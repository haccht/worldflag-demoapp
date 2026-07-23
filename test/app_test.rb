# frozen_string_literal: true

ENV['RESTCOUNTRIES_API_KEY'] = 'test-key'
ENV['APP_ENV'] = 'test'
ENV['CACHE_COUNTRIES'] = 'tmp/test-cache/countries'
ENV['CACHE_FLAGS'] = 'tmp/test-cache/flags'

require 'fileutils'
require 'minitest/autorun'
require 'rake'
require 'rack/test'
require_relative '../app'
load File.expand_path('../Rakefile', __dir__)

FakeResponse = Struct.new(:status, :body)

class FakeClient
  attr_reader :requests

  def initialize(*responses)
    @responses = responses
    @requests = []
  end

  def get(endpoint)
    req = Struct.new(:params).new({})
    yield req if block_given?
    @requests << [endpoint, req.params.dup]
    @responses.shift
  end
end

class FakeConnectionBuilder
  attr_reader :headers

  def initialize
    @headers = {}
  end

  def request(*) = nil

  def response(*) = nil
end

class WorldFlagAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    WorldFlagApp
  end

  def setup
    FileUtils.rm_rf('tmp/test-cache')
    FileUtils.mkdir_p([CACHE_COUNTRIES, CACHE_FLAGS])
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, 'all_v5.json'))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, 'all_v5_alpha2.json'))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, 'jp_v5.json'))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, 'all_v5_alpha2.json.lock'))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, "#{COUNTRIES_CACHE_FILE}.lock"))
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, 'jp_v5.json.lock'))
    FileUtils.rm_f(File.join(CACHE_FLAGS, 'jp.png'))
    @app = WorldFlagApp.new!
  end

  def teardown
    FileUtils.rm_rf('tmp/test-cache')
  end

  def test_countries_pages_with_free_plan_limit
    client = FakeClient.new(
      FakeResponse.new(200, {
        'data' => {
          'objects' => [
            {'names' => {'common' => 'Japan'}, 'codes' => {'alpha_2' => 'JP'}},
            {'names' => {'common' => 'Canada'}, 'codes' => {'alpha_2' => 'CA'}},
            {'names' => {'common' => 'Abkhazia'}, 'codes' => {'alpha_2' => ''}}
          ],
          'meta' => {'more' => true, 'limit' => 100}
        }
      }),
      FakeResponse.new(200, {
        'data' => {
          'objects' => [
            {'names' => {'common' => 'Brazil'}, 'codes' => {'alpha_2' => 'BR'}}
          ],
          'meta' => {'more' => false, 'limit' => 100}
        }
      })
    )
    @app.instance_variable_set(:@client, client)

    countries = @app.send(:countries)

    assert_equal %w[Brazil Canada Japan], countries.map { |country| country.dig('names', 'common') }
    assert_equal [
      ['', {limit: 100, offset: 0, response_fields: RESTCOUNTRIES_RESPONSE_FIELDS}],
      ['', {limit: 100, offset: 100, response_fields: RESTCOUNTRIES_RESPONSE_FIELDS}]
    ], client.requests
  end

  def test_healthcheck_returns_ok_without_touching_api_or_cache
    get '/_chk'

    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.content_type
    assert_equal({'status' => 'ok'}, JSON.parse(last_response.body))
    assert_equal 'no-store', last_response.headers['cache-control']
    refute File.exist?(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE))
  end

  def test_country_reads_v5_shape_from_full_cache_by_alpha2
    File.write(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE), JSON.generate([
      {
        'names' => {'common' => 'Japan'},
        'codes' => {'alpha_2' => 'JP'},
        'coordinates' => {'lat' => 36.0, 'lng' => 138.0}
      }
    ]))
    @app.instance_variable_set(:@client, FakeClient.new)

    country = @app.send(:country, 'jp')

    assert_equal 'Japan', country.dig('names', 'common')
    assert_equal 'JP', country.dig('codes', 'alpha_2')
    assert_empty @app.instance_variable_get(:@client).requests
  end

  def test_countries_uses_fresh_cache_without_api_request
    File.write(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE), JSON.generate([
      {'names' => {'common' => 'Japan'}, 'codes' => {'alpha_2' => 'JP'}}
    ]))
    @app.instance_variable_set(:@client, FakeClient.new)

    countries = @app.send(:countries)

    assert_equal ['Japan'], countries.map { |country| country.dig('names', 'common') }
    assert_empty @app.instance_variable_get(:@client).requests
  end

  def test_sample_quiz_uses_list_cache_names
    File.write(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE), JSON.generate([
      {'names' => {'common' => 'Japan'}, 'codes' => {'alpha_2' => 'JP'}},
      {'names' => {'common' => 'Canada'}, 'codes' => {'alpha_2' => 'CA'}},
      {'names' => {'common' => 'Brazil'}, 'codes' => {'alpha_2' => 'BR'}},
      {'names' => {'common' => 'France'}, 'codes' => {'alpha_2' => 'FR'}}
    ]))
    @app.instance_variable_set(:@client, FakeClient.new)

    question = @app.send(:sample_quiz)

    assert_equal 4, question[:choices].size
    assert question[:choices].all? { |choice| choice.key?(:code) && choice.key?(:name) }
    assert_empty @app.instance_variable_get(:@client).requests
  end

  def test_quiz_answer_returns_answer_on_wrong_guess
    env 'rack.session', {quiz_answer: 'jp', quiz_answer_name: 'Japan'}

    post '/quiz/answer', guess: 'ca'

    assert_equal 200, last_response.status
    assert_equal({
      'correct' => false,
      'answer' => {'code' => 'jp', 'name' => 'Japan'}
    }, JSON.parse(last_response.body))
  end

  def test_country_halts_when_code_is_not_in_full_cache
    File.write(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE), JSON.generate([]))

    assert_throws(:halt) { @app.send(:country, 'zz') }
  end

  def test_restcountries_client_uses_bearer_auth
    builder = nil
    response = FakeResponse.new(200, {
      'data' => {
        'objects' => [],
        'meta' => {'more' => false}
      }
    })

    Faraday.stub(:new, lambda { |url, &block|
      assert_equal RESTCOUNTRIES_API_BASEURL, url
      builder = FakeConnectionBuilder.new
      block.call(builder)
      FakeClient.new(response)
    }) do
      @app.send(:restcountries)
    end

    assert_equal 'Bearer test-key', builder.headers['Authorization']
  end

  def test_display_helpers_read_v5_fields
    country = {
      'capitals' => [{'name' => 'Tokyo'}],
      'languages' => [{'name' => 'Japanese'}],
      'currencies' => {'JPY' => {'name' => 'Japanese yen', 'symbol' => 'Y'}}
    }

    assert_equal ['Tokyo'], @app.send(:capital_names, country)
    assert_equal ['Japanese'], @app.send(:language_names, country)
    assert_equal ['Y Japanese yen (JPY)'], @app.send(:currency_names, country)
  end

  def test_flag_description_returns_text_or_nil
    assert_equal 'A red circle on a white field.', @app.send(:flag_description, {
      'flag' => {'description' => ' A red circle on a white field. '}
    })
    assert_nil @app.send(:flag_description, {'flag' => {'description' => ' '}})
    assert_nil @app.send(:flag_description, {})
  end

  def test_flag_palette_filters_invalid_entries
    palette = @app.send(:flag_palette, {
      'flag' => {
        'colors' => {
          'palette' => [
            {'hex' => '#ffffff', 'proportion' => 0.72},
            {'hex' => '', 'proportion' => 0.28},
            {'hex' => 'red', 'proportion' => 0.1},
            {'proportion' => 0.1},
            {'hex' => '#bc002d'}
          ]
        }
      }
    })

    assert_equal [
      {'hex' => '#ffffff', 'proportion' => 0.72},
      {'hex' => '#bc002d', 'proportion' => nil}
    ], palette
  end

  def test_maps_embed_url_returns_nil_without_key
    old_key = ENV.delete('MAPS_EMBED_KEY')
    country = {
      'coordinates' => {'lat' => 36.0, 'lng' => 138.0},
      'area' => {'kilometers' => 377_975}
    }

    assert_nil @app.send(:maps_embed_url, country)
  ensure
    ENV['MAPS_EMBED_KEY'] = old_key if old_key
  end

  def test_flag_fetches_original_png_from_v5_flag_cdn
    response = FakeResponse.new(200, 'png-bytes')
    Faraday.stub(:get, lambda { |url|
      assert_equal "#{RESTCOUNTRIES_FLAG_BASEURL}jp.png", url
      response
    }) do
      path = @app.send(:flag, 'jp', 'png')

      assert_equal File.join(CACHE_FLAGS, 'jp.png'), path
      assert_equal 'png-bytes', File.read(path)
    end
  ensure
    FileUtils.rm_f(File.join(CACHE_FLAGS, 'jp.png'))
  end

  def test_cache_prune_removes_obsolete_detail_caches
    detail_cache = File.join(CACHE_COUNTRIES, 'jp_v5.json')
    old_list_cache = File.join(CACHE_COUNTRIES, 'all_v5_alpha2.json')
    full_cache = File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE)
    File.write(detail_cache, '{}')
    File.write(old_list_cache, '[]')
    File.write(full_cache, '[]')

    Rake::Task['cache:prune'].reenable
    Rake::Task['cache:prune'].invoke

    refute File.exist?(detail_cache)
    refute File.exist?(old_list_cache)
    assert File.exist?(full_cache)
  ensure
    FileUtils.rm_f(detail_cache)
    FileUtils.rm_f(old_list_cache)
    FileUtils.rm_f(full_cache)
  end

  def test_cache_warm_populates_full_cache_without_detail_requests
    client = FakeClient.new(FakeResponse.new(200, {
      'data' => {
        'objects' => [
          {'names' => {'common' => 'Japan'}, 'codes' => {'alpha_2' => 'JP'}}
        ],
        'meta' => {'more' => false, 'limit' => 100}
      }
    }))

    WorldFlagApp.stub(:new!, -> { @app }) do
      @app.instance_variable_set(:@client, client)
      Rake::Task['cache:warm'].reenable
      Rake::Task['cache:warm'].invoke
    end

    assert File.exist?(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE))
    assert_equal [['', {limit: 100, offset: 0, response_fields: RESTCOUNTRIES_RESPONSE_FIELDS}]], client.requests
  ensure
    FileUtils.rm_f(File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE))
  end
end
