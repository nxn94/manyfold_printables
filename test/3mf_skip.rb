# Test: the deserializer correctly handles the case where some files
# in a print return ok=false from getDownloadLink. The print still
# imports (metadata, tags, license, images, etc.) but those files are
# skipped with a clear log message.

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

data = {
  "id" => "99999",
  "name" => "Mixed Files Test",
  "slug" => "mixed-files",
  "summary" => "test",
  "description" => "...",
  "nsfw" => false,
  "tags" => [],
  "license" => {"id" => "1", "name" => "x"},
  "image" => {"id" => "1", "filePath" => "media/prints/abc/images/x/y.jpg"},
  "images" => [
    {"id" => "1", "filePath" => "media/prints/abc/images/x/y.jpg"}
  ],
  "stls" => [
    # Two STLs that getDownloadLink works for, one that fails.
    {"id" => "1", "name" => "thing_a.stl", "fileSize" => 100},
    {"id" => "2", "name" => "thing_b.stl", "fileSize" => 100},
    {"id" => "3", "name" => "thing_c.stl", "fileSize" => 100}
  ],
  "slas" => [],
  "gcodes" => [],
  "otherFiles" => [],
  "user" => {"id" => "1", "handle" => "h", "publicUsername" => "h", "avatarFilePath" => nil}
}

Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}, **_opts| {"print" => data} }
end

# Stub get_download_url to fail for file_id=2 only
Integrations::Printables::ModelDeserializer.class_eval do
  define_method(:get_download_url) do |file_id:, file_type:|
    if file_id == "2"
      nil  # Simulates getDownloadLink returning ok=false
    else
      "https://files.printables.com/stls/#{file_id}/test.stl"
    end
  end
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/99999-test")
result = md.deserialize

failures = []

# Two of three STLs should appear (file_id=2 fails).
stl_entries = result[:file_urls].select { |e| e[:filename].start_with?("files/") }
failures << "expected 2 file entries (file_id=2 skipped), got #{stl_entries.size}" unless stl_entries.size == 2
failures << "expected entries for thing_a.stl and thing_c.stl, got #{stl_entries.map { |e| e[:filename] }}" unless stl_entries.map { |e| e[:filename] }.sort == ["files/thing_a.stl", "files/thing_c.stl"]

# The image is still present.
img_entries = result[:file_urls].select { |e| e[:filename].start_with?("images/") }
failures << "expected 1 image entry, got #{img_entries.size}" unless img_entries.size == 1

# Skip message logged for the failed file. log_skip prints "[manyfold_printables] <msg>"
# but we strip the prefix before substring matching so the test stays decoupled
# from the exact prefix.
log = Rails.logger.messages
skip_logs = log.select { |m| m.include?("skipping") && m.include?("thing_b.stl") }
failures << "expected skip log for thing_b.stl, got: #{log.inspect}" unless skip_logs.size == 1

if failures.empty?
  puts "✓ getDownloadLink ok=false is handled correctly:"
  puts "  - 2 of 3 STLs imported (third one skipped)"
  puts "  - Image still imported"
  puts "  - Skip message logged with file name"
else
  puts "✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
