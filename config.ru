require_relative 'app.rb'

require 'rack/brotli'
use Rack::Brotli
use Rack::Deflater

run WorldApp
