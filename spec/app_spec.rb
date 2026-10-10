require 'json'

RSpec.describe WeddingApp do
  def app
    WeddingApp
  end

  let(:drive) do
    instance_double(GoogleDrive, configured?: true, oauth_configured?: true, folder_url: 'https://drive.google.com/drive/folders/abc')
  end

  before do
    WeddingApp.set :drive, drive
    WeddingApp.set :access_code, ''
    WeddingApp.set :admin_password, 'secret'
  end

  def request_session(body)
    post '/api/upload-session', JSON.generate(body), 'CONTENT_TYPE' => 'application/json', 'HTTP_ORIGIN' => 'https://photos.example'
  end

  describe 'GET /' do
    it 'shows the upload form' do
      get '/'
      expect(last_response).to be_ok
      expect(last_response.body).to include('id="files"')
    end

    it 'hides the form when an access code is required but missing' do
      WeddingApp.set :access_code, 'love'
      get '/'
      expect(last_response.body).not_to include('id="files"')
      get '/?code=love'
      expect(last_response.body).to include('id="files"')
    end
  end

  describe 'POST /api/upload-session' do
    it 'returns a Drive upload URL named after the guest' do
      expect(drive).to receive(:create_upload_session)
        .with(name: 'Camille - IMG_1.HEIC', mime_type: 'image/heic', size: 1234, origin: 'https://photos.example')
        .and_return('https://upload.example/session')

      request_session(name: 'IMG_1.HEIC', type: 'image/heic', size: 1234, guest: 'Camille')

      expect(last_response).to be_ok
      expect(JSON.parse(last_response.body)).to eq('uploadUrl' => 'https://upload.example/session')
    end

    it 'accepts media with an empty MIME type based on the extension' do
      allow(drive).to receive(:create_upload_session).and_return('https://upload.example/s')
      request_session(name: 'clip.MOV', type: '', size: 10)
      expect(last_response).to be_ok
    end

    it 'rejects non-media files' do
      request_session(name: 'virus.exe', type: 'application/x-msdownload', size: 10)
      expect(last_response.status).to eq(400)
    end

    it 'rejects files that are too big' do
      request_session(name: 'a.jpg', type: 'image/jpeg', size: 10 * 1024**3)
      expect(last_response.status).to eq(413)
    end

    it 'requires the access code when configured' do
      WeddingApp.set :access_code, 'love'
      request_session(name: 'a.jpg', type: 'image/jpeg', size: 10, code: 'nope')
      expect(last_response.status).to eq(403)
    end

    it 'reports when Drive is not connected yet' do
      allow(drive).to receive(:configured?).and_return(false)
      request_session(name: 'a.jpg', type: 'image/jpeg', size: 10)
      expect(last_response.status).to eq(503)
    end
  end

  describe 'GET /admin' do
    it 'requires the admin password' do
      get '/admin'
      expect(last_response.status).to eq(401)
    end

    it 'shows the Drive folder and the guest link' do
      basic_authorize 'admin', 'secret'
      get '/admin'
      expect(last_response).to be_ok
      expect(last_response.body).to include('https://drive.google.com/drive/folders/abc')
      expect(last_response.body).to include('http://example.org/')
    end
  end

  it 'renders the printable QR page' do
    get '/qr'
    expect(last_response).to be_ok
    expect(last_response.body).to include('qrcode')
  end
end
