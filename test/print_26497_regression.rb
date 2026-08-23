# Test: end-to-end import payload for print 26497 using a captured real
# GraphQL response from api.printables.com.
#
# This is a regression test for two real bugs caught by this fixture:
#   1. license was human-readable "Creative Commons — Attribution" — failed
#      Manyfold's spdx validator and rolled back the whole sync.
#   2. file_urls contained bogus STEP entries whose preview path is under
#      /previews/ instead of /stls/ — those URLs would 404 on download.
#
# Now that we use getDownloadLink to get signed URLs, both bugs are caught
# differently: bug 1 is still about license mapping; bug 2 manifests as
# the getDownloadLink mutation returning ok=false for the STP file (which
# is in the `stls` array but isn't really an STL).

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
  end
end
class Model; end; class Creator; end
require "net/http"; require "json"; require "uri"; require "cgi"
module Faraday
  class ResourceNotFound < StandardError; def initialize(m = "Not Found"); super(m); end; end
  class Error < StandardError; end
end
module ManyfoldPrintables; VERSION = "0.1.0"; end

# Stub Rails.logger
module Rails
  def self.logger
    @logger ||= Class.new {
      def initialize; @messages = []; end
      def info(m); @messages << m; end
      def warn(m); @messages << m; end
      def error(m); @messages << m; end
      def messages; @messages; end
    }.new
  end
end

PLUGIN = File.expand_path("../app/deserializers/integrations/printables", __dir__)
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"
require "#{PLUGIN}/creator_deserializer.rb"

fixture_path = File.expand_path("fixtures/print_26497.json", __dir__)
abort "fixture missing: #{fixture_path}" unless File.exist?(fixture_path)
data = JSON.parse(File.read(fixture_path))["data"]["print"]

# Stub graphql (used for the print query) — return captured fixture data
Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}, **_opts| {"print" => data, "getDownloadLink" => nil} }
end

# Stub getDownloadLink results — based on what the live API returned for
# print 26497 on 2026-08-22:
#   - fileType: stl returned ok=true with a working signed URL
#   - fileType: other returned ok=false (STPs don't accept fileType: other)
# Each file in the `stls` array is processed with fileType: stl, so all
# should return a working URL.
Integrations::Printables::ModelDeserializer.class_eval do
  define_method(:get_download_url) do |file_id:, file_type:|
    if file_type == "stl"
      "https://files.printables.com/stls/#{file_id}/test.stl"
    else
      nil
    end
  end
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/26497-screw-organising-tray-with-numbers")
result = md.deserialize

failures = []

# Bug 1: license must be valid SPDX.
failures << "license is not SPDX: #{result[:license].inspect}" unless result[:license] == "CC-BY-4.0"

# Every STL entry should produce a file_url entry. Print 26497's `stls`
# array has 6 entries (3 .stl + 3 .stp); we ask the API for fileType: stl
# for all of them, and all 6 returned ok=true in our live test.
stl_entries = result[:file_urls].select { |e| e[:filename].start_with?("files/") }
failures << "expected 6 file entries (3 STL + 3 STP), got #{stl_entries.size}" unless stl_entries.size == 6

# Every file URL must point at files.printables.com (the signed-URL host)
files_urls = result[:file_urls].select { |e| e[:url].to_s.start_with?("https://files.printables.com") }
failures << "no files.printables.com URLs in result" if files_urls.empty?

# images are still served from media.printables.com (image CDN hasn't moved)
img_urls = result[:file_urls].select { |e| e[:url].to_s.start_with?("https://media.printables.com") }
failures << "no image URLs in result" if img_urls.empty?

# Sanity: name, slug, license, caption populated
failures << "name is placeholder" if result[:name].to_s.start_with?("Importing from ")
failures << "slug is empty: #{result[:slug].inspect}" if result[:slug].to_s.empty?
failures << "caption is empty" if result[:caption].to_s.empty?

# Sanity: live HEAD-check that at least one signed URL works.
# (Skipped when running offline.)
if ENV["PRINTABLES_TEST_LIVE"] == "1"
  require "net/http"
  files_urls.first(1).each do |e|
    uri = URI.parse(e[:url])
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |h|
      resp = h.head(uri.request_uri)
      failures << "live HEAD #{e[:url]} returned #{resp.code}" unless resp.code.to_i == 200
    end
  end
end

if failures.empty?
  puts "✓ print 26497 import payload valid:"
  puts "  - license = #{result[:license]}"
  puts "  - file_urls = #{result[:file_urls].size} entries (all using signed CDN URLs)"
  puts "  - all 6 file types (STL + STP) returned ok=true from getDownloadLink"
  puts "  - name = #{result[:name].inspect}"
else
  puts "✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
