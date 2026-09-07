# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "pathname"

module GptVnModeAssets
  class Error < StandardError; end

  class Generator
    SCHEMA_VERSION = 1

    EMOTIONS = %w[
      default
      happy
      sad
      mischievous
      surprised
      embarrassed
      angry
    ].freeze

    TYPES = {
      "characters" => {
        extensions: {
          ".avif" => "image/avif",
          ".gif" => "image/gif",
          ".jpeg" => "image/jpeg",
          ".jpg" => "image/jpeg",
          ".png" => "image/png",
          ".webp" => "image/webp"
        }
      },
      "backgrounds" => {
        extensions: {
          ".avif" => "image/avif",
          ".gif" => "image/gif",
          ".jpeg" => "image/jpeg",
          ".jpg" => "image/jpeg",
          ".png" => "image/png",
          ".webp" => "image/webp"
        }
      },
      "music" => {
        extensions: {
          ".mp3" => "audio/mpeg",
          ".wav" => "audio/wav",
          ".webm" => "audio/webm"
        }
      },
      "sounds" => {
        extensions: {
          ".mp3" => "audio/mpeg",
          ".wav" => "audio/wav",
          ".webm" => "audio/webm"
        }
      }
    }.freeze
    BADGES = {
      "characters" => {
        label: "Characters",
        color: "#c05a93",
        label_width: 68
      },
      "backgrounds" => {
        label: "Backgrounds",
        color: "#4c78a8",
        label_width: 82
      },
      "music" => {
        label: "Music",
        color: "#7656c9",
        label_width: 42
      },
      "sounds" => {
        label: "SFX",
        color: "#d97732",
        label_width: 34
      }
    }.freeze
    BADGE_VALUE_WIDTH = 34
    PLACEHOLDER_PATHS = TYPES.keys.map { |kind| "assets/#{kind}/.gitkeep" }.freeze

    attr_reader :root

    def initialize(root:)
      @root = Pathname(root).expand_path
    end

    def write!
      generated = manifests

      generated.each do |kind, manifest|
        manifest_path(kind).write(serialize(manifest))
      end

      BADGES.each do |kind, config|
        path = badge_path(kind)
        path.dirname.mkpath
        path.write(badge_svg(config, asset_count(generated.fetch(kind))))
      end
    end

    def outdated_manifests
      generated = manifests
      outdated = generated.filter_map do |kind, manifest|
        path = manifest_path(kind)
        kind unless path.file? && path.read == serialize(manifest)
      end

      outdated + BADGES.filter_map do |kind, config|
        path = badge_path(kind)
        expected = badge_svg(config, asset_count(generated.fetch(kind)))
        "badges/#{kind}.svg" unless path.file? && path.read == expected
      end
    end

    def manifests
      generated = TYPES.to_h { |kind, config| [kind, build_manifest(kind, config)] }
      validate_source_coverage!(generated)
      generated
    end

    private

    def build_manifest(kind, config)
      source_root = root.join("assets", kind)
      source_root.mkpath

      content = if kind == "characters"
                  scan_character_category(source_root, [], config.fetch(:extensions))
                else
                  scan_file_category(
                    source_root,
                    [],
                    config.fetch(:extensions),
                    title_metadata: kind == "music"
                  )
                end

      {
        "schemaVersion" => SCHEMA_VERSION,
        "kind" => kind,
        "assets" => content.fetch("assets"),
        "categories" => content.fetch("categories")
      }
    end

    def scan_character_category(directory, category_parts, extensions)
      entries = visible_entries(directory)
      files = entries.select(&:file?)
      directories = entries.select(&:directory?)
      validate_entry_types!(entries)

      defaults = files.map do |file|
        validate_extension!(file, extensions)
        build_character(file, directory, category_parts, extensions)
      end
      validate_unique_ids!(defaults, directory)

      pack_names = files.map { |file| file.basename(file.extname).to_s }.to_h { |stem| [stem, true] }
      categories = directories.reject { |child| pack_names.key?(child.basename.to_s) }

      detect_orphan_expression_packs!(categories, extensions)

      {
        "assets" => sort_assets(defaults),
        "categories" => categories.map do |child|
          build_category_node(child, category_parts, extensions, character: true)
        end
      }
    end

    def scan_file_category(directory, category_parts, extensions, title_metadata:)
      entries = visible_entries(directory)
      validate_entry_types!(entries)

      assets = entries.select(&:file?).map do |file|
        validate_extension!(file, extensions)
        build_file_asset(file, category_parts, extensions, title_metadata: title_metadata)
      end
      validate_unique_ids!(assets, directory)

      {
        "assets" => sort_assets(assets),
        "categories" => entries.select(&:directory?).map do |child|
          build_category_node(
            child,
            category_parts,
            extensions,
            character: false,
            title_metadata: title_metadata
          )
        end
      }
    end

    def build_category_node(directory, parent_parts, extensions, character:, title_metadata: false)
      source_name = directory.basename.to_s
      validate_category_name!(source_name, directory)
      parts = parent_parts + [source_name]
      content = if character
                  scan_character_category(directory, parts, extensions)
                else
                  scan_file_category(directory, parts, extensions, title_metadata: title_metadata)
                end

      {
        "id" => parts.join("/"),
        "label" => display_name(source_name),
        "assets" => content.fetch("assets"),
        "categories" => content.fetch("categories")
      }
    end

    def build_character(default_file, directory, category_parts, extensions)
      stem = default_file.basename(default_file.extname).to_s
      source_name, color = parse_character_stem(stem, default_file)
      sprites = { "default" => file_descriptor(default_file, extensions) }
      pack = directory.join(stem)

      if pack.directory?
        visible_entries(pack).each do |entry|
          raise Error, "An expression pack cannot contain a directory: #{relative(entry)}" if entry.directory?

          validate_entry_types!([entry])
          validate_extension!(entry, extensions)
          emotion = entry.basename(entry.extname).to_s

          unless EMOTIONS.include?(emotion) && emotion != "default"
            raise Error, "Unknown expression in #{relative(entry)}: #{emotion.inspect}"
          end
          raise Error, "Duplicate expression in #{relative(pack)}: #{emotion}" if sprites.key?(emotion)

          sprites[emotion] = file_descriptor(entry, extensions)
        end
      end

      ordered_sprites = EMOTIONS.each_with_object({}) do |emotion, result|
        result[emotion] = sprites.fetch(emotion) if sprites.key?(emotion)
      end

      asset = {
        "id" => (category_parts + [source_name]).join("/"),
        "label" => display_name(source_name),
        "sprites" => ordered_sprites
      }
      asset["color"] = "##{color.downcase}" if color
      asset
    end

    def build_file_asset(file, category_parts, extensions, title_metadata:)
      stem = file.basename(file.extname).to_s
      source_name, title = if title_metadata
                             parse_music_stem(stem, file)
                           else
                             [stem, nil]
                           end

      if !title_metadata && stem.include?("__")
        raise Error, "The __ metadata separator is not supported for this asset type: #{relative(file)}"
      end

      asset = {
        "id" => (category_parts + [source_name]).join("/"),
        "label" => display_name(source_name),
        "file" => file_descriptor(file, extensions)
      }
      asset["title"] = display_name(title) if title
      asset
    end

    def parse_character_stem(stem, file)
      parts = stem.split("__", -1)
      if parts.length > 2 || parts.first.nil? || display_name(parts.first).empty?
        raise Error, "Invalid character name: #{relative(file)}"
      end

      color = parts[1]
      if color && !color.match?(/\A[0-9a-f]{6}\z/i)
        raise Error, "Invalid color in #{relative(file)}: #{color.inspect} (expected six hexadecimal digits)"
      end

      [parts.first, color]
    end

    def parse_music_stem(stem, file)
      parts = stem.split("__", -1)
      if parts.length > 2 || parts.any? { |part| display_name(part).empty? }
        raise Error, "Invalid music name: #{relative(file)}"
      end

      parts
    end

    def file_descriptor(file, extensions)
      digest = Base64.strict_encode64(Digest::SHA256.file(file).digest)

      {
        "path" => relative(file),
        "contentType" => extensions.fetch(file.extname.downcase),
        "byteSize" => file.size,
        "integrity" => "sha256-#{digest}"
      }
    end

    def visible_entries(directory)
      directory.children
        .reject { |entry| placeholder?(entry) }
        .sort_by { |entry| [entry.basename.to_s.downcase, entry.basename.to_s] }
    end

    def validate_source_coverage!(generated)
      referenced = generated.values.flat_map { |manifest| referenced_paths(manifest) }
      duplicates = referenced.group_by(&:itself).select { |_path, matches| matches.length > 1 }.keys
      unless duplicates.empty?
        raise Error, "Files referenced more than once: #{duplicates.join(', ')}"
      end

      source_files = Dir.glob(root.join("assets", "**", "*").to_s, File::FNM_DOTMATCH)
        .map { |path| Pathname(path) }
        .select(&:file?)
        .reject { |path| placeholder?(path) }
        .map { |path| relative(path) }
        .sort

      ignored = source_files - referenced
      missing = referenced - source_files

      raise Error, "Assets ignored by the manifests: #{ignored.join(', ')}" unless ignored.empty?
      raise Error, "References without a source file: #{missing.join(', ')}" unless missing.empty?
    end

    def referenced_paths(node)
      files = node.fetch("assets").flat_map do |asset|
        descriptors = asset["sprites"] ? asset.fetch("sprites").values : [asset.fetch("file")]
        descriptors.map { |descriptor| descriptor.fetch("path") }
      end

      files + node.fetch("categories").flat_map { |category| referenced_paths(category) }
    end

    def placeholder?(path)
      PLACEHOLDER_PATHS.include?(relative(path)) && path.file? && path.zero?
    end

    def validate_entry_types!(entries)
      entries.each do |entry|
        raise Error, "Symbolic links are not allowed: #{relative(entry)}" if entry.symlink?
        next if entry.file? || entry.directory?

        raise Error, "Unsupported file type: #{relative(entry)}"
      end
    end

    def validate_extension!(file, extensions)
      return if extensions.key?(file.extname.downcase)

      raise Error, "Unsupported file extension: #{relative(file)}"
    end

    def validate_category_name!(name, directory)
      return unless name.include?("__")

      raise Error, "The __ separator is not allowed in a category name: #{relative(directory)}"
    end

    def validate_unique_ids!(assets, directory)
      duplicates = assets.group_by { |asset| asset.fetch("id") }.select { |_id, matches| matches.length > 1 }
      return if duplicates.empty?

      raise Error, "Duplicate asset ID in #{relative(directory)}: #{duplicates.keys.join(', ')}"
    end

    def detect_orphan_expression_packs!(directories, extensions)
      directories.each do |directory|
        files = visible_entries(directory).select(&:file?)
        next if files.empty?
        next unless files.all? do |file|
          extensions.key?(file.extname.downcase) && EMOTIONS.include?(file.basename(file.extname).to_s)
        end

        raise Error, "Expression pack without a matching default sprite: #{relative(directory)}"
      end
    end

    def sort_assets(assets)
      assets.sort_by { |asset| [asset.fetch("label").downcase, asset.fetch("id")] }
    end

    def display_name(source_name)
      source_name.tr("_", " ").strip
    end

    def relative(path)
      path.relative_path_from(root).each_filename.to_a.join("/")
    end

    def manifest_path(kind)
      root.join("#{kind}.json")
    end

    def badge_path(kind)
      root.join("badges", "#{kind}.svg")
    end

    def asset_count(node)
      node.fetch("assets").length + node.fetch("categories").sum { |category| asset_count(category) }
    end

    def badge_svg(config, count)
      label = config.fetch(:label)
      label_width = config.fetch(:label_width)
      total_width = label_width + BADGE_VALUE_WIDTH
      label_center = label_width / 2.0
      value_center = label_width + (BADGE_VALUE_WIDTH / 2.0)
      description = "#{label}: #{count}"

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="#{total_width}" height="20" role="img" aria-label="#{description}">
          <title>#{description}</title>
          <linearGradient id="s" x2="0" y2="100%">
            <stop offset="0" stop-color="#fff" stop-opacity=".18"/>
            <stop offset="1" stop-opacity=".18"/>
          </linearGradient>
          <clipPath id="r">
            <rect width="#{total_width}" height="20" rx="3" fill="#fff"/>
          </clipPath>
          <g clip-path="url(#r)">
            <rect width="#{label_width}" height="20" fill="#555"/>
            <rect x="#{label_width}" width="#{BADGE_VALUE_WIDTH}" height="20" fill="#{config.fetch(:color)}"/>
            <rect width="#{total_width}" height="20" fill="url(#s)"/>
          </g>
          <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
            <text x="#{label_center}" y="15" fill="#010101" fill-opacity=".3">#{label}</text>
            <text x="#{label_center}" y="14">#{label}</text>
            <text x="#{value_center}" y="15" fill="#010101" fill-opacity=".3">#{count}</text>
            <text x="#{value_center}" y="14">#{count}</text>
          </g>
        </svg>
      SVG
    end

    def serialize(manifest)
      "#{JSON.pretty_generate(manifest)}\n"
    end
  end
end
