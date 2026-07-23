require 'sinatra/json'
require 'sinatra/base'
require 'sinatra/cookies'
require 'sinatra/custom_logger'
require 'dotenv/load'
require 'faraday'
require 'rack/brotli'
require 'image_processing/mini_magick'
require 'fileutils'
require 'digest/sha1'
require 'json'

RESTCOUNTRIES_API_BASEURL  = "https://api.restcountries.com/countries/v5"
RESTCOUNTRIES_FLAG_BASEURL = "https://flags.restcountries.com/v5/w320/"
RESTCOUNTRIES_RESPONSE_FIELD_NAMES = %w[
  names
  codes.alpha_2
  flag
  flag.description
  flag.colors.dominant
  flag.colors.palette
  capitals
  continents
  timezones
  region
  subregion
  population
  area.kilometers
  coordinates
  languages
  currencies
].freeze
RESTCOUNTRIES_RESPONSE_FIELDS = RESTCOUNTRIES_RESPONSE_FIELD_NAMES.join(',')

CACHE_COUNTRIES = ENV.fetch('CACHE_COUNTRIES', 'cache/countries')
CACHE_FLAGS     = ENV.fetch('CACHE_FLAGS', 'cache/flags')
CACHE_TTL_API   = 3*24*60*60
CACHE_TTL_ASSET = 30*24*60*60

COUNTRIES_CACHE_FILE = 'all_v5_full_alpha2.json'
FLAG_BASE_PATTERN = /\A([a-z]+)(?:_([0-9]+)x([0-9]+))?\z/
FLAG_NAME_PATTERN = /\A([a-z]+(?:_[0-9]+x[0-9]+)?)\.([^\.]+)\z/
CONTENT_TYPES = {
  'jpg' => 'image/jpeg',
  'jpeg' => 'image/jpeg',
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'avif' => 'image/avif',
  'svg' => 'image/svg+xml'
}.freeze

FileUtils.mkdir_p([CACHE_COUNTRIES, CACHE_FLAGS])

class RestCountriesError < StandardError
  attr_reader :status

  def initialize(status, message)
    super(message)
    @status = status
  end
end

class DebugMiddleware
  def initialize(app, logger:)
    @app = app
    @logger = logger
  end

  def call(env)
    env.select { |k,_| k.start_with?('HTTP_') }.each do |k,v|
      k = k.delete_prefix("HTTP_").gsub(/_/, '-').downcase
      @logger.info "[req->] #{k}: #{v}"
    end

    status, headers, body = @app.call(env)
    headers.each do |k,v|
      @logger.info "[<-res] #{k}: #{v}"
    end

    [status, headers, body]
  end
end


