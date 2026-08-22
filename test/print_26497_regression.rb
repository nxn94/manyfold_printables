# Regression test: reproduce the exact import failure reported by the user
# (print 26497 "Screw Organising Tray") and assert the deserializer now
# produces a Model.update! payload that Manyfold can accept.
#
# Two real bugs were caught and fixed by this fixture:
#   1. license was human-readable "Creative Commons — Attribution" — failed
#      Manyfold's spdx validator and rolled back the whole sync.
#   2. file_urls contained bogus STEP entries whose preview path is under
#      /previews/ instead of /stls/ — those URLs would 404 on download.
#
# If you change the deserializer and either of these regresses, this test
# will fail.

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

module Integrations
  class BaseDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = canonicalize(uri); end
    def valid?(for_class: nil); api_configured? && !uri.nil? && (for_class ? for_class == capabilities[:class] : true); end
    def deserialize; raise NotImplementedError; end
    def capabilities; raise NotImplementedError; end
    private
    def api_configured?; raise NotImplementedError; end
    def canonicalize(uri); raise NotImplementedError; end
    def attempt_creator_match(attrs); {creator_attributes: attrs}; end
    def filename_from_url(url); return nil if url.nil? || url.to_s.empty?; CGI.unescape(URI.parse(url).path).split("/").last; end
  end
end
class Model; end; class Creator; end
require "net/http"; require "json"; require "uri"; require "cgi"
module Faraday
  class ResourceNotFound < StandardError; def initialize(m = "Not Found"); super(m); end; end
  class Error < StandardError; end
end
module ManyfoldPrintables; VERSION = "0.1.0"; end

PLUGIN = File.expand_path("../app/deserializers/integrations/printables", __dir__)
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"
require "#{PLUGIN}/creator_deserializer.rb"

fixture_path = File.expand_path("fixtures/print_26497.json", __dir__)
abort "fixture missing: #{fixture_path}" unless File.exist?(fixture_path)
data = JSON.parse(File.read(fixture_path))["data"]["print"]

Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}| {"print" => data} }
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/26497-screw-organising-tray-with-numbers")
result = md.deserialize

failures = []

# Bug 1: license must be a valid SPDX identifier that Manyfold accepts.
# Manyfold's Model validates `license` with the spdx gem; the human-readable
# name from Printables is NOT a valid SPDX identifier.
failures << "license is not SPDX: #{result[:license].inspect}" unless result[:license] == "CC-BY-4.0"

# Bug 2: file_urls must not contain STEP files. Printables' GraphQL `stls`
# array contains any geometry file — .stl, .stp, .3mf, etc. The deserializer
# should derive download URLs only for files whose preview path is under a
# known CDN directory (/stls/, /slas/, /gcodes/). STEP files in this print
# have preview paths under /previews/ and should be skipped.
bogus = result[:file_urls].select { |e| e[:url].to_s.include?("/previews/") }
failures << "found #{bogus.size} bogus /previews/ entries: #{bogus.map { |b| b[:filename] }.inspect}" unless bogus.empty?

# Bug 2 (continued): Every entry must be under /stls/, /slas/, /gcodes/, /images/
bad_dirs = result[:file_urls].reject { |e|
  %w[/stls/ /slas/ /gcodes/ /images/].any? { |d| e[:url].to_s.include?(d) }
}
failures << "found entries outside known dirs: #{bad_dirs.map { |b| b[:url] }.inspect}" unless bad_dirs.empty?

# Sanity: must have at least one STL and one image for this print
stls = result[:file_urls].select { |e| e[:filename].end_with?(".stl") }
imgs = result[:file_urls].select { |e| e[:filename].end_with?(".jpg") }
failures << "no STL files in result (got #{stls.size})" if stls.empty?
failures << "no images in result (got #{imgs.size})" if imgs.empty?

# Sanity: every STL URL must actually download from the CDN
require "net/http"
stls.each do |e|
  uri = URI.parse(e[:url])
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |h|
    resp = h.head(uri.request_uri)
    failures << "STL #{e[:url]} returned #{resp.code}" unless resp.code.to_i == 200
  end
end

# Sanity: name and slug should be populated (not the placeholder)
failures << "name is placeholder: #{result[:name].inspect}" if result[:name].to_s.start_with?("Importing from ")
failures << "slug is empty: #{result[:slug].inspect}" if result[:slug].to_s.empty?

if failures.empty?
  puts "✓ print 26497 import payload valid:"
  puts "  - license = #{result[:license]}"
  puts "  - file_urls = #{result[:file_urls].size} (all in /stls/, /slas/, /gcodes/, or /images/)"
  puts "  - all STL URLs return 200 OK"
  puts "  - name = #{result[:name].inspect}"
else
  puts "✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
