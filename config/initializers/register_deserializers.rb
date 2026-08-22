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

  # Prepend our views directory so app/views/imports/new.html.erb (which
  # adds a Printables entry to the Supported Sites list on /imports/new)
  # is found before Manyfold's upstream version. See the comment at the
  # top of that view file for sync requirements.
  plugin_views_dir = File.expand_path("../../app/views", __dir__)
  if Dir.exist?(plugin_views_dir)
    # ActionController::Base.prepend_view_path mutates the controller's
    # view_paths in place (it has done so since Rails 3) and is the
    # supported way to extend view lookup from a gem / plugin.
    ActionController::Base.prepend_view_path(plugin_views_dir)
    Rails.logger.info "[manyfold_printables] view path prepended: #{plugin_views_dir}"
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

  # ---------------------------------------------------------------------------
  # Authenticated download support for newer prints.
  #
  # Many newer prints (since ~2024) live behind Printables' authenticated
  # download flow: the public CDN returns 404 for the derived URLs. If the
  # user has set PRINTABLES_SESSION_COOKIE, we want to fetch those files
  # with the cookie included.
  #
  # The patch targets ModelFile#update_from_url! (the Manyfold method that
  # calls Shrine's assign_remote_url). It detects URLs on printables' CDN
  # host and substitutes a custom downloader that includes the session
  # cookie. Other URLs are passed through unchanged.
  #
  # Only applies when PRINTABLES_SESSION_COOKIE is set. If unset, the
  # patch is a no-op (downloads behave exactly as before).
  if defined?(::ModelFile) && !ENV["PRINTABLES_SESSION_COOKIE"].to_s.empty?
    ::ModelFile.prepend(Module.new do
      def update_from_url!(url:)
        return super unless url.to_s.include?("media.printables.com")
        cookie = ENV["PRINTABLES_SESSION_COOKIE"]
        # Custom downloader callable. Shrine invokes it as
        # downloader.call(url, **options). We fetch with Net::HTTP and the
        # session cookie, then return a StringIO that Shrine can ingest via
        # attach_cached. If the response is non-2xx, raise a Down-like error
        # so Shrine marks the download as failed.
        downloader_with_cookie = ->(u, **_opts) {
          uri = URI.parse(u)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 10
          http.read_timeout = 60
          req = Net::HTTP::Get.new(uri.request_uri)
          req["Cookie"] = cookie
          req["User-Agent"] = "Manyfold/#{ManyfoldPrintables::VERSION} (+manyfold_printables plugin)"
          resp = http.request(req)
          unless resp.code.to_i.between?(200, 299)
            raise Shrine::Plugins::RemoteUrl::DownloadError,
                  "HTTP #{resp.code} — cookie may be expired or print is private"
          end
          StringIO.new(resp.body)
        }
        save! if attachment_attacher.assign_remote_url(
          url,
          downloader: downloader_with_cookie
        )
      end
    end)
    Rails.logger.info "[manyfold_printables] ModelFile#update_from_url! prepended (authenticated downloads enabled)"
  end
end
