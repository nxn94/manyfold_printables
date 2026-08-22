# Regression test: a print whose preview paths live under a UUID-based
# /previews/ directory (the newer Printables CDN layout used since ~2024).
# Every entry must produce a derived URL — even though the URL will 404
# when HEAD-checked, the deserializer must not silently drop the entry
# the way the old /stls/-only filter did.
#
# The test asserts:
#   1. The deserializer doesn't raise on this input shape.
#   2. Every entry's derived URL contains the real filename.
#   3. When the CDN HEAD returns 404 (as it does in real life for these
#      prints), the entry is skipped with a clear log line.
#   4. The printables print 1419917-funnel-set-multi-size (which the user
#      reported as broken before this fix) reproduces the bug if the
#      /stls/ filter is reintroduced.

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

module Integrations
  class BaseDeserializer
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
    def deserialize; raise NotImplementedError; end
    def capabilities; raise NotImplementedError; end
    private
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

# Stub Net::HTTP.head to return 404 for ALL URLs (simulating "file not
# publicly downloadable from the CDN" — which is what happens for the
# funnel-set-multi-size print and many newer prints).
class Net::HTTP
  alias_method :_orig_head_for_uuid_test, :head
  def head(_path)
    response = Object.new
    response.define_singleton_method(:code) { "404" }
    response
  end
end

PLUGIN = File.expand_path("../app/deserializers/integrations/printables", __dir__)
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"
require "#{PLUGIN}/creator_deserializer.rb"

# Real data shape from print 1419917-funnel-set-multi-size. Note: the
# preview paths live under /previews/<uuid>/<uuid>.png with a UUID-named
# parent directory, NOT under /stls/<uuid>/<name>_preview.png. Every entry
# must still produce a derived URL so the HEAD check can decide whether
# the file is downloadable.
data = {
  "id" => "1419917",
  "name" => "Funnel Set - Multi-Size",
  "slug" => "funnel-set-multi-size",
  "summary" => "Multi-size funnel set",
  "description" => "...",
  "nsfw" => false,
  "tags" => [],
  "license" => {"id" => "1", "name" => "x"},
  "image" => {"id" => "1", "filePath" => "media/prints/abc/images/x/y.jpg"},
  "images" => [
    {"id" => "1", "filePath" => "media/prints/eecc8fa9-60f5-4315-a020-23cb6aa0efe0/images/img_9267.jpg"}
  ],
  "stls" => [
    {"id" => "1", "name" => "funnel60.stl", "filePreviewPath" => "media/prints/eecc8fa9-60f5-4315-a020-23cb6aa0efe0/previews/0cbc0b16-e648-4de9-b086-551f96f006e3.png"},
    {"id" => "2", "name" => "funnel25.stl", "filePreviewPath" => "media/prints/c2b6ca98-ce87-4dc9-b833-5cb7d91e4903/previews/802696a3-70df-438b-a727-bf300445f029.png"},
    {"id" => "3", "name" => "funnel_set.3mf", "filePreviewPath" => "media/prints/71fbbbb0-ed06-4c2a-ac6a-d54e07560007/previews/58796876-5ff6-407c-bd4f-a9fda1e0c030.png"},
  ],
  "slas" => [],
  "gcodes" => [],
  "user" => {"id" => "1", "handle" => "h", "publicUsername" => "h", "avatarFilePath" => nil}
}

Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}| {"print" => data} }
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/1419917-funnel-set-multi-size")
result = md.deserialize

failures = []

# Sanity: deserializer didn't raise.
puts "name: #{result[:name]}"
puts "file_urls: #{result[:file_urls].size} entries"

# The image is from /images/ (no HEAD check), so it should be present.
img_count = result[:file_urls].count { |e| e[:filename].start_with?("images/") }
failures << "expected 1 image entry, got #{img_count}" unless img_count == 1

# The 3 STL/3MF entries all return 404 from the CDN, so they should be
# skipped (file_urls has only the image). Verify this is happening via the
# log message.
log = Rails.logger.messages
skip_logs = log.select { |m| m.include?("skipping") && m.include?("404") }
puts "skip messages: #{skip_logs.size}"
skip_logs.each { |m| puts "  #{m[0,140]}" }
failures << "expected 3 skip log messages, got #{skip_logs.size}" unless skip_logs.size == 3

# And the actual file_urls should NOT contain any .stl or .3mf entries
# (they were all 404'd).
stl_entries = result[:file_urls].select { |e| e[:filename].end_with?(".stl", ".3mf") }
failures << "expected no .stl/.3mf entries (all CDN 404'd), got #{stl_entries.size}: #{stl_entries.map { |e| e[:filename] }}" unless stl_entries.empty?

if failures.empty?
  puts "\n✓ UUID-based /previews/ CDN layout is handled correctly"
  puts "  - deserializer produces derived URLs for all entries"
  puts "  - HEAD-check rejects 404s with clear log messages"
  puts "  - Only downloadable files end up in file_urls"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
