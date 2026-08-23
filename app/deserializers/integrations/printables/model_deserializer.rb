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
        otherFiles {
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
  # We include STL/SLA/gcode/otherFiles (the actual printable geometry) and the
  # cover image plus any additional images Manyfold might want for thumbnails.
  #
  # File URLs come from the public GraphQL `getDownloadLink` mutation, which
  # returns a 24-hour signed CDN URL for any file (STL, 3MF, STEP, OBJ, etc.)
  # on the `files.printables.com` host. This is the same endpoint the
  # printables.com website uses for its "Download all" button — and crucially,
  # it works without a session cookie for most files (Printables' rate-limit
  # is generous: thousands of downloads per day from a single IP).
  def build_file_entries(data)
    entries = []

    # Map each kind array to the fileType enum value that getDownloadLink
    # expects. Files in the `stls` array (which can include .stl, .3mf, .stp,
    # .obj etc — Printables stores them all under stls regardless of extension)
    # use `fileType: stl`. Same for slas/gcodes. `otherFiles` uses `other`.
    kind_to_filetype = {
      "stls" => "stl",
      "slas" => "sla",
      "gcodes" => "gcode",
      "otherFiles" => "other"
    }

    kind_to_filetype.each do |kind, file_type|
      Array(data[kind]).each do |f|
        next unless !f["name"].to_s.empty? && f["id"]
        next unless %w[stl sla gcode other].include?(file_type)

        url = get_download_url(file_id: f["id"], file_type: file_type)
        if url
          entries << {url: url, filename: "files/#{f['name']}"}
        else
          Rails.logger.info(
            "[manyfold_printables] skipping #{f['name']}: " \
            "getDownloadLink returned no URL for file id=#{f['id']} type=#{file_type}"
          )
        end
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

  # Call Printables' public GraphQL `getDownloadLink` mutation. Returns a
  # 24-hour signed CDN URL on files.printables.com, or nil on failure.
  #
  # This is the same mutation the printables.com website invokes when the
  # user clicks "Download" on a file — it does NOT require authentication for
  # most files, and works for all file extensions (.stl, .3mf, .stp, .obj,
  # etc.) regardless of which `stls`/`slas`/`gcodes`/`otherFiles` array
  # Printables stores them in.
  def get_download_url(file_id:, file_type:)
    query = <<~GQL
      mutation GetDownloadLink($id: ID!, $modelId: ID!, $fileType: DownloadFileTypeEnum!, $source: DownloadSourceEnum!) {
        getDownloadLink(id: $id, printId: $modelId, fileType: $fileType, source: $source) {
          ok
          errors { field messages }
          output { link ttl }
        }
      }
    GQL
    variables = {
      id: file_id,
      modelId: @model_id,
      fileType: file_type,
      source: "model_detail"
    }
    data = graphql(query, variables).dig("data", "getDownloadLink") || {}
    return nil unless data["ok"]
    data.dig("output", "link")
  rescue StandardError => e
    Rails.logger.warn("[manyfold_printables] get_download_url(#{file_id}) failed: #{e.class}: #{e.message}")
    nil
  end

  # (obsolete — was used to derive a CDN URL from the preview path; we now
  # get a proper signed URL directly from the getDownloadLink mutation.)

  def preview_filename_from(data)
    return nil unless data["image"].is_a?(Hash)
    path = data["image"]["filePath"]
    return nil if path.to_s.empty?
    "images/#{File.basename(path)}"
  end

  # Lightweight slugify that doesn't depend on ActiveSupport::Inflector#parameterize.
  # Strips non-word chars and replaces whitespace with dashes, then collapses
  # repeated dashes and trims leading/trailing dashes.
  #
  # Uses purely non-backtracking String operations to avoid the
  # polynomial-regex DoS flagged by GitHub code scanning. Earlier versions
  # used chained gsub calls (one to replace non-alphanumerics, one to trim
  # leading/trailing dashes), but `\\A-+|-+\\z` was still flagged because
  # the code scanner doesn't account for the bounded-input argument.
  #
  # Steps (all O(n) and regex-free):
  #   1. tr replaces each non-alphanumeric with a single "-".
  #   2. squeeze collapses runs of "-" into one.
  #   3. delete_prefix removes a leading "-", delete_suffix removes a trailing "-".
  def slugify(text)
    return nil if text.nil?
    s = text.to_s.downcase.tr("^a-z0-9", "-").squeeze("-")
    s = s.delete_prefix("-") while s.start_with?("-")
    s = s.delete_suffix("-") while s.end_with?("-")
    s.empty? ? nil : s
  end

  def creator_attributes(user_data)
    return {} unless user_data.is_a?(Hash)
    attempt_creator_match(Integrations::Printables::CreatorDeserializer.parse(user_data))
  end
end
