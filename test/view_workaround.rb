# Test the Link#deserializer workaround: returning nil for Printables
# deserializers to avoid the Manyfold/Phlex rendering bug.

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

module Integrations
  class BaseDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
    def deserialize; raise NotImplementedError; end
    def capabilities; raise NotImplementedError; end
    private
    def attempt_creator_match(attrs); {creator_attributes: attrs}; end
  end
end
class Model; end; class Creator; end
module Faraday; class ResourceNotFound < StandardError; def initialize(m = "Not Found"); super(m); end; end; class Error < StandardError; end; end
module ManyfoldPrintables; VERSION = "0.1.0"; end

# Stub Rails for the initializer
module Rails
  class Application
    def config; @config ||= Configuration.new; end
    class Configuration
      def after_initialize(&blk); @inits ||= []; @inits << blk; end
      def run_inits!; @inits&.each(&:call); end
    end
    def self.env; ActiveSupport::StringInquirer.new("development"); end
  end
  def self.env; ActiveSupport::StringInquirer.new("development"); end
  class << self; attr_accessor :application; end
end
module ActiveSupport
  class StringInquirer < String
    def test?(*); false; end
    def development?; true; end
    def test; false; end
  end
end
Rails.application = Rails::Application.new

# Stub minimal Link with both a class method (deserializer_for) AND an
# instance method (deserializer) — both must be properly stubbed so the
# initializer's prepended modules don't break the test.
class Link
  def self.deserializer_for(url:, for_class: nil)
    return nil if url.nil? || url.empty?
    # Pick a built-in stub for non-printables URLs
    if url.include?("thingiverse.com")
      Integrations::Thingiverse::ModelDeserializer.new(uri: url)
    elsif url.include?("cults3d.com")
      Integrations::Cults3d::ModelDeserializer.new(uri: url)
    end
  end

  attr_accessor :url, :linkable
  def initialize(url:, linkable:)
    @url = url
    @linkable = linkable
  end

  def deserializer
    self.class.deserializer_for(url: url, for_class: linkable.class)
  end
end

module Integrations::Cults3d
  class ModelDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
  end
end

module Integrations::Thingiverse
  class ModelDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
  end
end

module Integrations::Printables
  class BaseDeserializer < Integrations::BaseDeserializer; end
  class ModelDeserializer < Integrations::Printables::BaseDeserializer
    def valid?(for_class: nil)
      uri = @uri.to_s
      !uri.empty? && uri.include?("printables.com/model/")
    end
  end
  class CreatorDeserializer < Integrations::Printables::BaseDeserializer
    def valid?(for_class: nil)
      uri = @uri.to_s
      !uri.empty? && uri.include?("printables.com/@")
    end
  end
end

require "/home/nxn/projects/manyfold_printables/config/initializers/register_deserializers.rb"
Rails.application.config.run_inits!

failures = []

# 1. Printables URL -> Link#deserializer returns nil (view workaround)
link = Link.new(url: "https://www.printables.com/model/26497-...", linkable: Model.new)
d = link.deserializer
puts "Printables Link#deserializer = #{d.inspect}"
failures << "printables link deserializer should be nil (got #{d.class})" unless d.nil?

# 2. Thingiverse URL -> still works via super
link2 = Link.new(url: "https://www.thingiverse.com/thing:12345", linkable: Model.new)
d2 = link2.deserializer
puts "Thingiverse Link#deserializer = #{d2.class}"
failures << "thingiverse deserializer should still return a built-in instance (got #{d2.inspect})" unless d2.is_a?(Integrations::Thingiverse::ModelDeserializer)

# 3. Cults3D URL -> still works via super
link3 = Link.new(url: "https://cults3d.com/en/3d-model/3d-model/foo", linkable: Model.new)
d3 = link3.deserializer
puts "Cults3D Link#deserializer = #{d3.class}"
failures << "cults3d deserializer should still work (got #{d3.inspect})" unless d3.is_a?(Integrations::Cults3d::ModelDeserializer)

# 4. Unknown URL -> Link#deserializer returns nil
link4 = Link.new(url: "https://example.com/foo", linkable: Model.new)
d4 = link4.deserializer
puts "Unknown URL Link#deserializer = #{d4.inspect}"
failures << "unknown url deserializer should be nil (got #{d4.inspect})" unless d4.nil?

# 5. CRITICAL: but Link.deserializer_for (class method) still returns our instance
# (because the class-method prepend is unchanged). This is the path used by
# CreateObjectFromUrlJob and UpdateMetadataFromLinkJob, which is what we want.
url = "https://www.printables.com/model/26497-..."
df = Link.deserializer_for(url: url, for_class: Model)
puts "Link.deserializer_for(#{url}) = #{df.class}"
failures << "class-method deserializer_for should return ModelDeserializer" unless df.is_a?(Integrations::Printables::ModelDeserializer)

if failures.empty?
  puts "\n✓ View rendering workaround works correctly."
  puts "  - Link#deserializer returns nil for Printables (page renders fine)"
  puts "  - Link.deserializer_for still returns Printables instance (sync job works)"
  puts "  - Built-in URLs (Thingiverse, Cults3D) untouched"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