class WorldFlagApp < Sinatra::Base
  configure :development, :production do
    set :static_cache_control, [:public, max_age: CACHE_TTL_ASSET, immutable: true]
    set :logger, Logger.new($stdout)
    $stdout.sync = true

    #use DebugMiddleware, logger: settings.logger
    use Rack::CommonLogger, settings.logger
    use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'] || SecureRandom.hex(64)

    use Rack::Deflater
    use Rack::Brotli
  end

  configure :production do
    set :host_authorization, { permitted_hosts: ENV['AUTHORIZED_HOSTS'].split(",").map { |e| e.strip } }
  end

  helpers Sinatra::Cookies
  helpers Sinatra::CustomLogger
  helpers do
    def api_key
      ENV.fetch('RESTCOUNTRIES_API_KEY') { raise 'RESTCOUNTRIES_API_KEY missing' }
    end

    def restcountries(**params)
      @client ||= Faraday.new(RESTCOUNTRIES_API_BASEURL) do |conn|
        conn.headers['Authorization'] = "Bearer #{api_key}"
        conn.request  :json
        conn.response :json, content_type: "application/json"
      end
      resp = @client.get('') do |req|
        req.params.update(params)
      end

      case resp.status
      when 200...300
        data = resp.body['data'] if resp.body.is_a?(Hash)
        raise "Unexpected response shape from REST Countries" unless data.is_a?(Hash)

        [data['objects'] || [], data['meta'] || {}]
      else
        message = if resp.body.is_a?(Hash)
          Array(resp.body['errors']).map { |error| error['message'] }.compact.join(', ')
        end
        error_message = "REST Countries request failed: #{resp.status}"
        error_message += ": #{message}" unless message.to_s.empty?
        raise RestCountriesError.new(resp.status, error_message)
      end
    end

    def read_cache(path, ttl)
      return nil unless File.exist?(path)
      return nil if File.mtime(path) < Time.now - ttl

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def fetch_json_cache(path, ttl)
      cached = read_cache(path, ttl)
      return cached if cached

      FileUtils.mkdir_p(File.dirname(path))
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        cached = read_cache(path, ttl)
        return cached if cached

        fresh = yield
        File.write(path, JSON.generate(fresh))
        fresh
      end
    end

    def countries
      fetch_json_cache(countries_cache_path, CACHE_TTL_API) { fetch_countries }
    end

    def country(code)
      found = countries.find { |country| country_code(country).casecmp?(code.to_s) }
      halt 404, 'Country not found' unless found

      found
    end

    def countries_cache_path
      File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE)
    end

    def fetch_countries
      records = fetch_country_pages
      records = records.select { |country| valid_country_code?(country_code(country)) }
      records.sort_by { |country| country_name(country) }
    end

    def fetch_country_pages
      offset = 0
      records = []
      loop do
        objects, meta = restcountries(
          limit: 100,
          offset: offset,
          response_fields: RESTCOUNTRIES_RESPONSE_FIELDS
        )
        records.concat(objects)
        break unless meta['more']

        offset += meta['limit'].to_i
        offset += 100 if meta['limit'].to_i <= 0
      end
      records
    end

    def country_code(country)
      country.dig('codes', 'alpha_2').to_s
    end

    def country_name(country)
      country.dig('names', 'common').to_s
    end

    def valid_country_code?(code)
      code.match?(/\A[a-z]{2}\z/i)
    end

    def flag(base, ext)
      cache = File.join(CACHE_FLAGS, "#{base}.#{ext}")
      cache_miss = !File.exist?(cache) || File.mtime(cache) < Time.now - CACHE_TTL_ASSET
      return cache unless cache_miss

      match = base.match(FLAG_BASE_PATTERN)
      halt 502 unless match

      code, w, h = match.captures
      if ext == 'png' && w.nil? && h.nil?
        flag_url = "#{RESTCOUNTRIES_FLAG_BASEURL}#{code}.png"
        resp = Faraday.get(flag_url)
        halt 502 unless resp.status == 200

        File.write(cache, resp.body)
        return cache
      end

      png = flag(code, 'png')

      pipeline = ImageProcessing::MiniMagick.source(png)
      pipeline = pipeline.resize_to_fit(w&.to_i, h&.to_i)
      pipeline = pipeline.convert(ext)
      pipeline.call(destination: cache)
      return cache
    rescue
      halt 502
    end

    def maps_embed_url(country)
      lat = country.dig('coordinates', 'lat')
      lng = country.dig('coordinates', 'lng')
      key = ENV['MAPS_EMBED_KEY']
      return nil if key.to_s.empty? || lat.nil? || lng.nil?

      zoom = ((14.6 - 0.5*Math.log2(country.dig('area', 'kilometers').to_i+1)).round).clamp(3, 12)
      "https://www.google.com/maps/embed/v1/view?key=#{key}&center=#{lat},#{lng}&zoom=#{zoom}&maptype=roadmap"
    end

    def sample_quiz
      choices = countries.sample(4).map do |country|
        {
          code: country_code(country).downcase,
          name: country_name(country)
        }
      end
      {code: choices.first[:code], choices: choices.shuffle}
    end

    def capital_names(country)
      Array(country['capitals']).map { |capital| capital['name'] }.compact
    end

    def language_names(country)
      Array(country['languages']).map { |language| language['name'] || language['english_name'] }.compact
    end

    def currency_names(country)
      case country['currencies']
      when Hash
        country['currencies'].map do |code, currency|
          [currency['symbol'], currency['name'], "(#{code})"].compact.join(' ')
        end
      when Array
        country['currencies'].map do |currency|
          [currency['symbol'], currency['name'] || currency['english_name'], "(#{currency['code']})"].compact.join(' ')
        end
      else
        []
      end
    end

    def flag_description(country)
      description = country.dig('flag', 'description').to_s.strip
      description unless description.empty?
    end

    def flag_palette(country)
      Array(country.dig('flag', 'colors', 'palette')).filter_map do |entry|
        hex = entry['hex'].to_s.strip
        next unless hex.match?(/\A#[0-9a-fA-F]{6}\z/)

        {'hex' => hex, 'proportion' => entry['proportion']}
      end
    end

    def format_n(n)
      return nil if n.nil?

      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end

  error KeyError do
    status 503
    @title = "Configuration error - World Flags"
    @message = "RESTCOUNTRIES_API_KEY is missing."
    erb :error
  end

  error RestCountriesError do
    error = env['sinatra.error']
    status case error.status
    when 401, 403
      503
    when 429
      429
    else
      502
    end
    @title = "REST Countries error - World Flags"
    @message = error.message
    erb :error
  end

  get '/' do
    @countries = countries

    erb :index
  end

  get '/country/:code' do |code|
    @country = country(code)
    erb :country
  end

  get '/flags/:name' do |name|
    m = name.downcase.match(FLAG_NAME_PATTERN)
    halt 502 unless m

    base, ext = m.captures
    filepath = flag(base, ext)
    type = CONTENT_TYPES[ext]
    halt 400 unless type

    content_type type

    etag Digest::SHA1.file(filepath).hexdigest
    cache_control [:public, max_age: CACHE_TTL_ASSET, immutable: true]
    send_file filepath
  end

  get '/quiz' do
    @question = sample_quiz
    session[:quiz_answer] = @question[:code]
    session[:quiz_answer_name] = @question[:choices].find { |choice| choice[:code] == @question[:code] }&.dig(:name)
    erb :quiz
  end

  post '/quiz/answer' do
    answer_code = session.delete(:quiz_answer)
    answer_name = session.delete(:quiz_answer_name)
    correct = (params[:guess]&.downcase == answer_code&.downcase)
    json correct: correct, answer: {code: answer_code, name: answer_name}
  end

  get '/api/country/:code' do |code|
    json country(code)
  end

  get '/_chk' do
    cache_control :no_store
    json status: 'ok'
  end
end
