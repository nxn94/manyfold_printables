# Test: print with only 3MF under /previews/ (not CDN-downloadable) gets
# the 3MF entry skipped via HEAD check, with a clear log message.

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

# Stub Rails.logger to capture log output
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

# Stub Net::HTTP BEFORE loading plugin files. HEAD returns 200 for .stl, 404 for anything else.
class Net::HTTP
  alias_method :_orig_head, :head
  def head(path)
    response = Object.new
    response.define_singleton_method(:code) { path.include?(".stl") ? "200" : "404" }
    response
  end
end

PLUGIN = "/home/nxn/projects/manyfold_printables/app/deserializers/integrations/printables"
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"
require "#{PLUGIN}/creator_deserializer.rb"

# Now stub graphql to return a print that has both an STL (downloadable) and a 3MF (not).
Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) do |_q, _v = {}|
    {"print" => {
      "id" => "99999",
      "name" => "Test Print With 3MF",
      "slug" => "test-print-3mf",
      "summary" => "",
      "description" => "",
      "nsfw" => false,
      "tags" => [],
      "license" => {"id" => "1", "name" => "X"},
      "image" => {"id" => "1", "filePath" => "media/prints/99999/images/x/y.jpg"},
      "images" => [{"id" => "1", "filePath" => "media/prints/99999/images/x/y.jpg"}],
      "stls" => [
        # Real STL
        {"id" => "1", "name" => "thing.stl", "filePreviewPath" => "media/prints/99999/stls/uuid/thing_preview.png"},
        # 3MF under /stls/ — derived URL 404s per our CDN test
        {"id" => "2", "name" => "thing.3mf", "filePreviewPath" => "media/prints/99999/stls/uuid/thing_preview.png"},
      ],
      "slas" => [],
      "gcodes" => [],
      "user" => {"id" => "1", "handle" => "h", "publicUsername" => "h", "avatarFilePath" => nil}
    }}
  end
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/99999-test-print-3mf")
result = md.deserialize

failures = []

puts "Total file_urls: #{result[:file_urls].size}"
result[:file_urls].each { |e| puts "  #{e[:filename]} -> #{e[:url][0,100]}" }

# Expected: 1 STL accepted, 1 3MF rejected via HEAD, 1 image accepted = 2 entries
failures << "expected 2 file entries (1 STL + 1 image, 3MF skipped), got #{result[:file_urls].size}" unless result[:file_urls].size == 2

# The 3MF should have been skipped with a clear log message
log = Rails.logger.messages
skipped_logs = log.select { |m| m.include?("skipping") && m.include?(".3mf") }
puts "Skip log messages:"
skipped_logs.each { |m| puts "  #{m[0,200]}" }
failures << "expected 1 skip log message for 3MF, got #{skipped_logs.size}" unless skipped_logs.size == 1

if failures.empty?
  puts "\n✓ 3MF skip via HEAD check works correctly."
  puts "  - STL accepted, 3MF skipped with log message"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
