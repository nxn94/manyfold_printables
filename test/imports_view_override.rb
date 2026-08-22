# Test: the plugin's app/views/imports/new.html.erb exists, contains the
# Printables entry, and is structurally identical to the upstream
# Manyfold imports/new.html.erb except for that single addition.

PLUGIN_VIEWS = File.expand_path("../app/views/imports/new.html.erb", __dir__)
UPSTREAM_VIEWS_GLOB = "/tmp/manyfold-research/manyfold/app/views/imports/new.html.erb"

failures = []

unless File.exist?(PLUGIN_VIEWS)
  abort "Missing plugin view: #{PLUGIN_VIEWS}"
end

plugin_content = File.read(PLUGIN_VIEWS)

# 1. The plugin view contains a Printables entry with ✅ (no API key needed).
unless plugin_content.match?(/<li>\s*✅\s*<%= t\s+"sites\.printables"/)
  failures << "plugin view is missing the Printables entry in the Supported Sites list"
end

# 2. The plugin view includes the sync comment.
unless plugin_content.include?("Printables is provided by the manyfold_printables plugin")
  failures << "plugin view is missing the sync comment explaining what changed"
end

# 3. The plugin view is structurally a superset of the upstream view:
#    every line that exists upstream must exist in the plugin view.
if File.exist?(UPSTREAM_VIEWS_GLOB)
  upstream_content = File.read(UPSTREAM_VIEWS_GLOB)
  upstream_lines = upstream_content.lines.map(&:rstrip).reject(&:empty?)
  plugin_lines = plugin_content.lines.map(&:rstrip).reject(&:empty?)

  # Drop the Printables entry AND the file-header comment block from the
  # plugin side before comparing, so we only flag genuine structural drift.
  filtered_plugin = plugin_lines.reject do |line|
    line.include?("Printables is provided by the manyfold_printables plugin") ||
      line.include?("Always shown as ✅ because no API key is required") ||
      line.match?(/\A\s*<li>✅ <%= t "sites\.printables".*\z/) ||
      line.match?(/\A\s*<%#\s*$/) ||
      line.match?(/\A\s*Printables serves `.3mf`/) ||
      line.match?(/\A\s*authenticated web download flow/) ||
      line.match?(/\A\s*limitation, not a plugin limitation\.\s*$/) ||
      line.include?("Override of Manyfold's app/views/imports/new.html.erb") ||
      line.include?("This file MUST be kept in sync with the upstream version") ||
      line.include?("intentional change is the addition") ||
      line.include?("If Manyfold adds new integrations to its imports/new.html.erb") ||
      line.include?("Last synced with Manyfold") ||
      line.include?("Supported Sites list (always") ||
      line.include?("those additions here too") ||
      line.rstrip == "%>"
  end

  upstream_only = upstream_lines - filtered_plugin
  plugin_only = filtered_plugin - upstream_lines

  unless upstream_only.empty?
    failures << "plugin view is missing #{upstream_only.size} lines from upstream: #{upstream_only.first(3).inspect}"
  end
  unless plugin_only.empty?
    # Allow only one extra line: the Printables list entry.
    if plugin_only.size > 1
      failures << "plugin view has #{plugin_only.size} unexpected additions: #{plugin_only.first(3).inspect}"
    end
  end
else
  puts "  (skipping upstream comparison: #{UPSTREAM_VIEWS_GLOB} not found)"
end

if failures.empty?
  puts "✓ plugin's imports/new.html.erb is structurally a superset of upstream + adds Printables entry"
else
  puts "✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
