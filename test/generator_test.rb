# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/gpt_vn_mode_assets/generator"

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
    pack = category.join("Asuka_Langley__e65a32")
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
    @generator ||= GptVnModeAssets::Generator.new(root: @root)
  end

  def integrity_for(path)
    "sha256-#{Base64.strict_encode64(Digest::SHA256.file(path).digest)}"
  end
end
