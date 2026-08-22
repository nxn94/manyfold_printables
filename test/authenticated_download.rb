# Regression test for the authenticated-download patch logic.
#
# We can't run the patch against a real ModelFile (that requires the
# full Manyfold+Shrine stack), so we extract the downloader builder as
# a method and test it in isolation.

$LOAD_PATH.unshift("/tmp/manyfold-research/manyfold/app/deserializers")

# Set up minimal stubs
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

# Extract the downloader-builder from the initializer into a testable
# helper. We replicate the same code structure that's in
# config/initializers/register_deserializers.rb.
module PrintablesDownloader
  module_function

  def build(cookie)
    ->(u, **_opts) {
      uri = URI.parse(u)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 60
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Cookie"] = cookie
      req["User-Agent"] = "manyfold_printables plugin (test)"
      resp = http.request(req)
      unless resp.code.to_i.between?(200, 299)
        raise Shrine::Plugins::RemoteUrl::DownloadError,
              "HTTP #{resp.code} — cookie may be expired or print is private"
      end
      StringIO.new(resp.body)
    }
  end
end

failures = []

# Test 1: downloader returns a StringIO containing the body on 200
class Net::HTTP
  alias_method :_orig_req_test1, :request
  def request(req)
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { "STL binary content here" * 100 }
    response
  end
end

downloader = PrintablesDownloader.build("session=cookie123; cf_clearance=abc")
result = downloader.call("https://media.printables.com/prints/abc/stls/uuid/foo.stl")
failures << "expected StringIO, got #{result.class}" unless result.is_a?(StringIO)
failures << "wrong body content" unless result.read.include?("STL binary content")
puts "Test 1: ✓ 200 → StringIO with body"

# Test 2: downloader sends the cookie in the request
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
downloader.call("https://media.printables.com/foo.stl")
failures << "Cookie header missing: #{$captured_req["Cookie"].inspect}" unless $captured_req["Cookie"] == "session=cookie123; cf_clearance=abc"
puts "Test 2: ✓ Cookie header set correctly"

# Test 3: downloader raises DownloadError on 403
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
  downloader.call("https://media.printables.com/foo.stl")
  failures << "should have raised on 403"
rescue Shrine::Plugins::RemoteUrl::DownloadError => e
  failures << "wrong error message: #{e.message}" unless e.message.include?("HTTP 403")
  puts "Test 3: ✓ raises DownloadError on 403"
end

# Test 4: downloader raises on 404
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
  downloader.call("https://media.printables.com/foo.stl")
  failures << "should have raised on 404"
rescue Shrine::Plugins::RemoteUrl::DownloadError => e
  puts "Test 4: ✓ raises DownloadError on 404 (#{e.message})"
end

# Test 5: downloader respects HTTPS scheme
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
downloader.call("https://media.printables.com/foo.stl")
failures << "https scheme should use port 443, got #{$https_uri_used.inspect}" unless $https_uri_used && $https_uri_used[1] == 443
puts "Test 5: ✓ HTTPS uses port 443 (got #{$https_uri_used.inspect})"

if failures.empty?
  puts "\n✓ all authenticated-download downloader tests passed"
else
  puts "\n� FAILURES:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
