# Register Printables deserializers into the Link lookup table.
#
# Manyfold's plugin contract doesn't yet expose a public hook for adding
# `Integrations::*` deserializers. The core Link model hardcodes the list of
# deserializers it knows about, so this plugin prepends two classes (a Model
# deserializer and a Creator deserializer) into that list at boot time.
#
# The approach: prepend a module on Link's singleton class that tries our
# deserializers first and falls back to the original implementation. This is
# race-free at boot (after_initialize runs before any Link#sync call), and
# it means if Manyfold adds new built-in deserializer classes upstream we
# automatically benefit from them — we never duplicate the upstream class list.
#
# If the Manyfold team later adds a public `PluginManager.register_deserializer`
# hook, this initializer can be dropped and replaced with that registration.

Rails.application.config.after_initialize do
  next if Rails.env.test?

  # Force-load the deserializer classes. They live under our plugin's
  # app/deserializers/ directory, which is NOT in Rails' main autoload paths,
  # so Zeitwerk can't auto-discover them. Without these requires, the
  # constants referenced below would NameError at boot. The constant check
  # is so the plugin's own tests (which pre-load stubs) don't double-require.
  unless defined?(Integrations::Printables::BaseDeserializer)
    require_relative "../../app/deserializers/integrations/printables/base_deserializer"
    require_relative "../../app/deserializers/integrations/printables/model_deserializer"
    require_relative "../../app/deserializers/integrations/printables/creator_deserializer"
  end

  printables_deserializer_classes = [
    Integrations::Printables::ModelDeserializer,
    Integrations::Printables::CreatorDeserializer
  ].freeze

  Link.singleton_class.prepend(Module.new do
    define_method(:deserializer_for) do |url:, for_class: nil|
      # Try our deserializers first. If none matches, fall back to the original
      # implementation (which iterates the built-in Cults3d/Thingiverse/etc list).
      ours = printables_deserializer_classes.map { |klass| klass.new(uri: url) }
      ours.find { |it| it.valid?(for_class: for_class) } ||
        super(url: url, for_class: for_class)
    end
  end)

  # ---------------------------------------------------------------------------
  # View-rendering workaround.
  #
  # Manyfold's Components::LinkList renders a per-link "resync" button when
  # `link.deserializer.present? && policy(link.linkable).sync?` is true. The
  # `policy(...)` Pundit helper is registered as a Phlex value helper, and
  # somewhere in the Phlex 2.4.0 / Manyfold 0.146.0 interaction, calling it
  # with our deserializer instance's linkable raises:
  #
  #   ArgumentError (wrong number of arguments (given 0, expected 1))
  #
  # The link sync itself works fine via CreateObjectFromUrlJob / re-import,
  # so we disable the per-link resync button just for our deserializers to
  # avoid the 500. If Manyfold later exposes a PluginManager.register_deserializer
  # API or fixes the Phlex interaction, this override can be dropped.
  Link.prepend(Module.new do
    def deserializer
      result = super
      return nil if result.is_a?(Integrations::Printables::BaseDeserializer)
      result
    end
  end)
end
