# Register Printables deserializers into the Link lookup table.
#
# Manyfold's plugin contract doesn't yet expose a public hook for adding
# `Integrations::*` deserializers. The core Link model hardcodes the list of
# deserializers it knows about, so this plugin prepends two classes (a Model
# deserializer and a Creator deserializer) into that list at boot time. The
# prepend happens before any Link sync can run, so it is race-free at boot.
#
# If the Manyfold team later adds a public `PluginManager.register_deserializer`
# hook, this initializer can be dropped and replaced by that registration.

Rails.application.config.after_initialize do
  next if Rails.env.test?

  Link.singleton_class.prepend(Module.new do
    def deserializer_for(url:, for_class: nil)
      # Our deserializers go first so Printables URLs are matched before the
      # generic Cults3d/Thingiverse/MyMiniFactory list runs.
      additional = [
        Integrations::Printables::ModelDeserializer,
        Integrations::Printables::CreatorDeserializer
      ]
      (additional + super(url: url, for_class: for_class)).map do |klass|
        klass.new(uri: url)
      end.find { |it| it.valid?(for_class: for_class) }
    end
  end)
end
