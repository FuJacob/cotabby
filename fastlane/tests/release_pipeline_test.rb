# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/release_pipeline"

# Exercise the publication boundary with in-memory GitHub responses. These tests
# protect the irreversible step: validation/upload failures must leave a draft.
class ReleasePipelineTest < Minitest::Test
  Pipeline = CoHamster::ReleasePipeline

  def test_version_and_suffix_validation
    assert_equal({ "version" => "0.7.0", "build_number" => "2026092601" },
                 Pipeline.version("MARKETING_VERSION = 0.7.0\nCURRENT_PROJECT_VERSION = 2026092601\n"))
    assert_equal "0.7.0-beta.1", Pipeline.label("0.7.0", "beta.1")
    %w[beta.0 ../secret rc.1/other $(whoami)].each do |suffix|
      assert_raises(RuntimeError) { Pipeline.label("0.7.0", suffix) }
    end
    assert_raises(RuntimeError) { Pipeline.version("MARKETING_VERSION = 0.7.0-beta.1\nCURRENT_PROJECT_VERSION = 1") }
    assert_raises(RuntimeError) { Pipeline.version("MARKETING_VERSION = 0.7.0\nCURRENT_PROJECT_VERSION = 0") }
  end

  def test_build_and_version_must_advance
    current = { "version" => "0.7.0", "build_number" => "11" }
    previous = { "version" => "0.7.0", "build_number" => "10" }
    Pipeline.check_newer!(current, previous, stable: false) # RC to final may share numeric version.
    assert_raises(RuntimeError) { Pipeline.check_newer!(current, previous, stable: true) }
    assert_raises(RuntimeError) { Pipeline.check_newer!(current, current, stable: false) }
    assert_raises(RuntimeError) do
      Pipeline.check_newer!(current.merge("version" => "0.6.9"), previous, stable: false)
    end
  end

  def test_uploaded_bytes_must_match_and_extra_assets_fail
    Dir.mktmpdir do |root|
      path = File.join(root, "artifact.dmg")
      File.write(path, "good")
      asset = { "name" => "artifact.dmg", "size" => 4, "digest" => "sha256:#{Digest::SHA256.file(path).hexdigest}" }
      Pipeline.verify_assets!([path], [asset])
      assert_raises(RuntimeError) { Pipeline.verify_assets!([path], [asset.merge("digest" => "sha256:bad")]) }
      assert_raises(RuntimeError) { Pipeline.verify_assets!([path], [asset.merge("size" => 3)]) }
      assert_raises(RuntimeError) { Pipeline.verify_assets!([path], [asset, asset.merge("name" => "extra")]) }
    end
  end

  # This fixture lives only for one test. It replaces OS/network boundaries while
  # retaining publish's real ordering, commit checks, and artifact verification.
  class PublishingFixture < Pipeline
    attr_reader :events
    attr_accessor :failure

    def initialize(root:)
      super
      @events = []
      @asset = File.join(root, "artifact.dmg")
      File.write(@asset, "signed artifact")
      @notes = File.join(root, "notes.md")
      File.write(@notes, "Release notes")
    end

    def clean_commit! = "a" * 40
    def current_version = { "version" => "0.7.0", "build_number" => "20" }
    def preflight_publish!(*args) = @events.push(:preflight)

    def verify
      @events << :verify
      raise "Tests failed" if failure == :verify
    end

    def package(suffix:)
      @events << :package
      raise "Notarization failed" if failure == :package
      { assets: [@asset], notes: @notes }
    end

    def run(*args, **options)
      @events << :upload
      raise "Upload failed" if failure == :upload
    end

    def api(path, method: "GET", data: nil, **options)
      @events << [method, data]
      return [{ "name" => "artifact.dmg", "size" => File.size(@asset),
                "digest" => failure == :digest ? "wrong" : "sha256:#{Digest::SHA256.file(@asset).hexdigest}" }] if path.end_with?("/assets")
      { "id" => 123, "html_url" => "https://github.com/example/release" }
    end
  end

  def test_no_publication_after_failed_validation_notarization_or_upload
    %i[verify package upload digest].each do |failure|
      Dir.mktmpdir do |root|
        pipeline = PublishingFixture.new(root: root)
        pipeline.failure = failure
        assert_raises(RuntimeError) { pipeline.publish }
        refute pipeline.events.any? { |event| event.is_a?(Array) && event.first == "PATCH" }
        if %i[verify package].include?(failure)
          refute pipeline.events.any? { |event| event.is_a?(Array) && event.first == "POST" }
        end
      end
    end
  end

  def test_draft_targets_exact_commit_and_latest_is_stable_only
    [nil, "beta.1"].each do |suffix|
      Dir.mktmpdir do |root|
        pipeline = PublishingFixture.new(root: root)
        pipeline.publish(suffix: suffix)
        post = pipeline.events.find { |event| event.is_a?(Array) && event.first == "POST" && event.last.key?(:draft) }.last
        patch = pipeline.events.find { |event| event.is_a?(Array) && event.first == "PATCH" }.last
        assert_equal "a" * 40, post[:target_commitish]
        assert_equal true, post[:draft]
        assert_equal false, patch[:draft]
        assert_equal !suffix.nil?, patch[:prerelease]
        assert_equal suffix.nil? ? "true" : "false", patch[:make_latest]
      end
    end
  end

  def test_dirty_checkout_rejected_and_only_derived_data_is_cleaned
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root, exception: true)
      File.write(File.join(root, "untracked"), "work")
      pipeline = Pipeline.new(root: root)
      assert_raises(RuntimeError) { pipeline.send(:clean_commit!) }
      FileUtils.mkdir_p(File.join(root, "build/DerivedData"))
      FileUtils.mkdir_p(File.join(root, "build/releases"))
      assert_raises(RuntimeError) { pipeline.exclusive { raise "Build failure" } }
      refute File.exist?(File.join(root, "build/DerivedData"))
      assert File.directory?(File.join(root, "build/releases"))
      assert_equal "work", File.read(File.join(root, "untracked"))
    end
  end

  def test_existing_tags_and_legacy_versions_are_checked
    Dir.mktmpdir do |root|
      pipeline = Pipeline.new(root: root)
      responses = {
        "repos/#{Pipeline::REPOSITORY}/releases" => [{ "tag_name" => "cohamster-v0.6.3", "draft" => false, "prerelease" => true }],
        "repos/#{Pipeline::REPOSITORY}/git/matching-refs/tags/cohamster-v0.7.0" => [],
        "repos/#{Pipeline::REPOSITORY}/contents/Config/Version.xcconfig?ref=cohamster-v0.6.3" => nil
      }
      pipeline.define_singleton_method(:api) { |path, **options| responses.fetch(path) }
      pipeline.send(:preflight_publish!, "cohamster-v0.7.0", { "version" => "0.7.0", "build_number" => "12" })
      responses["repos/#{Pipeline::REPOSITORY}/git/matching-refs/tags/cohamster-v0.7.0"] = [{ "ref" => "refs/tags/cohamster-v0.7.0" }]
      assert_raises(RuntimeError) do
        pipeline.send(:preflight_publish!, "cohamster-v0.7.0", { "version" => "0.7.0", "build_number" => "12" })
      end
    end
  end

  def test_source_archive_contains_committed_app_and_patched_native_source_only
    Dir.mktmpdir do |root|
      git = lambda do |directory, *args|
        output, error, status = Open3.capture3("git", "-C", directory, *args)
        raise error unless status.success?
        output.strip
      end
      app = File.join(root, "app")
      native = File.join(app, "build/cohamster-release/CotabbyInference")
      output = File.join(root, "artifacts")
      FileUtils.mkdir_p([File.join(app, "patches"), native, output])
      [app, native].each do |directory|
        git.call(directory, "init", "-q")
        git.call(directory, "config", "user.name", "Pipeline Test")
        git.call(directory, "config", "user.email", "test@example.invalid")
      end
      File.write(File.join(native, "native.txt"), "before\n")
      git.call(native, "add", "native.txt")
      git.call(native, "commit", "-qm", "native baseline")
      File.write(File.join(native, "native.txt"), "patched\n")
      patch = git.call(native, "diff", "HEAD") + "\n"
      File.write(File.join(app, "patches/cotabbyinference-mchamster.patch"), patch)
      File.write(File.join(app, "app.txt"), "committed source")
      File.write(File.join(app, ".gitignore"), "build/\n")
      git.call(app, "add", "app.txt", ".gitignore", "patches")
      git.call(app, "commit", "-qm", "app baseline")
      File.write(File.join(app, "untracked-secret.txt"), "never distribute")
      pipeline = Pipeline.new(root: app)
      pipeline.send(:source_archive, output, "0.7.0", git.call(app, "rev-parse", "HEAD"), File.dirname(native))
      system("tar", "-xzf", File.join(output, "CoHamster-0.7.0-source.tar.gz"), "-C", output, exception: true)
      extracted = File.join(output, "CoHamster-0.7.0")
      assert_equal "committed source", File.read(File.join(extracted, "app.txt"))
      assert_equal "patched\n", File.read(File.join(extracted, "vendor/CotabbyInference/native.txt"))
      assert File.file?(File.join(extracted, "BUILDING-SOURCE.txt"))
      refute File.exist?(File.join(extracted, "untracked-secret.txt"))
      refute File.exist?(File.join(extracted, "build"))
    end
  end
end
