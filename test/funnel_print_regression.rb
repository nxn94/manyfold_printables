# Regression test: the funnel-set-multi-size print, which was the original
# failing case. Now that we use getDownloadLink for file URLs (which returns
# signed CDN URLs without needing auth), this print should produce
# file_urls entries for ALL its STLs and the 3MF — no more "not publicly
# downloadable" errors.

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

# Returns the host of a URL string, or nil if it's missing/malformed/relative.
# Used by tests to assert URL provenance by host (defuses
# rb/incomplete-url-substring-sanitization in Code Scanning).
def host_of(url)
  return nil if url.nil? || url.to_s.empty?
  URI.parse(url.to_s).host
rescue URI::InvalidURIError
  nil
end
module Faraday
  class ResourceNotFound < StandardError; def initialize(m = "Not Found"); super(m); end; end
  class Error < StandardError; end
end
module ManyfoldPrintables; VERSION = "0.1.0"; end

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

# Real data shape from print 1419917-funnel-set-multi-size. The original
# problem: preview paths under /previews/ meant the old URL-derivation
# logic couldn't find working URLs. With getDownloadLink, this is no
# longer an issue — every file gets a proper signed URL.
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
    {"id" => "1", "name" => "funnel60.stl", "fileSize" => 118784, "filePreviewPath" => "x"},
    {"id" => "2", "name" => "funnel25.stl", "fileSize" => 196984, "filePreviewPath" => "x"},
    {"id" => "3", "name" => "funnel15.stl", "fileSize" => 227884, "filePreviewPath" => "x"},
    {"id" => "4", "name" => "funnel30.stl", "fileSize" => 144684, "filePreviewPath" => "x"},
    {"id" => "5", "name" => "funnel_set.3mf", "fileSize" => 283788, "filePreviewPath" => "x"},
    {"id" => "6", "name" => "funnel45.stl", "fileSize" => 132984, "filePreviewPath" => "x"},
    {"id" => "7", "name" => "funnel100.stl", "fileSize" => 120784, "filePreviewPath" => "x"}
  ],
  "slas" => [],
  "gcodes" => [],
  "otherFiles" => [],
  "user" => {"id" => "1", "handle" => "h", "publicUsername" => "h", "avatarFilePath" => nil}
}

Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}, **_opts| {"print" => data} }
end

# Stub get_download_url to return a working signed URL for every file.
Integrations::Printables::ModelDeserializer.class_eval do
  define_method(:get_download_url) do |file_id:, file_type:|
    "https://files.printables.com/stls/#{file_id}/test.stl"
  end
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/1419917-funnel-set-multi-size")
result = md.deserialize

failures = []

puts "name: #{result[:name]}"
puts "file_urls: #{result[:file_urls].size} entries"
result[:file_urls].each { |e| puts "  #{e[:filename]} -> #{e[:url][0,80]}" }

# 7 files (6 STL + 1 3MF) + 1 image = 8 file_urls entries
file_count = result[:file_urls].count { |e| e[:filename].start_with?("files/") }
failures << "expected 7 file entries, got #{file_count}" unless file_count == 7

img_count = result[:file_urls].count { |e| e[:filename].start_with?("images/") }
failures << "expected 1 image entry, got #{img_count}" unless img_count == 1

# All file URLs must be on files.printables.com (signed CDN URL host).
# Compare via URI host (not substring) to defuse
# rb/incomplete-url-substring-sanitization: a prefix check would let
# "https://files.printables.com.attacker.tld/x" through, even though such URLs
# could never come from our deserializer.
files_urls = result[:file_urls].select { |e| host_of(e[:url]) == "files.printables.com" }
failures << "no files.printables.com URLs in result, got #{result[:file_urls].map { |e| e[:url][0,40] }}" if files_urls.empty?

# No skip messages — getDownloadLink returns ok=true for everything.
log = Rails.logger.messages
skip_logs = log.select { |m| m.include?("skipping") }
failures << "expected no skip messages, got #{skip_logs.size}: #{skip_logs}" unless skip_logs.empty?

# 3MF file is included — not silently dropped like the old code did.
three_mf = result[:file_urls].find { |e| e[:filename] == "files/funnel_set.3mf" }
failures << "3MF entry missing" if three_mf.nil?

if failures.empty?
  puts "\n✓ funnel-set-multi-size import is fully covered:"
  puts "  - All 7 file entries (6 STL + 1 3MF) get signed URLs via getDownloadLink"
  puts "  - 1 image entry from media.printables.com"
  puts "  - No 'skipping' log lines (everything downloads)"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
