# Test: assert the deserializer's slugify produces correct output across
# edge cases. Guards against accidental behaviour changes when swapping
# the regex-based implementation for tr+squeeze+gsub (which we did to
# silence a code-scanning polynomial-regex DoS warning).

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

module Integrations
  class BaseDeserializer
    def initialize(uri:); @uri = uri; end
  end
end

PLUGIN = File.expand_path("../app/deserializers/integrations/printables", __dir__)
require "#{PLUGIN}/base_deserializer.rb"
require "#{PLUGIN}/model_deserializer.rb"

# Inputs chosen to exercise edge cases:
#  - simple ASCII
#  - uppercase (must downcase)
#  - mixed special chars (must collapse runs)
#  - leading/trailing dashes (must trim)
#  - only special chars (must return nil)
#  - nil (must return nil)
#  - empty string (must return nil)
#  - non-ASCII letters → stripped, then trimmed
#  - runs of internal dashes
inputs = [
  ["Battery Tray", "battery-tray"],
  ["SCREW ORGANISING TRAY", "screw-organising-tray"],
  ["Hello, World!", "hello-world"],
  ["---abc---", "abc"],
  ["!@#$%^&*()", nil],
  ["---", nil],
  ["", nil],
  [nil, nil],
  ["a-b-c-d", "a-b-c-d"],
  ["a---b", "a-b"],
  ["Café", "caf"]
]

md = Integrations::Printables::ModelDeserializer.new(uri: "x")

failures = []
inputs.each do |input, expected|
  actual = md.send(:slugify, input)
  if actual != expected
    failures << "slugify(#{input.inspect}) returned #{actual.inspect}, expected #{expected.inspect}"
  end
end

if failures.empty?
  puts "✓ slugify produces expected output for #{inputs.size} inputs"
else
  puts "✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
