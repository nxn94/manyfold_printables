class Integrations::Printables::ModelDeserializer < Integrations::Printables::BaseDeserializer
  attr_reader :model_id

  # GraphQL query — fields chosen to map onto Manyfold's Model attributes. The
  # Printables GraphQL endpoint has introspection disabled, so unknown field
  # names will return errors. Keep this in sync with the live schema.
  PRINT_QUERY = <<~GRAPHQL.freeze
    query ManyfoldPrintables($id: ID!) {
      print(id: $id) {
        id
        name
        slug
        summary
        description
        nsfw
        modified
        firstPublish
        datePublished
        downloadCount
        displayCount
        filesCount
        likesCount
        makesCount
        commentCount
        ratingAvg
        ratingCount
        thingiverseLink
        publicCollectionsCount
        numPieces
        weight
        printDuration
        license {
          id
          name
          disallowRemixing
        }
        image {
          id
          filePath
        }
        images {
          id
          filePath
        }
        stls {
          id
          name
          fileSize
          filePreviewPath
        }
        slas {
          id
          name
          fileSize
          filePreviewPath
        }
        gcodes {
          id
          name
          fileSize
          filePreviewPath
        }
        user {
          id
          handle
          publicUsername
          avatarFilePath
          verified
          badgesProfileLevel {
            profileLevel
          }
        }
        tags {
          id
          name
        }
      }
    }
  GRAPHQL

  def deserialize
    return {} unless valid?
    data = graphql(PRINT_QUERY, {id: @model_id}).dig("print")
    raise Faraday::ResourceNotFound.new("Not Found") unless data

    file_entries = build_file_entries(data)

    {
      name: data["name"],
      slug: data["slug"].to_s.empty? ? slugify(data["name"]) : data["slug"],
      notes: data["description"],
      summary: data["summary"],
      sensitive: data["nsfw"] == true,
      tag_list: Array(data["tags"]).map { |t| t["name"] }.compact,
      license: data.dig("license", "name"),
      file_urls: file_entries,
      preview_filename: preview_filename_from(data)
    }.merge(creator_attributes(data["user"]))
  end

  def capabilities
    {
      class: Model,
      name: true,
      notes: true,
      summary: true,
      images: true,
      model_files: true,
      creator: true,
      tags: true,
      sensitive: true,
      license: true
    }
  end

  private

  def valid_path?(path)
    match = MODEL_PATH_RE.match(path)
    @model_id = match[:model_id] if match
    !match.nil?
  end

  # Build the file_urls list Manyfold will download into the model directory.
  # We include STL/SLA/gcode files (the actual printable geometry) and the
  # cover image plus any additional images Manyfold might want for thumbnails.
  def build_file_entries(data)
    entries = []

    %w[stls slas gcodes].each do |kind|
      Array(data[kind]).each do |f|
        next unless !f["name"].to_s.empty? && !f["filePreviewPath"].to_s.empty?
        url = derived_file_url(f["filePreviewPath"], f["name"])
        entries << {url: url, filename: "files/#{f['name']}"} if url
      end
    end

    Array(data["images"]).each do |img|
      next unless !img["filePath"].to_s.empty?
      entries << {
        url: file_url(img["filePath"]),
        filename: "images/#{File.basename(img['filePath'])}"
      }
    end

    entries
  end

  # The GraphQL response gives us filePreviewPath (a path on media.printables.com)
  # but not the absolute download URL for the real file. The CDN layout is
  #   media/prints/<id>/<kind>/<uuid>/<basename>_preview.<preview-ext>
  # and the real file is at the same path with `_preview.<ext>` replaced by the
  # actual filename. We derive the URL here; the preview is HTTP-public.
  def derived_file_url(file_preview_path, real_filename)
    return nil if file_preview_path.to_s.empty? || real_filename.to_s.empty?
    dir = file_preview_path.sub(%r{/[^/]+\z}, "")
    extension = File.extname(real_filename)
    base = File.basename(real_filename, extension)
    file_url("#{dir}/#{base}#{extension}")
  end

  def preview_filename_from(data)
    return nil unless data["image"].is_a?(Hash)
    path = data["image"]["filePath"]
    return nil if path.to_s.empty?
    "images/#{File.basename(path)}"
  end

  # Lightweight slugify that doesn't depend on ActiveSupport::Inflector#parameterize.
  # Strips non-word chars and replaces whitespace with dashes.
  def slugify(text)
    return nil if text.nil?
    text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def creator_attributes(user_data)
    return {} unless user_data.is_a?(Hash)
    attempt_creator_match(Integrations::Printables::CreatorDeserializer.parse(user_data))
  end
end
