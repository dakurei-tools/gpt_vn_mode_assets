# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/gpt_vn_mode_assets/generator"

class FakePreviewer
  attr_reader :calls

  def initialize
    @calls = []
  end

  def generate(kind:, source:, destination:, recipe:)
    @calls << { kind: kind, source: source, destination: destination, recipe: recipe }
    destination.dirname.mkpath
    destination.binwrite("preview:#{kind}:#{source.basename}:#{source.binread}")
  end
end

class GeneratorTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir)
    %w[characters backgrounds music sounds].each do |kind|
      @root.join("assets", kind).mkpath
    end
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_builds_a_character_pack_with_an_optional_color
    category = @root.join("assets/characters/Anime/Evangelion")
    category.mkpath
    default = category.join("Asuka_Langley__e65a32.webp")
    default.binwrite("default sprite")
    pack = category.join("Asuka_Langley")
    pack.mkpath
    happy = pack.join("happy.png")
    happy.binwrite("happy sprite")

    manifest = generator.manifests.fetch("characters")
    anime = manifest.fetch("categories").first
    evangelion = anime.fetch("categories").first
    character = evangelion.fetch("assets").first

    assert_equal "Anime/Evangelion/Asuka_Langley", character.fetch("id")
    assert_equal "Asuka Langley", character.fetch("label")
    refute character.key?("name")
    assert_equal "#e65a32", character.fetch("color")
    assert_equal %w[default happy], character.fetch("sprites").keys
    assert_equal "image/webp", character.dig("sprites", "default", "contentType")
    assert_equal integrity_for(default), character.dig("sprites", "default", "integrity")
    assert_equal integrity_for(happy), character.dig("sprites", "happy", "integrity")
  end

  def test_builds_appearances_from_bracketed_sprite_names
    category = @root.join("assets/characters/Anime/Naruto")
    category.mkpath
    default = category.join("Dakurei_Makushimu_(Shippuden)__4995d4.png")
    default.binwrite("default sprite")
    pack = category.join("Dakurei_Makushimu_(Shippuden)")
    pack.mkpath
    pack.join("angry.png").binwrite("default angry sprite")
    outfit_default = pack.join("[Tenue_spéciale].png")
    outfit_default.binwrite("outfit default sprite")
    outfit_angry = pack.join("[Tenue_spéciale]angry.webp")
    outfit_angry.binwrite("outfit angry sprite")

    character = generator.manifests
      .dig("characters", "categories", 0, "categories", 0, "assets", 0)

    assert_equal %w[default angry], character.fetch("sprites").keys
    assert_equal 1, character.fetch("appearances").length
    appearance = character.fetch("appearances").first
    assert_equal "tenue-speciale", appearance.fetch("id")
    assert_equal "Tenue spéciale", appearance.fetch("label")
    assert_equal %w[default angry], appearance.fetch("sprites").keys
    assert_equal integrity_for(outfit_default), appearance.dig("sprites", "default", "integrity")
    assert_equal integrity_for(outfit_angry), appearance.dig("sprites", "angry", "integrity")
  end

  def test_rejects_an_appearance_without_a_default_sprite
    category = @root.join("assets/characters/Anime")
    category.mkpath
    category.join("Hero__123456.png").binwrite("default")
    pack = category.join("Hero")
    pack.mkpath
    pack.join("[Armure]angry.png").binwrite("angry")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Appearance \"Armure\" has no default sprite", error.message
  end

  def test_rejects_an_explicit_default_suffix_for_an_appearance
    category = @root.join("assets/characters/Anime")
    category.mkpath
    category.join("Hero.png").binwrite("default")
    pack = category.join("Hero")
    pack.mkpath
    pack.join("[Armure]default.png").binwrite("armour default")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "omit 'default' after the bracket", error.message
  end

  def test_rejects_a_legacy_color_suffix_on_a_character_pack_directory
    category = @root.join("assets/characters/Anime")
    category.mkpath
    category.join("Hero__123456.png").binwrite("default")
    legacy_pack = category.join("Hero__123456")
    legacy_pack.mkpath
    legacy_pack.join("happy.png").binwrite("happy")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Character pack without a matching default sprite", error.message
  end

  def test_builds_nested_categories_for_regular_assets
    category = @root.join("assets/backgrounds/Anime/Evangelion")
    category.mkpath
    file = category.join("Tokyo_3_at_night.jpg")
    file.binwrite("background")

    manifest = generator.manifests.fetch("backgrounds")
    asset = manifest.dig("categories", 0, "categories", 0, "assets", 0)

    assert_equal "Anime/Evangelion/Tokyo_3_at_night", asset.fetch("id")
    assert_equal "Tokyo 3 at night", asset.fetch("label")
    assert_equal "assets/backgrounds/Anime/Evangelion/Tokyo_3_at_night.jpg", asset.dig("file", "path")
    assert_equal file.size, asset.dig("file", "byteSize")
  end

  def test_builds_music_with_an_optional_display_title
    category = @root.join("assets/music/Combat")
    category.mkpath
    titled = category.join("Boss_battle__One_Winged_Angel.webm")
    titled.binwrite("boss music")
    untitled = category.join("Tension.mp3")
    untitled.binwrite("tension music")

    assets = generator.manifests.dig("music", "categories", 0, "assets")
    boss_music = assets.find { |asset| asset.fetch("label") == "Boss battle" }
    tension_music = assets.find { |asset| asset.fetch("label") == "Tension" }

    assert_equal "Combat/Boss_battle", boss_music.fetch("id")
    assert_equal "One Winged Angel", boss_music.fetch("title")
    assert_equal "audio/webm", boss_music.dig("file", "contentType")
    refute tension_music.key?("title")
  end

  def test_generates_content_addressed_previews_incrementally
    character = @root.join("assets/characters/Hero.png")
    background = @root.join("assets/backgrounds/Forest.png")
    music = @root.join("assets/music/Theme.mp3")
    sound = @root.join("assets/sounds/Click.mp3")
    character.binwrite("large character")
    background.binwrite("large background")
    music.binwrite("long music")
    sound.binwrite("short sound")
    previewer = FakePreviewer.new
    optimized_generator = GptVnModeAssets::Generator.new(root: @root, previewer: previewer)

    optimized_generator.write!

    manifests = %w[characters backgrounds music sounds].to_h do |kind|
      [kind, JSON.parse(@root.join("#{kind}.json").read)]
    end
    character_preview = manifests.dig("characters", "assets", 0, "preview")
    background_preview = manifests.dig("backgrounds", "assets", 0, "preview")
    music_preview = manifests.dig("music", "assets", 0, "preview")
    assert_match %r{\Apreviews/characters/Hero--[0-9a-f]{16}--v1\.webp\z}, character_preview.fetch("path")
    assert_match %r{\Apreviews/backgrounds/Forest--[0-9a-f]{16}--v1\.webp\z}, background_preview.fetch("path")
    assert_match %r{\Apreviews/music/Theme--[0-9a-f]{16}--v1\.mp3\z}, music_preview.fetch("path")
    assert_equal "image/webp", character_preview.fetch("contentType")
    assert_equal "audio/mpeg", music_preview.fetch("contentType")
    refute manifests.dig("sounds", "assets", 0).key?("preview")
    assert_equal ["512x512>", "640x360>"], previewer.calls.first(2).map { |call| call[:recipe][:geometry] }
    assert_equal 3, previewer.calls.length
    assert_empty optimized_generator.outdated_manifests

    original_music_preview = @root.join(music_preview.fetch("path"))
    optimized_generator.write!
    assert_equal 3, previewer.calls.length

    music.binwrite("changed long music")
    optimized_generator.write!
    assert_equal 4, previewer.calls.length
    refute original_music_preview.exist?
    assert_empty optimized_generator.outdated_manifests
  end

  def test_generates_a_preview_for_each_appearance_default
    character = @root.join("assets/characters/Hero__123456.png")
    character.binwrite("default")
    pack = @root.join("assets/characters/Hero")
    pack.mkpath
    outfit_default = pack.join("[Armure].png")
    outfit_default.binwrite("armour default")
    pack.join("[Armure]angry.png").binwrite("armour angry")
    previewer = FakePreviewer.new
    optimized_generator = GptVnModeAssets::Generator.new(root: @root, previewer: previewer)

    optimized_generator.write!

    manifest = JSON.parse(@root.join("characters.json").read)
    appearance = manifest.dig("assets", 0, "appearances", 0)
    assert_match(
      %r{\Apreviews/characters/Hero/\[Armure\]--[0-9a-f]{16}--v1\.webp\z},
      appearance.dig("preview", "path")
    )
    assert_equal [outfit_default, character], previewer.calls.map { |call| call.fetch(:source) }
    assert_empty optimized_generator.outdated_manifests
  end

  def test_rejects_an_unknown_emotion
    category = @root.join("assets/characters/Anime")
    category.mkpath
    category.join("Rei_Ayanami.webp").binwrite("default")
    pack = category.join("Rei_Ayanami")
    pack.mkpath
    pack.join("confused.webp").binwrite("sprite")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Unknown expression", error.message
  end

  def test_rejects_an_invalid_character_color
    file = @root.join("assets/characters/Asuka__orange.webp")
    file.binwrite("sprite")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Invalid color", error.message
  end

  def test_rejects_an_empty_music_title
    file = @root.join("assets/music/Combat___.webm")
    file.binwrite("music")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Invalid music name", error.message
  end

  def test_rejects_a_hidden_file_instead_of_silently_ignoring_it
    file = @root.join("assets/sounds/.forgotten")
    file.binwrite("unused bytes")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Unsupported file extension", error.message
    assert_match ".forgotten", error.message
  end

  def test_only_ignores_empty_root_placeholders
    nested = @root.join("assets/sounds/Ambience/.gitkeep")
    nested.dirname.mkpath
    nested.write("")

    error = assert_raises(GptVnModeAssets::Error) { generator.manifests }

    assert_match "Unsupported file extension", error.message
    assert_match "Ambience/.gitkeep", error.message
  end

  def test_writes_reproducible_manifests_and_checks_them
    generator.write!

    assert_empty generator.outdated_manifests

    @root.join("music.json").write("{}\n")
    assert_equal ["music"], generator.outdated_manifests
  end

  def test_writes_badges_counting_assets_instead_of_character_sprites
    characters = @root.join("assets/characters/Anime")
    characters.mkpath
    characters.join("Asuka.webp").binwrite("default")
    pack = characters.join("Asuka")
    pack.mkpath
    pack.join("happy.webp").binwrite("happy")
    pack.join("sad.webp").binwrite("sad")

    backgrounds = @root.join("assets/backgrounds/Anime")
    backgrounds.mkpath
    backgrounds.join("Tokyo_3.jpg").binwrite("first")
    backgrounds.join("Nerv_HQ.png").binwrite("second")

    generator.write!

    assert_includes @root.join("badges/characters.svg").read, "Characters: 1"
    assert_includes @root.join("badges/backgrounds.svg").read, "Backgrounds: 2"
    assert_includes @root.join("badges/music.svg").read, "Music: 0"
    assert_empty generator.outdated_manifests

    @root.join("badges/characters.svg").write("obsolete\n")
    assert_equal ["badges/characters.svg"], generator.outdated_manifests
  end

  private

  def generator
    @generator ||= GptVnModeAssets::Generator.new(root: @root, previews: false)
  end

  def integrity_for(path)
    "sha256-#{Base64.strict_encode64(Digest::SHA256.file(path).digest)}"
  end
end
