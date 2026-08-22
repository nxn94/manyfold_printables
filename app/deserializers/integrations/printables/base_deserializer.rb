module Integrations::Printables
  class BaseDeserializer < Integrations::BaseDeserializer
    GRAPHQL_ENDPOINT = "https://api.printables.com/graphql/".freeze
    CDN_HOST = "media.printables.com".freeze

    # Map Printables' numeric license IDs to SPDX identifiers. Printables'
    # GraphQL `license.id` is a numeric database ID (1, 2, 4, 7, ...), and the
    # `license.name` is a human-readable title like "Creative Commons —
    # Attribution". Manyfold validates `Model.license` against the SPDX list,
    # so we translate IDs to SPDX identifiers. Unknown IDs map to nil so the
    # model's `normalize_license` callback clears the column rather than
    # raising a validation error and rolling back the sync.
    PRINTABLES_LICENSE_TO_SPDX = {
      "1" => "CC-BY-4.0",         # Creative Commons — Attribution
      "2" => "CC-BY-SA-4.0",      # Creative Commons — Attribution — Share Alike
      "3" => "CC-BY-NC-4.0",      # Creative Commons — Attribution — Noncommercial
      "4" => "CC-BY-NC-SA-4.0",   # Creative Commons — Attribution — Noncommercial — Share Alike
      "5" => nil,                 # (reserved; not seen)
      "6" => "CC-BY-NC-ND-4.0",   # Creative Commons — Attribution — Noncommercial — NoDerivatives
      "7" => "CC0-1.0",           # Creative Commons — Public Domain
      "8" => nil,                 # (reserved)
      "9" => nil                  # (Printables-internal / non-SPDX, treat as unknown)
    }.freeze

    # Path patterns for the two kinds of URLs we accept:
    #   https://www.printables.com/model/46705
    #   https://www.printables.com/model/46705-battery-tray-16x-aa-16x-aaa-4x-cr2032
    #   https://www.printables.com/@handle
    MODEL_PATH_RE = %r{\A/model/(?<model_id>\d+)(?:-[^/]+)?\z}.freeze
    CREATOR_PATH_RE = %r{\A/@(?<handle>[A-Za-z0-9_-]+)\z}.freeze

    private

    # Printables' GraphQL is fully public — no key needed.
    def api_configured?
      true
    end

    def canonicalize(uri)
      u = URI.parse(uri)
      # Accept both bare apex and www. prefix; both should resolve.
      return unless u.host == "www.printables.com" || u.host == "printables.com"
      return unless valid_path?(u.path)
      u.host = "www.printables.com"
      u.scheme = "https"
      u.query = u.fragment = nil
      u.to_s
    rescue URI::InvalidURIError
      nil
    end

    # POST a GraphQL operation to the Printables endpoint and return the parsed body.
    # Raises Faraday::ResourceNotFound for "not found" so the calling Job can record
    # a problem on the Link, just like the other integrations do.
    def graphql(query, variables = {})
      uri = URI.parse(GRAPHQL_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "User-Agent" => "Manyfold/#{ManyfoldPrintables::VERSION} (+manyfold_printables plugin)"
      })
      req.body = JSON.generate(
        operationName: "ManyfoldPrintables",
        query: query,
        variables: variables
      )

      response = http.request(req)
      raise Faraday::ResourceNotFound.new("Not Found") if response.code.to_i == 404

      body = JSON.parse(response.body)
      if body["errors"]&.any?
        message = body["errors"].map { |e| e["message"] }.join("; ")
        raise Faraday::Error.new(message)
      end

      body["data"] || {}
    end

    # Convert a CDN-relative filePath (e.g. "media/prints/46705/...")
    # into an absolute download URL on the printables.com CDN.
    def file_url(file_path)
      return nil if file_path.nil? || file_path.to_s.empty?
      "https://#{CDN_HOST}/#{file_path.to_s.sub(%r{\A/}, "")}"
    end

    def filename_from_url(url)
      return nil if url.nil? || url.to_s.empty?
      CGI.unescape(URI.parse(url).path).split("/").last
    end

    def blank?(s)
      s.nil? || s.to_s.empty?
    end

    # Printables license ID -> SPDX identifier. Unknown IDs return nil so the
    # Model's normalize_license callback clears the column rather than raising.
    def spdx_license_for(printables_license_id)
      return nil if printables_license_id.nil?
      PRINTABLES_LICENSE_TO_SPDX[printables_license_id.to_s]
    end
  end
end
