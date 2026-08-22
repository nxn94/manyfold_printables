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

  Rails.logger.info "[manyfold_printables] initializer running"

  # Force-load the deserializer classes. They live under our plugin's
  # app/deserializers/ directory, which is NOT in Rails' main autoload paths,
  # so Zeitwerk can't auto-discover them. Without these requires, the
  # constants referenced below would NameError at boot. The constant check
  # is so the plugin's own tests (which pre-load stubs) don't double-require.
  unless defined?(Integrations::Printables::BaseDeserializer)
    begin
      require_relative "../../app/deserializers/integrations/printables/base_deserializer"
      require_relative "../../app/deserializers/integrations/printables/model_deserializer"
      require_relative "../../app/deserializers/integrations/printables/creator_deserializer"
      Rails.logger.info "[manyfold_printables] deserializer classes loaded"
    rescue => e
      Rails.logger.error "[manyfold_printables] FAILED to load deserializer classes: #{e.class}: #{e.message}"
      raise
    end
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
  Rails.logger.info "[manyfold_printables] Link#deserializer_for prepended with #{printables_deserializer_classes.size} classes"

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
  # Important: `Link#deserializer` is used for TWO unrelated purposes:
  #   1. UpdateMetadataFromLinkJob (needs our deserializer to actually sync)
  #   2. Components::LinkList view rendering (currently 500s for our links)
  #
  # If we make `Link#deserializer` return nil for our deserializers, the sync
  # job silently no-ops. Instead, we patch ONLY LinkList#view_template so the
  # broken `policy(...)` branch is skipped for our links. The sync path is
  # left untouched; users can resync by re-pasting the URL on the Imports
  # page.
  #
  # If Manyfold later exposes PluginManager.register_deserializer or fixes
  # the Phlex interaction, this override can be dropped.
  Rails.application.config.to_prepare do
    if defined?(Components::LinkList)
      Components::LinkList.prepend(Module.new do
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
                # Printables deserializer instances. The "sync" button is
                # suppressed for those links; re-import on /imports/new to
                # refresh.
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
      end)
    end
  end
end
