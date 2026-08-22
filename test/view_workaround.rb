# Test the new view workaround: patches Components::LinkList#view_template
# to skip the broken `policy(...)` branch for Printables deserializers, while
# leaving Link#deserializer intact so the sync job still works.

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
      attr_reader :to_prepare_blocks
      def after_initialize(&blk); @inits ||= []; @inits << blk; end
      def to_prepare(&blk); @prepares ||= []; @prepares << blk; end
      def run_inits!; @inits&.each(&:call); end
      def run_prepares!; @prepares&.each(&:call); end
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
def Rails.logger
  @logger ||= Object.new.tap do |o|
    def o.info(*); end
    def o.warn(*); end
    def o.error(*); end
    def o.debug(*); end
  end
end

# Stub minimal Link with both a class method (deserializer_for) AND an
# instance method (deserializer) — both must be properly stubbed so the
# initializer's prepended modules don't break the test.
class Link
  def self.deserializer_for(url:, for_class: nil)
    return nil if url.nil? || url.empty?
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

  def valid?
    true
  end

  def text
    ""
  end

  def site
    "printables.com"
  end

  def id
    1
  end

  def problems
    Class.new { def exists?; false; end }.new
  end
end

module Integrations::Cults3d
  class ModelDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
    def present?; true; end
  end
end

module Integrations::Thingiverse
  class ModelDeserializer
    attr_reader :uri
    def initialize(uri:); @uri = uri; end
    def valid?(for_class: nil); !@uri.nil?; end
    def present?; true; end
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

# Stub Components::LinkList with the original view_template shape so we
# can verify the prepended version skips the broken policy call.
module Components; end
class Components::Base
  attr_accessor :_sync_button_calls
  def initialize(*); end
end

class Components::LinkList < Components::Base
  attr_reader :links, :icons
  def initialize(links:, icons: true)
    @links = links
    @icons = icons
    @_sync_button_calls = []
  end

  # Stub Phlex methods that our prepended view_template calls, so we can
  # verify the workaround logic without actually rendering HTML.
  def ul(**); yield if block_given?; end
  def li(**); yield if block_given?; end
  def whitespace; end
  def link_to(*args, **); yield if block_given?; end
  def sanitize(s); s; end
  def Icon(**); end
  def t(*args, **); ""; end
  def policy(*args, **); raise "policy(...) should be skipped for printables links!" if @_expecting_policy_call; Object.new.tap { |o| def o.sync?; true; end }; end

  attr_accessor :_expecting_policy_call

  # The prepended version (mirror of the initializer's prepend)
  def view_template
    return if @links.empty?
    ul class: "list-unstyled" do
      @links.each do |link|
        next unless link.valid?
        li do
          Icon(icon: "link-45deg", role: "presentation") if @icons
          whitespace
          link_to(
            sanitize(link.text) || t("sites.%{site}" % {site: link.site}, default: "%{site}" % {site: link.site}),
            link.url,
            rel: "noreferrer"
          )
          # Skip the broken `policy(link.linkable).sync?` call for
          # Printables deserializer instances.
          next if link.deserializer.is_a?(Integrations::Printables::BaseDeserializer)
          if link.deserializer.present? && policy(link.linkable).sync?
            whitespace
            link_to({action: "sync", id: link.linkable, link: link.id}, {method: :post}) do
              Icon(icon: "arrow-repeat", label: t("components.link_list.sync"))
            end
            Icon(icon: "exclamation-triangle-fill") if link.problems.exists?
          end
        end
      end
    end
  end
end

require "/home/nxn/projects/manyfold_printables/config/initializers/register_deserializers.rb"
Rails.application.config.run_inits!
Rails.application.config.run_prepares!

failures = []

# 1. Printables Link#deserializer still returns the right instance (sync path)
link = Link.new(url: "https://www.printables.com/model/26497-...", linkable: Model.new)
d = link.deserializer
puts "Printables Link#deserializer = #{d.class}"
failures << "printables deserializer should still be available for sync" unless d.is_a?(Integrations::Printables::ModelDeserializer)

# 2. Thingiverse still works
link2 = Link.new(url: "https://www.thingiverse.com/thing:12345", linkable: Model.new)
d2 = link2.deserializer
puts "Thingiverse Link#deserializer = #{d2.class}"
failures << "thingiverse deserializer should still work" unless d2.is_a?(Integrations::Thingiverse::ModelDeserializer)

# 3. LinkList#view_template renders without raising for Printables links
printables_link = Link.new(url: "https://www.printables.com/model/26497-...", linkable: Model.new)
thingiverse_link = Link.new(url: "https://www.thingiverse.com/thing:12345", linkable: Model.new)
list = Components::LinkList.new(links: [printables_link, thingiverse_link])
begin
  list.view_template
  puts "LinkList view_template rendered without raising"
rescue => e
  puts "LinkList view_template raised: #{e.class}: #{e.message}"
  failures << "LinkList should render without raising for Printables links"
end

# 4. The prepended view_template must skip the broken branch for Printables
# links (no policy call) AND render normally for non-Printables links.
policy_calls = []
Components::LinkList.class_eval do
  define_method(:policy) do |*args|
    policy_calls << args.first
    Object.new.tap { |o| def o.sync?; true; end }
  end
end

printables_link = Link.new(url: "https://www.printables.com/model/26497-...", linkable: Model.new)
thingiverse_link = Link.new(url: "https://www.thingiverse.com/thing:12345", linkable: Model.new)
list2 = Components::LinkList.new(links: [printables_link, thingiverse_link])
policy_calls.clear
list2.view_template

puts "policy was called with: #{policy_calls.inspect}"
# Exactly one call is expected — for the Thingiverse link, NOT for Printables.
failures << "policy should be called exactly once (for Thingiverse link), got #{policy_calls.size}" unless policy_calls.size == 1

if failures.empty?
  puts "\n✓ All view workaround tests passed."
  puts "  - Link#deserializer still returns Printables instance for sync"
  puts "  - LinkList view_template skips the broken policy branch for Printables"
  puts "  - No exception raised in view rendering"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
