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

    # Manyfold's Model has `notes` (long, markdown/HTML) and `caption` (short
    # blurb; was called `excerpt` before migration 20230222155910 but renamed
    # in v0.146.0+). Printables gives us both `summary` (one-line tagline) and
    # `description` (full HTML) — we map summary → caption and description →
    # notes, matching how the Cults3d integration treats its `description`
    # field as `notes`.
    #
    # Manyfold validates license against the SPDX list, so we map Printables'
    # numeric license IDs to SPDX identifiers. Unknown IDs map to nil so the
    # model's normalize_license callback will clear the column rather than
    # raise a validation error.
    {
      name: data["name"],
      slug: data["slug"].to_s.empty? ? slugify(data["name"]) : data["slug"],
      notes: data["description"],
      caption: data["summary"],
      sensitive: data["nsfw"] == true,
      tag_list: Array(data["tags"]).map { |t| t["name"] }.compact,
      license: spdx_license_for(data.dig("license", "id")),
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
  # but not the absolute download URL for the real file. The CDN layout for a
  # true `.stl` / `.sla` / `.gcode` is:
  #   media/prints/<id>/<kind>/<uuid>/<basename>_preview.<preview-ext>
  # and the real file is at the same path with `_preview.<ext>` replaced by the
  # actual filename.
  #
  # However, Printables' `stls` array can contain entries whose preview path is
  # under `/previews/` (general file previews, used for STEP, 3MF, OBJ, etc. —
  # formats Printables doesn't serve under `/stls/`). For those we can't derive
  # a working download URL, so we return nil and the entry is skipped.
  def derived_file_url(file_preview_path, real_filename)
    return nil if file_preview_path.to_s.empty? || real_filename.to_s.empty?
    return nil unless KNOWN_PREVIEW_DIRS.any? { |dir| file_preview_path.include?(dir) }
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
