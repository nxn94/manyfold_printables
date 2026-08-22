# Schema guard test: every key the ModelDeserializer returns must be either
# (a) a real Model column in Manyfold's schema, or
# (b) one of the special keys Manyfold's UpdateMetadataFromLinkJob knows how
#     to handle separately (creator_attributes, file_urls, preview_filename),
#     or
# (c) a virtual attribute like `tag_list` from acts_as_taggable_on.
#
# If we ever add a new key that isn't one of those, this test fails — that's
# what bit us with `summary` (which Manyfold's Model doesn't have).

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

class Model; end
class Creator; end
require "net/http"; require "json"; require "uri"; require "cgi"
require "set"

module Faraday
  class ResourceNotFound < StandardError; def initialize(m = "Not Found"); super(m); end; end
  class Error < StandardError; end
end
module ManyfoldPrintables; VERSION = "0.1.0"; end

PLUGIN = File.expand_path("../app/deserializers/integrations/printables", __dir__)
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"
require "#{PLUGIN}/creator_deserializer.rb"

# Authoritative Model columns (from db/migrate/* in the manyfold repo at
# v0.146.0+, the minimum version this plugin supports).
#
# History:
#   - 20230202210000 added `notes` and `excerpt`
#   - 20230222155910 renamed `excerpt` to `caption` on models/creators/model_files
#   - 20241017093301 added `sensitive` to models and comments
# So `caption` is the right column, not `excerpt` or `summary`.
#
# Keep this in sync when Manyfold adds migrations.
KNOWN_MODEL_COLUMNS = %w[
  id name path library_id creator_id created_at updated_at preview_file_id
  entrypoint_id entrypoint_fragment notes caption license slug like_count
  collection_id sensitive
].to_set

# Virtual attributes & special keys Manyfold accepts beyond the column set.
SPECIAL_KEYS = %i[creator_attributes file_urls preview_filename tag_list].to_set

# Stub graphql() with real captured data.
captured_path = ENV["PRINTABLES_CAPTURED"] || File.expand_path("fixtures/print_46705.json", __dir__)
unless File.exist?(captured_path)
  abort "Captured GraphQL response not found at #{captured_path}. " \
        "Run tools/capture_printables.rb to produce one."
end
fake_data = JSON.parse(File.read(captured_path))["data"]["print"]
Integrations::Printables::BaseDeserializer.class_eval do
  define_method(:graphql) { |_q, _v = {}| {"print" => fake_data} }
end

md = Integrations::Printables::ModelDeserializer.new(uri: "https://www.printables.com/model/46705")
result = md.deserialize

unknown = result.keys.reject { |k| KNOWN_MODEL_COLUMNS.include?(k.to_s) || SPECIAL_KEYS.include?(k) }
if unknown.empty?
  puts "✓ All Model keys valid."
  puts "  Columns used: #{result.keys.select { |k| KNOWN_MODEL_COLUMNS.include?(k.to_s) }.sort.inspect}"
  puts "  Special keys: #{result.keys.select { |k| SPECIAL_KEYS.include?(k) }.sort.inspect}"
else
  puts "✗ UNKNOWN Model keys: #{unknown.inspect}"
  exit 1
end

# Creator check
fake_user = {"id" => "1", "handle" => "x", "publicUsername" => "x", "avatarFilePath" => nil}
parsed = Integrations::Printables::CreatorDeserializer.parse(fake_user)
KNOWN_CREATOR_COLUMNS = %w[
  id name slug created_at updated_at notes avatar_data banner_data
  avatar_remote_url banner_remote_url
].to_set
unknown_c = parsed.keys.reject do |k|
  KNOWN_CREATOR_COLUMNS.include?(k.to_s) ||
    [:links_attributes, :avatar_remote_url, :banner_remote_url].include?(k)
end
if unknown_c.empty?
  puts "✓ All Creator keys valid."
else
  puts "✗ UNKNOWN Creator keys: #{unknown_c.inspect}"
  exit 1
end
