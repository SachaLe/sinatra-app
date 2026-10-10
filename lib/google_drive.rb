require 'net/http'
require 'json'
require 'uri'

# Minimal Google Drive client (no heavy SDK).
#
# It authenticates as the Drive owner via an OAuth refresh token and uses the
# `drive.file` scope, which only gives access to files this app creates.
# Photos are not proxied through our server: we only open a *resumable upload
# session* and hand its URL to the guest's browser, which uploads directly to
# Google Drive.
class GoogleDrive
  class Error < StandardError; end

  SCOPE = 'https://www.googleapis.com/auth/drive.file'.freeze
  AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'.freeze
  TOKEN_URL = 'https://oauth2.googleapis.com/token'.freeze
  FILES_URL = 'https://www.googleapis.com/drive/v3/files'.freeze
  UPLOAD_URL = 'https://www.googleapis.com/upload/drive/v3/files'.freeze
  FOLDER_MIME = 'application/vnd.google-apps.folder'.freeze

  attr_reader :client_id, :client_secret, :refresh_token, :folder_name

  def initialize(client_id:, client_secret:, refresh_token:, folder_name:)
    @client_id = client_id
    @client_secret = client_secret
    @refresh_token = refresh_token
    @folder_name = folder_name
    @token_mutex = Mutex.new
    @folder_mutex = Mutex.new
  end

  def self.from_env
    new(
      client_id: ENV['GOOGLE_CLIENT_ID'],
      client_secret: ENV['GOOGLE_CLIENT_SECRET'],
      refresh_token: ENV['GOOGLE_REFRESH_TOKEN'],
      folder_name: ENV.fetch('DRIVE_FOLDER_NAME', 'Photos du mariage')
    )
  end

  def oauth_configured?
    present?(client_id) && present?(client_secret)
  end

  def configured?
    oauth_configured? && present?(refresh_token)
  end

  # --- One-time owner authorization (used by the /admin page) -------------

  def authorization_url(redirect_uri:, state:)
    params = {
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: 'code',
      scope: SCOPE,
      access_type: 'offline',
      prompt: 'consent',
      state: state
    }
    "#{AUTH_URL}?#{URI.encode_www_form(params)}"
  end

  # Exchanges the authorization code and returns the refresh token.
  def exchange_code(code:, redirect_uri:)
    data = post_form(TOKEN_URL,
                     code: code,
                     client_id: client_id,
                     client_secret: client_secret,
                     redirect_uri: redirect_uri,
                     grant_type: 'authorization_code')
    data.fetch('refresh_token') { raise Error, 'Google did not return a refresh token' }
  end

  # --- Uploads -----------------------------------------------------------

  # Opens a resumable upload session in the wedding folder and returns its URL.
  # `origin` must be the origin of the page that will PUT the file (CORS).
  def create_upload_session(name:, mime_type:, size:, origin:)
    uri = URI("#{UPLOAD_URL}?uploadType=resumable&fields=id,name")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    req['Content-Type'] = 'application/json; charset=UTF-8'
    req['X-Upload-Content-Type'] = mime_type
    req['X-Upload-Content-Length'] = size.to_s
    req['Origin'] = origin if origin
    req.body = JSON.generate(name: name, parents: [folder_id])

    res = perform(uri, req)
    location = res['Location']
    raise Error, "Upload session failed (#{res.code}): #{res.body}" unless res.is_a?(Net::HTTPSuccess) && location

    location
  end

  def folder_id
    @folder_mutex.synchronize { @folder_id ||= find_folder || create_folder }
  end

  def folder_url
    "https://drive.google.com/drive/folders/#{folder_id}"
  end

  private

  def access_token
    @token_mutex.synchronize do
      if @access_token.nil? || Time.now >= @access_token_expires_at
        data = post_form(TOKEN_URL,
                         client_id: client_id,
                         client_secret: client_secret,
                         refresh_token: refresh_token,
                         grant_type: 'refresh_token')
        @access_token = data.fetch('access_token')
        @access_token_expires_at = Time.now + data.fetch('expires_in', 3600).to_i - 60
      end
      @access_token
    end
  end

  # With the drive.file scope, only folders created by this app are visible,
  # so a name match is enough to find "our" folder again after a restart.
  def find_folder
    escaped = folder_name.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
    query = "name = '#{escaped}' and mimeType = '#{FOLDER_MIME}' and trashed = false"
    uri = URI("#{FILES_URL}?#{URI.encode_www_form(q: query, fields: 'files(id)', spaces: 'drive')}")
    data = api_json(uri, Net::HTTP::Get.new(uri))
    data.fetch('files', []).first&.fetch('id')
  end

  def create_folder
    uri = URI("#{FILES_URL}?fields=id")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json; charset=UTF-8'
    req.body = JSON.generate(name: folder_name, mimeType: FOLDER_MIME)
    api_json(uri, req).fetch('id')
  end

  def api_json(uri, req)
    req['Authorization'] = "Bearer #{access_token}"
    res = perform(uri, req)
    raise Error, "Drive API error (#{res.code}): #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  end

  def post_form(url, params)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(params)
    res = perform(uri, req)
    data = JSON.parse(res.body) rescue {}
    raise Error, "OAuth error (#{res.code}): #{data['error_description'] || data['error'] || res.body}" unless res.is_a?(Net::HTTPSuccess)

    data
  end

  def perform(uri, req)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(req)
    end
  end

  def present?(value)
    !value.nil? && !value.strip.empty?
  end
end
