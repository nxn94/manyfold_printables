# Register Printables deserializers into the Link lookup table.
#
# Manyfold's plugin contract doesn't yet expose a public hook for adding
# `Integrations::*` deserializers. The core Link model hardcodes the list of
# deserializers it knows about, so this plugin prepends two classes (a Model
# deserializer and a Creator deserializer) into that list at boot time.
#
# If the Manyfold team later adds a public `PluginManager.register_deserializer`
# hook, this initializer can be dropped and replaced with that registration.

# ---------------------------------------------------------------------------
# View-rendering workaround (registered via `to_prepare`).
#
# Manyfold's Components::LinkList renders a per-link "resync" button when
# `link.deserializer.present? && policy(link.linkable).sync?` is true. The
# `policy(...)` Pundit helper is registered as a Phlex value helper, and
# somewhere in the Phlex 2.4.0 / Manyfold 0.146.0 interaction, calling it
# with our deserializer instance's linkable raises:
#
#   ArgumentError (wrong number of arguments (given 0, expected 1))
#
# We patch ONLY LinkList#view_template so the broken `policy(...)` branch is
# skipped for Printables deserializer instances. The sync path (Link#deserializer)
# is left untouched; users can resync by re-pasting the URL on the Imports page.
#
# IMPORTANT: this MUST be registered as a top-level `to_prepare` block.
# Putting it inside `after_initialize` is a no-op — by the time
# `after_initialize` callbacks fire in production, `to_prepare` callbacks
# have already been drained.
#
# If Manyfold later exposes PluginManager.register_deserializer or fixes
# the Phlex interaction, this override can be dropped.
Rails.application.config.to_prepare do
  next if Rails.env.test?
  Rails.logger.info "[manyfold_printables] to_prepare running"

  # Force-load the deserializer classes. They live under our plugin's
  # app/deserializers/ directory which is NOT in Rails' main autoload paths,
  # so Zeitwerk can't auto-discover them. Defer the require until here (in
  # to_prepare, after autoloaders are set up + Integrations::BaseDeserializer
  # is autoloadable from the main app) so the require doesn't blow up at
  # initializer-load time before autoloaders are ready.
  unless defined?(Integrations::Printables::BaseDeserializer)
    begin
      require_relative "../../app/deserializers/integrations/printables/base_deserializer"
      require_relative "../../app/deserializers/integrations/printables/model_deserializer"
      require_relative "../../app/deserializers/integrations/printables/creator_deserializer"
    rescue => e
      Rails.logger.error "[manyfold_printables] FAILED to load deserializer classes: #{e.class}: #{e.message}"
      raise
    end
  end

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
    Rails.logger.info "[manyfold_printables] Components::LinkList prepended (view workaround active)"
  else
    Rails.logger.warn "[manyfold_printables] to_prepare ran but Components::LinkList not defined; view workaround skipped"
  end
end

# ---------------------------------------------------------------------------
# Singleton-class prepend for Link.deserializer_for (the class method that
# UpdateMetadataFromLinkJob calls). Done in after_initialize because at that
# point Integrations::BaseDeserializer (the main app's deserializer base) is
# autoloaded and our deserializer subclasses can inherit from it.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  Rails.logger.info "[manyfold_printables] initializer running"

  printables_deserializer_classes = [
    Integrations::Printables::ModelDeserializer,
    Integrations::Printables::CreatorDeserializer
  ].freeze

  Link.singleton_class.prepend(Module.new do
    define_method(:deserializer_for) do |url:, for_class: nil|
      ours = printables_deserializer_classes.map { |klass| klass.new(uri: url) }
      ours.find { |it| it.valid?(for_class: for_class) } ||
        super(url: url, for_class: for_class)
    end
  end)
  Rails.logger.info "[manyfold_printables] Link#deserializer_for prepended with #{printables_deserializer_classes.size} classes"
end
