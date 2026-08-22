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
end
