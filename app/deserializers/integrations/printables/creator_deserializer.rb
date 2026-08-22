class Integrations::Printables::CreatorDeserializer < Integrations::Printables::BaseDeserializer
  attr_reader :handle

  USER_QUERY = <<~GRAPHQL.freeze
    query ManyfoldPrintables($id: ID!) {
      user(id: $id) {
        id
        handle
        publicUsername
        avatarFilePath
        verified
        badgesProfileLevel {
          profileLevel
        }
      }
    }
  GRAPHQL

  # Printables identifies users by numeric ID, not by handle — but their public URLs
  # use handles (e.g. https://www.printables.com/@100prznt). We resolve handle -> id
  # by walking the public profile page, then issue the GraphQL query.
  def deserialize
    return {} unless valid?
    user_id = resolve_user_id(@handle)
    raise Faraday::ResourceNotFound.new("Not Found") unless user_id
    data = graphql(USER_QUERY, {id: user_id}).dig("user")
    raise Faraday::ResourceNotFound.new("Not Found") unless data
    self.class.parse(data)
  end

  def self.parse(data)
    {
      name: (data["publicUsername"].to_s.empty? ? data["handle"] : data["publicUsername"]),
      slug: data["handle"],
      links_attributes: [{url: "https://www.printables.com/@#{data['handle']}"}],
      avatar_remote_url: avatar_url(data["avatarFilePath"])
    }
  end

  def capabilities
    {
      class: Creator,
      name: true,
      slug: true,
      notes: false
    }
  end

  private

  def valid_path?(path)
    match = CREATOR_PATH_RE.match(path)
    @handle = match[:handle] if match
    !match.nil?
  end

  # Walk the public Printables profile page to extract the numeric user ID. The
  # page HTML embeds the ID in a window.__NEXT_DATA__ payload (Next.js), so we
  # grep for a JSON blob containing the handle and pull the user id from there.
  # Returns nil if the page can't be parsed (404, Cloudflare block, etc.).
  def resolve_user_id(handle)
    uri = URI.parse("https://www.printables.com/@#{handle}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30
    req = Net::HTTP::Get.new(uri.request_uri, {
      "User-Agent" => "Mozilla/5.0 (compatible; Manyfold/#{ManyfoldPrintables::VERSION})",
      "Accept" => "text/html"
    })
    response = http.request(req)
    return nil unless response.code.to_i == 200

    body = response.body.to_s
    # Next.js data payload includes "id":"<digits>" adjacent to the handle.
    # Example: "publicUsername":"100prznt"... "id":"23641"
    if (m = body.match(/"publicUsername"\s*:\s*"#{Regexp.escape(handle)}"/)) &&
       (id_match = body[m.end(0)..(m.end(0) + 4000)]&.match(/"id"\s*:\s*"(?<uid>\d+)"/))
      return id_match[:uid]
    end

    # Fallback: any "user":{"id":N,"handle":"X"} block.
    if (m = body.match(/"user"\s*:\s*\{[^{}]*"id"\s*:\s*"(?<uid>\d+)"[^{}]*"handle"\s*:\s*"#{Regexp.escape(handle)}"/))
      return m[:uid]
    end

    nil
  rescue StandardError
    nil
  end

  def self.avatar_url(file_path)
    return nil if file_path.to_s.empty?
    "https://#{CDN_HOST}/#{file_path.sub(%r{\A/}, '')}"
  end
end
