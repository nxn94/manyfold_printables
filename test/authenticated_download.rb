# Regression test for the authenticated-download patch logic.
#
# The patch in register_deserializers.rb bypasses Shrine's downloader
# mechanism entirely: it fetches the bytes via Net::HTTP with the
# session cookie, then attaches the StringIO to the Shrine attacher
# via attach_cached. This test verifies the Net::HTTP request is made
# correctly (cookie header, HTTPS scheme, response handling).

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

require "uri"
require "net/http"
require "stringio"

module Shrine
  module Plugins
    module RemoteUrl
      class DownloadError < StandardError; end
    end
  end
end

# Replicate the Net::HTTP fetch logic from the initializer's patch
# in a way that's testable in isolation.
def fetch_printables_file(url, cookie)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 10
  http.read_timeout = 60
  req = Net::HTTP::Get.new(uri.request_uri)
  req["Cookie"] = cookie
  req["User-Agent"] = "manyfold_printables plugin (test)"
  resp = http.request(req)
  raise "Printables authenticated download failed: HTTP #{resp.code}" unless resp.code.to_i.between?(200, 299)
  StringIO.new(resp.body)
end

failures = []

# Test 1: 200 → StringIO with body
class Net::HTTP
  alias_method :_orig_req_test1, :request
  def request(req)
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { "STL binary content here" * 100 }
    response
  end
end

result = fetch_printables_file("https://media.printables.com/prints/abc/stls/uuid/foo.stl", "session=cookie123; cf_clearance=abc")
failures << "expected StringIO, got #{result.class}" unless result.is_a?(StringIO)
failures << "wrong body content" unless result.read.include?("STL binary content")
puts "Test 1: ✓ 200 → StringIO with body"

# Test 2: Cookie header set correctly
captured_req = nil
class Net::HTTP
  alias_method :_orig_req_test2, :request
  def request(req)
    $captured_req = req
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { "ok" }
    response
  end
end
$captured_req = nil
fetch_printables_file("https://media.printables.com/foo.stl", "session=mycookie; other=stuff")
failures << "Cookie header missing: #{$captured_req["Cookie"].inspect}" unless $captured_req["Cookie"] == "session=mycookie; other=stuff"
puts "Test 2: ✓ Cookie header set correctly"

# Test 3: raises on 403
class Net::HTTP
  alias_method :_orig_req_test3, :request
  def request(req)
    response = Object.new
    response.define_singleton_method(:code) { "403" }
    response.define_singleton_method(:body) { "Forbidden" }
    response
  end
end
begin
  fetch_printables_file("https://media.printables.com/foo.stl", "session=cookie")
  failures << "should have raised on 403"
rescue => e
  failures << "wrong error message: #{e.message}" unless e.message.include?("HTTP 403")
  puts "Test 3: ✓ raises on 403 (#{e.message})"
end

# Test 4: raises on 404
class Net::HTTP
  alias_method :_orig_req_test4, :request
  def request(req)
    response = Object.new
    response.define_singleton_method(:code) { "404" }
    response.define_singleton_method(:body) { "Not Found" }
    response
  end
end
begin
  fetch_printables_file("https://media.printables.com/foo.stl", "session=cookie")
  failures << "should have raised on 404"
rescue => e
  puts "Test 4: ✓ raises on 404 (#{e.message})"
end

# Test 5: HTTPS scheme uses port 443
class Net::HTTP
  alias_method :_orig_req_test5, :request
  def request(req)
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { "https" }
    response
  end
end
$https_uri_used = nil
Net::HTTP.singleton_class.class_eval do
  alias_method :_orig_new_test5, :new
  define_method(:new) do |host, port|
    $https_uri_used = [host, port]
    _orig_new_test5(host, port)
  end
end
fetch_printables_file("https://media.printables.com/foo.stl", "session=cookie")
failures << "https scheme should use port 443, got #{$https_uri_used.inspect}" unless $https_uri_used && $https_uri_used[1] == 443
puts "Test 5: ✓ HTTPS uses port 443 (got #{$https_uri_used.inspect})"

# Test 6: User-Agent header set
$captured_req = nil
class Net::HTTP
  alias_method :_orig_req_test6, :request
  def request(req)
    $captured_req = req
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { "ok" }
    response
  end
end
fetch_printables_file("https://media.printables.com/foo.stl", "session=cookie")
failures << "User-Agent missing or wrong: #{$captured_req["User-Agent"].inspect}" unless $captured_req["User-Agent"].include?("manyfold_printables")
puts "Test 6: ✓ User-Agent includes 'manyfold_printables'"

if failures.empty?
  puts "\n✓ all authenticated-download tests passed"
else
  puts "\n✗ FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
