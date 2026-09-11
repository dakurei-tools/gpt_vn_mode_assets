# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "set"
require "tempfile"

module GptVnModeAssets
  class Error < StandardError; end

  class MissingPreviewError < Error
    attr_reader :path

    def initialize(path)
      @path = path
      super("Missing generated preview: #{path} (run bin/generate_manifests)")
    end
  end

  class PreviewGenerator
    def generate(kind:, source:, destination:, recipe:)
      destination.dirname.mkpath
      Tempfile.create(["cgvn-preview-", recipe.fetch(:extension)], destination.dirname.to_s) do |temporary|
        temporary.close
        command = if recipe.fetch(:media) == :image
                    image_command(source, temporary.path, recipe)
                  else
                    audio_command(source, temporary.path, recipe)
                  end
        _stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          detail = stderr.to_s.strip.lines.last(6).join.strip
          raise Error, "Could not generate #{kind} preview for #{source}: #{detail}"
        end
        unless File.file?(temporary.path) && File.size(temporary.path).positive?
          raise Error, "Preview generation produced an empty file for #{source}"
        end

        FileUtils.mv(temporary.path, destination)
        FileUtils.chmod(0o644, destination)
      end
    end

    private

    def image_command(source, destination, recipe)
      executable = find_executable(%w[magick convert])
      raise Error, "ImageMagick is required to generate image previews" unless executable

      [
        executable,
        "#{source}[0]",
        "-auto-orient",
        "-thumbnail", recipe.fetch(:geometry),
        "-strip",
        "-quality", recipe.fetch(:quality).to_s,
        "-define", "webp:method=6",
        destination
      ]
    end

    def audio_command(source, destination, recipe)
      executable = find_executable(["ffmpeg"])
      raise Error, "FFmpeg is required to generate audio previews" unless executable

      [
        executable,
        "-nostdin",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", source.to_s,
        "-map", "0:a:0",
        "-t", recipe.fetch(:duration).to_s,
        "-vn",
        "-map_metadata", "-1",
        "-codec:a", "libmp3lame",
        "-ar", "44100",
        "-b:a", recipe.fetch(:bitrate),
        destination
      ]
    end

    def find_executable(names)
      names.each do |name|
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.join(directory, name)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end
  end

  class Generator
    SCHEMA_VERSION = 1
    PREVIEW_RECIPE_VERSION = 1
    PREVIEW_RECIPES = {
      "characters" => {
        media: :image,
        extension: ".webp",
        content_type: "image/webp",
        geometry: "512x512>",
        quality: 75
      },
      "backgrounds" => {
        media: :image,
        extension: ".webp",
        content_type: "image/webp",
        geometry: "640x360>",
        quality: 75
      },
      "music" => {
        media: :audio,
        extension: ".mp3",
        content_type: "audio/mpeg",
        duration: 15,
        bitrate: "96k"
      }
    }.freeze

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

    def initialize(root:, previews: true, previewer: PreviewGenerator.new)
      @root = Pathname(root).expand_path
      @previews = previews
      @previewer = previewer
      @generate_previews = false
      @expected_preview_paths = Set.new
    end

    def write!
      generated = manifests(generate_previews: true)
      clean_stale_previews!

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

      outdated += BADGES.filter_map do |kind, config|
        path = badge_path(kind)
        expected = badge_svg(config, asset_count(generated.fetch(kind)))
        "badges/#{kind}.svg" unless path.file? && path.read == expected
      end
      outdated + stale_preview_paths
    rescue MissingPreviewError => error
      [error.path]
    end

    def manifests(generate_previews: false)
      @generate_previews = generate_previews
      @expected_preview_paths = Set.new
      generated = TYPES.to_h { |kind, config| [kind, build_manifest(kind, config)] }
      validate_source_coverage!(generated)
      generated
    ensure
      @generate_previews = false
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
                    kind: kind,
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

      pack_names = files.to_h do |file|
        stem = file.basename(file.extname).to_s
        source_name, = parse_character_stem(stem, file)
        [source_name, true]
      end
      categories = directories.reject { |child| pack_names.key?(child.basename.to_s) }

      detect_orphan_expression_packs!(categories, extensions)

      {
        "assets" => sort_assets(defaults),
        "categories" => categories.map do |child|
          build_category_node(
            child,
            category_parts,
            extensions,
            kind: "characters",
            character: true
          )
        end
      }
    end

    def scan_file_category(directory, category_parts, extensions, kind:, title_metadata:)
      entries = visible_entries(directory)
      validate_entry_types!(entries)

      assets = entries.select(&:file?).map do |file|
        validate_extension!(file, extensions)
        build_file_asset(
          file,
          category_parts,
          extensions,
          kind: kind,
          title_metadata: title_metadata
        )
      end
      validate_unique_ids!(assets, directory)

      {
        "assets" => sort_assets(assets),
        "categories" => entries.select(&:directory?).map do |child|
          build_category_node(
            child,
            category_parts,
            extensions,
            kind: kind,
            character: false,
            title_metadata: title_metadata
          )
        end
      }
    end

    def build_category_node(directory, parent_parts, extensions, kind:, character:, title_metadata: false)
      source_name = directory.basename.to_s
      validate_category_name!(source_name, directory)
      parts = parent_parts + [source_name]
      content = if character
                  scan_character_category(directory, parts, extensions)
                else
                  scan_file_category(
                    directory,
                    parts,
                    extensions,
                    kind: kind,
                    title_metadata: title_metadata
                  )
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
      appearances = {}
      pack = directory.join(source_name)

      if pack.directory?
        visible_entries(pack).each do |entry|
          raise Error, "A character pack cannot contain a directory: #{relative(entry)}" if entry.directory?

          validate_entry_types!([entry])
          validate_extension!(entry, extensions)
          appearance_name, emotion = parse_character_sprite_stem(
            entry.basename(entry.extname).to_s,
            entry
          )
          target = appearance_name ? (appearances[appearance_name] ||= {}) : sprites
          if target.key?(emotion)
            scope = appearance_name ? "appearance #{appearance_name.inspect}" : "default appearance"
            raise Error, "Duplicate expression for #{scope} in #{relative(pack)}: #{emotion}"
          end

          target[emotion] = file_descriptor(entry, extensions)
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
      unless appearances.empty?
        asset["appearances"] = appearances.map do |appearance_name, appearance_sprites|
          unless appearance_sprites.key?("default")
            raise Error,
                  "Appearance #{appearance_name.inspect} has no default sprite in #{relative(pack)}"
          end

          appearance = {
            "id" => appearance_id(appearance_name),
            "label" => display_name(appearance_name),
            "sprites" => ordered_character_sprites(appearance_sprites)
          }
          if @previews
            default_source = root.join(appearance.fetch("sprites").fetch("default").fetch("path"))
            appearance["preview"] = preview_descriptor(default_source, "characters")
          end
          appearance
        end.sort_by { |appearance| [appearance.fetch("label").downcase, appearance.fetch("id")] }

        duplicate_ids = asset.fetch("appearances")
          .group_by { |appearance| appearance.fetch("id") }
          .select { |_id, matches| matches.length > 1 }
          .keys
        unless duplicate_ids.empty?
          raise Error, "Duplicate appearance ID in #{relative(pack)}: #{duplicate_ids.join(', ')}"
        end
      end
      asset["color"] = "##{color.downcase}" if color
      asset["preview"] = preview_descriptor(default_file, "characters") if @previews
      asset
    end

    def parse_character_sprite_stem(stem, file)
      if stem.start_with?("[")
        match = stem.match(/\A\[([^\[\]]+)\](.*)\z/)
        unless match && !display_name(match[1]).empty?
          raise Error, "Invalid appearance name in #{relative(file)}: #{stem.inspect}"
        end

        if match[2] == "default"
          raise Error,
                "Invalid default appearance sprite in #{relative(file)}: omit 'default' after the bracket"
        end

        emotion = match[2].empty? ? "default" : match[2]
        unless EMOTIONS.include?(emotion)
          raise Error, "Unknown expression in #{relative(file)}: #{emotion.inspect}"
        end

        return [match[1], emotion]
      end

      unless EMOTIONS.include?(stem) && stem != "default"
        raise Error, "Unknown expression in #{relative(file)}: #{stem.inspect}"
      end

      [nil, stem]
    end

    def ordered_character_sprites(sprites)
      EMOTIONS.each_with_object({}) do |emotion, result|
        result[emotion] = sprites.fetch(emotion) if sprites.key?(emotion)
      end
    end

    def appearance_id(source_name)
      source_name.unicode_normalize(:nfd)
        .gsub(/\p{Mn}/, "")
        .downcase
        .gsub(/[^a-z0-9]+/, "-")
        .gsub(/\A-+|-+\z/, "")[0, 48]
        .then { |id| id.empty? ? "appearance" : id }
    end

    def build_file_asset(file, category_parts, extensions, kind:, title_metadata:)
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
      asset["preview"] = preview_descriptor(file, kind) if @previews && PREVIEW_RECIPES.key?(kind)
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

    def preview_descriptor(source, kind)
      recipe = PREVIEW_RECIPES.fetch(kind)
      source_digest = Digest::SHA256.file(source).hexdigest
      source_root = root.join("assets", kind)
      source_path = source.relative_path_from(source_root).sub_ext("").to_s
      preview_path = [
        "previews/#{kind}/#{source_path}",
        source_digest[0, 16],
        "v#{PREVIEW_RECIPE_VERSION}"
      ].join("--") + recipe.fetch(:extension)
      @expected_preview_paths.add(preview_path)

      destination = root.join(preview_path)
      if !destination.file? && @generate_previews
        @previewer.generate(
          kind: kind,
          source: source,
          destination: destination,
          recipe: recipe
        )
      end
      raise MissingPreviewError, preview_path unless destination.file?

      generated_file_descriptor(destination, recipe.fetch(:content_type))
    end

    def generated_file_descriptor(file, content_type)
      digest = Base64.strict_encode64(Digest::SHA256.file(file).digest)

      {
        "path" => relative(file),
        "contentType" => content_type,
        "byteSize" => file.size,
        "integrity" => "sha256-#{digest}"
      }
    end

    def stale_preview_paths
      return [] unless @previews

      existing_preview_paths - @expected_preview_paths.to_a
    end

    def clean_stale_previews!
      return unless @previews

      stale_preview_paths.each { |path| FileUtils.rm_f(root.join(path)) }
      preview_root = root.join("previews")
      return unless preview_root.directory?

      preview_root.glob("**/*").select(&:directory?).sort_by { |path| -path.to_s.length }.each do |directory|
        directory.rmdir if directory.children.empty?
      end
    end

    def existing_preview_paths
      preview_root = root.join("previews")
      return [] unless preview_root.directory?

      preview_root.glob("**/*", File::FNM_DOTMATCH)
        .select(&:file?)
        .map { |path| relative(path) }
        .sort
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
        descriptors = if asset["sprites"]
                        asset.fetch("sprites").values +
                          asset.fetch("appearances", []).flat_map { |appearance| appearance.fetch("sprites").values }
                      else
                        [asset.fetch("file")]
                      end
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
          next false unless extensions.key?(file.extname.downcase)

          stem = file.basename(file.extname).to_s
          stem.match?(/\A\[[^\[\]]+\](?:#{EMOTIONS.drop(1).join('|')})?\z/) ||
            (EMOTIONS.include?(stem) && stem != "default")
        end

        raise Error, "Character pack without a matching default sprite: #{relative(directory)}"
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
