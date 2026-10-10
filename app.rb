require 'sinatra/base'
require 'json'
require 'securerandom'
require 'rack/utils'
require_relative 'lib/google_drive'

class WeddingApp < Sinatra::Base
  ALLOWED_EXTENSIONS = %w[
    jpg jpeg png gif webp heic heif avif tif tiff dng raw
    mp4 mov m4v 3gp avi mkv webm hevc
  ].freeze

  set :root, File.dirname(__FILE__)
  set :drive, GoogleDrive.from_env
  set :wedding_title, ENV.fetch('WEDDING_TITLE', 'Notre mariage')
  set :access_code, ENV['ACCESS_CODE'].to_s.strip
  set :admin_password, ENV['ADMIN_PASSWORD'].to_s
  set :max_file_bytes, Integer(ENV.fetch('MAX_FILE_MB', '2048')) * 1024 * 1024

  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }

  helpers do
    def h(text)
      Rack::Utils.escape_html(text.to_s)
    end

    def drive
      settings.drive
    end

    def code_ok?(code)
      settings.access_code.empty? || Rack::Utils.secure_compare(settings.access_code, code.to_s.strip)
    end

    def public_url(path = '')
      "#{request.base_url}#{path}"
    end

    def guest_link
      code = settings.access_code
      code.empty? ? public_url('/') : public_url("/?code=#{Rack::Utils.escape(code)}")
    end

    def redirect_uri
      public_url('/admin/oauth/callback')
    end

    def json_error(status_code, message)
      halt status_code, { 'Content-Type' => 'application/json' }, JSON.generate(error: message)
    end

    def protect_admin!
      password = settings.admin_password
      halt 503, 'Définissez la variable ADMIN_PASSWORD pour accéder à cette page.' if password.empty?

      auth = Rack::Auth::Basic::Request.new(request.env)
      return if auth.provided? && auth.basic? && Rack::Utils.secure_compare(password, auth.credentials[1].to_s)

      headers['WWW-Authenticate'] = 'Basic realm="Admin"'
      halt 401, 'Accès réservé aux mariés.'
    end

    # "Marie Dupont" + "IMG_1234.HEIC" -> "Marie Dupont - IMG_1234.HEIC"
    def drive_file_name(guest, original)
      clean = ->(s, max) { s.to_s.gsub(%r{[/\\\x00-\x1f]}, ' ').squeeze(' ').strip[0, max] }
      file = clean.(original, 150)
      file = "photo-#{Time.now.strftime('%Y%m%d-%H%M%S')}" if file.empty?
      guest = clean.(guest, 60)
      guest.empty? ? file : "#{guest} - #{file}"
    end

    def allowed_media?(mime_type, file_name)
      return true if mime_type.start_with?('image/', 'video/')

      ALLOWED_EXTENSIONS.include?(File.extname(file_name).delete('.').downcase)
    end
  end

  # --- Guests ------------------------------------------------------------

  get '/' do
    @code = params['code'].to_s
    @code_ok = code_ok?(@code)
    erb :index
  end

  # Called by the browser for each file; returns a Google Drive resumable
  # upload URL that the browser then PUTs the file to directly.
  post '/api/upload-session' do
    content_type :json
    payload = JSON.parse(request.body.read) rescue {}

    json_error 403, 'Code d’accès invalide.' unless code_ok?(payload['code'])
    json_error 503, 'Le Google Drive des mariés n’est pas encore connecté.' unless drive.configured?

    original = payload['name'].to_s
    mime_type = payload['type'].to_s.empty? ? 'application/octet-stream' : payload['type'].to_s
    size = payload['size'].to_i

    json_error 400, 'Seules les photos et vidéos sont acceptées.' unless allowed_media?(mime_type, original)
    json_error 400, 'Fichier vide.' unless size.positive?
    if size > settings.max_file_bytes
      json_error 413, "Fichier trop volumineux (max #{settings.max_file_bytes / 1024 / 1024} Mo)."
    end

    origin = request.env['HTTP_ORIGIN'] || request.base_url
    upload_url = drive.create_upload_session(
      name: drive_file_name(payload['guest'], original),
      mime_type: mime_type,
      size: size,
      origin: origin
    )
    JSON.generate(uploadUrl: upload_url)
  rescue GoogleDrive::Error => e
    logger.error(e.message)
    json_error 502, 'Impossible de contacter Google Drive, réessayez dans un instant.'
  end

  # Printable page with a QR code to put on the tables.
  get '/qr' do
    @link = guest_link
    erb :qr
  end

  get '/health' do
    'ok'
  end

  # --- Couple (admin) ----------------------------------------------------

  get '/admin' do
    protect_admin!
    @folder_url = nil
    @drive_error = nil
    if drive.configured?
      begin
        @folder_url = drive.folder_url
      rescue GoogleDrive::Error => e
        @drive_error = e.message
      end
    end
    erb :admin
  end

  get '/admin/connect' do
    protect_admin!
    halt 500, 'GOOGLE_CLIENT_ID et GOOGLE_CLIENT_SECRET doivent être définis.' unless drive.oauth_configured?

    session[:oauth_state] = SecureRandom.hex(16)
    redirect drive.authorization_url(redirect_uri: redirect_uri, state: session[:oauth_state])
  end

  get '/admin/oauth/callback' do
    protect_admin!
    expected = session.delete(:oauth_state)
    halt 400, 'État OAuth invalide, recommencez depuis /admin.' unless expected && params['state'] == expected
    halt 400, "Autorisation refusée : #{h params['error']}" if params['error']

    @refresh_token = drive.exchange_code(code: params['code'], redirect_uri: redirect_uri)
    erb :connected
  rescue GoogleDrive::Error => e
    halt 502, "Erreur Google : #{h e.message}"
  end
end
