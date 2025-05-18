require 'sinatra/json'
require 'sinatra/base'
require 'sinatra/cookies'
require 'sinatra/custom_logger'
require 'dotenv/load'
require 'faraday'
require 'image_processing/mini_magick'
require 'fileutils'
require 'digest/sha1'
require 'json'

BASE_URL  = "https://restcountries.com/v3.1/"
CACHE_TTL = 30*24*60*60

CACHE_COUNTRIES = 'cache/countries'
CACHE_FLAGS     = 'cache/flags'
FileUtils.mkdir_p([CACHE_COUNTRIES, CACHE_FLAGS])


class WorldApp < Sinatra::Base
  configure :development, :production do
    set :logger, Logger.new($stdout)
    set :static_cache_control, [:public, max_age: CACHE_TTL, immutable: true]
    use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'] || SecureRandom.hex(64)
  end

  configure :production do
    set :host_authorization, { permitted_hosts: ["www.thachimu.net", "origin-2d36863-www.thachimu.net"] }
  end

  helpers Sinatra::Cookies
  helpers Sinatra::CustomLogger
  helpers do
    def restcountries(endpoint, **params)
      @client ||= Faraday.new(BASE_URL) do |conn|
        conn.request  :json
        conn.response :json, content_type: "application/json"
      end
      resp = @client.get(endpoint, **params)

      case resp.status
      when 200...300
        resp.body
      else
        raise "Unexpected status: #{resp.status}"
      end
    end

    def countries
      restcountries('all', fields: 'name,cca2').sort_by { |c| c['name']['common'] }
    end

    def country(code)
      cache = File.join(CACHE_COUNTRIES, "#{code.downcase}.json")
      cache_miss = !File.exist?(cache) || File.mtime(cache) < Time.now - CACHE_TTL
      return JSON.parse(File.read(cache)) unless cache_miss

      if fresh = restcountries("alpha/#{code}")&.first
        File.write(cache, JSON.generate(fresh))
        return fresh
      end
      halt 404, 'Country not found'
    rescue
      halt 502
    end

    def flag_cache(base, ext)
      cache = File.join(CACHE_FLAGS, "#{base}.#{ext}")
      cache_miss = !File.exist?(cache) || File.mtime(cache) < Time.now - CACHE_TTL
      return cache unless cache_miss

      code, w, h = base.match(/([a-z]+)(?:_([0-9]+)x([0-9]+))?/).captures
      if ext == 'png' && w.nil? && h.nil?
        flag_url = country(code).dig('flags', 'png')
        resp = Faraday.get(flag_url)
        File.write(cache, resp.body) if resp.status == 200
        return cache
      end

      png = flag_cache(code, 'png')
      pipeline = ImageProcessing::MiniMagick.source(png)
      pipeline = pipeline.resize_to_fit(w&.to_i, h&.to_i)
      pipeline = pipeline.convert(ext)
      pipeline.call(destination: cache)
      return cache
    rescue
      halt 502
    end

    def maps_embed_url(country)
      lat, lng = country['latlng']
      key = ENV['MAPS_EMBED_KEY'] || raise('MAPS_EMBED_KEY missing')
      zoom = ((14.6 - 0.5*Math.log2(country['area'].to_i+1)).round).clamp(3, 12)
      "https://www.google.com/maps/embed/v1/view?key=#{key}&center=#{lat},#{lng}&zoom=#{zoom}&maptype=roadmap"
    end

    def sample_quiz
      choices = countries.sample(4).map { |c| c['cca2'] }
      {code: choices.first.downcase, choices: choices.shuffle}
    end

    def format_n(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end

  get '/' do
    @countries = countries
    if params[:q]&.strip&.length&.positive?
      q = params[:q].downcase
      @countries.select! { ['name', 'code'].any? { |e| c[e].downcase.include?(q) } }
    end
    erb :index
  end

  get '/country/:code' do |code|
    @country = country(code)
    erb :country
  end

  get '/flags/:name' do |name|
    m = name.downcase.match(/([a-z]+(?:_[0-9]+x[0-9]+)?)\.([^\.]+)$/)
    halt 502 unless m

    base, ext = m.captures
    filepath = flag_cache(base, ext)

    case ext
    when 'jpg', 'jpeg'
      content_type 'image/jpeg'
    when 'png'
      content_type 'image/png'
    when 'gif'
      content_type 'image/gif'
    when 'webp'
      content_type 'image/webp'
    when 'jpg', 'jpeg'
      content_type 'image/jpeg'
    when 'avif'
      content_type 'image/avif'
    when 'svg'
      content_type 'image/svg+xml'
    else
      halt 400
    end

    etag Digest::SHA1.file(filepath).hexdigest
    cache_control [:public, max_age: CACHE_TTL, immutable: true]
    send_file filepath
  end

  get '/quiz' do
    @question = sample_quiz
    session[:quiz_answer] = @question[:code]
    erb :quiz
  end

  post '/quiz/answer' do
    correct = (params[:guess]&.downcase == session.delete(:quiz_answer)&.downcase)
    json correct: correct
  end

  get '/api/country/:code' do |code|
    json country(code)
  end
end
