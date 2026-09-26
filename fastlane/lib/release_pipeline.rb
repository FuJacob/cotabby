# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "time"

module Cotabby
  # One short-lived instance owns one lane's release transaction. Fastfile calls
  # this boundary; shell scripts retain native signing/packaging knowledge. Pure
  # version and artifact gates stay here so tests need neither Apple credentials
  # nor a network connection. No credentials are written into release metadata.
  class ReleasePipeline
    ROOT = File.expand_path("../..", __dir__)
    REPOSITORY = "mc-hamster/CoHamster"
    IDENTITY = "Developer ID Application: Jorge Miguel Casler (8RN882MNR5)"

    def initialize(root: ROOT)
      @root = root
      @log_dir = File.join(root, "build/fastlane-logs", "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}")
    end

    def self.version(text)
      values = text.scan(/^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$/).to_h
      version = values.fetch("MARKETING_VERSION", "")
      build = values.fetch("CURRENT_PROJECT_VERSION", "")
      raise "Use a numeric major.minor.patch MARKETING_VERSION" unless version.match?(/\A\d+\.\d+\.\d+\z/)
      raise "CURRENT_PROJECT_VERSION must be a positive integer" unless build.match?(/\A[1-9]\d*\z/)
      { "version" => version, "build_number" => build }
    end

    def self.label(version, suffix)
      return version if suffix.nil? || suffix.empty?
      raise "Suffix must be alpha.N, beta.N, or rc.N (N >= 1)" unless suffix.match?(/\A(alpha|beta|rc)\.[1-9]\d*\z/)
      "#{version}-#{suffix}"
    end

    def self.check_newer!(current, previous, stable:)
      raise "Build number must exceed published build #{previous.fetch('build_number')}" unless
        current.fetch("build_number").to_i > previous.fetch("build_number").to_i
      comparison = Gem::Version.new(current.fetch("version")) <=> Gem::Version.new(previous.fetch("version"))
      raise "Version must exceed the latest stable version" if stable && comparison <= 0
      raise "Version cannot precede a published version" if comparison < 0
    end

    def self.verify_assets!(local, remote)
      expected = local.map { |path| [File.basename(path), File.size(path)] }.sort
      actual = remote.map { |asset| [asset.fetch("name"), asset.fetch("size")] }.sort
      raise "GitHub draft assets do not match the package" unless expected == actual
      remote.each do |asset|
        path = local.find { |item| File.basename(item) == asset.fetch("name") }
        expected_digest = "sha256:#{Digest::SHA256.file(path).hexdigest}"
        raise "GitHub asset checksum mismatch: #{asset['name']}" unless asset["digest"] == expected_digest
      end
    end

    # A second lane must not delete DerivedData while the first is building.
    # Logs/results and staged dev apps live elsewhere and survive cleanup.
    def exclusive
      FileUtils.mkdir_p(File.join(@root, "build"))
      File.open(File.join(@root, "build/fastlane.lock"), "w") do |lock|
        raise "Another Fastlane lane is using this checkout" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          FileUtils.rm_rf(File.join(@root, "build/DerivedData"))
        end
      end
    end

    def dev(configuration:, logs:)
      raise "configuration must be Debug or Release" unless %w[Debug Release].include?(configuration)
      run("bash", "scripts/build_and_run.sh", logs ? "logs" : "verify", configuration,
          env: { "COHAMSTER_SIGNING_IDENTITY" => identity }, log: "dev.log")
    end

    def verify(signed: true)
      # Keep tool caches in the checkout, including when the caller is sandboxed.
      cache = File.join(@root, "build/swiftlint-cache")
      FileUtils.mkdir_p(cache)
      run("swiftlint", "--strict", "--cache-path", cache, log: "lint.log")
      run("xcodegen", "generate", log: "xcodegen.log")
      run("git", "diff", "--exit-code", "HEAD", "--", "Cotabby.xcodeproj", log: "project-drift.log")
      run(RbConfig.ruby, "fastlane/tests/release_pipeline_test.rb", log: "pipeline-tests.log")
      run("python3", "-m", "unittest", "discover", "-s", "scripts/tests", log: "python-tests.log")
      check_signing! if signed
      run("bash", "scripts/prepare_cotabby_workspace.sh", log: "prepare.log")
      run("xcodebuild", "-resolvePackageDependencies", "-workspace", "build/cotabby-dependencies/Cotabby.xcworkspace",
          "-scheme", "Cotabby", "-onlyUsePackageVersionsFromResolvedFile", "-derivedDataPath", "build/DerivedData",
          log: "resolve.log")
      build_args = ["-workspace", "build/cotabby-dependencies/Cotabby.xcworkspace",
                    "-scheme", "Cotabby", "-configuration", "Debug", "-destination", "platform=macOS",
                    "-onlyUsePackageVersionsFromResolvedFile", "-derivedDataPath", "build/DerivedData"]
      run("xcodebuild", "build-for-testing", *build_args, "CODE_SIGNING_ALLOWED=NO", log: "test-build.log")
      if signed
        run("python3", "scripts/sign_local_app.py", "build/DerivedData/Build/Products/Debug/Cotabby.app",
            "--identity", identity, "--testing", log: "test-signing.log")
      end
      run("xcodebuild", "test-without-building", *build_args,
          "-resultBundlePath", File.join(@log_dir, "Tests.xcresult"),
          "-skip-testing:CotabbyTests/FoundationModelDriftEvalTests", log: "tests.log")
    end

    def doctor
      %w[xcodebuild xcrun xcodegen swiftlint git gh python3 codesign security hdiutil].each do |tool|
        raise "Missing tool: #{tool}" unless ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, tool))
        end
      end
      puts capture("xcodebuild", "-version")
      puts "Ruby #{RUBY_VERSION}; #{capture('xcodegen', '--version').strip}; SwiftLint #{capture('swiftlint', 'version').strip}"
      check_signing!
      capture("xcrun", "notarytool", "history", *notary_args, "--output-format", "json")
      repo = JSON.parse(capture("gh", "repo", "view", REPOSITORY, "--json", "nameWithOwner,viewerPermission"))
      raise "GitHub account needs write access to #{REPOSITORY}" unless %w[ADMIN MAINTAIN WRITE].include?(repo["viewerPermission"])
      puts "Signing, notarization, and GitHub access are ready."
    end

    def package(suffix: nil)
      commit = clean_commit!
      metadata = current_version
      release_label = self.class.label(metadata.fetch("version"), suffix)
      notes = "releases/cohamster-#{release_label}.md"
      raise "Missing release notes: #{notes}" unless File.file?(File.join(@root, notes))
      check_signing!
      # Fail before compiling if the stored notary credentials cannot authenticate.
      capture("xcrun", "notarytool", "history", *notary_args, "--output-format", "json")
      output = File.join(@root, "build/releases", "#{release_label}-#{metadata.fetch('build_number')}")
      raise "Artifact directory already exists: #{output}. Move it aside before retrying." if File.exist?(output)
      FileUtils.mkdir_p(output)
      run("bash", "scripts/release_cotabby.sh", env: {
        "COHAMSTER_SIGNING_IDENTITY" => identity, "NOTARY_PROFILE" => notary_profile,
        "COHAMSTER_RELEASE_LABEL" => release_label, "COHAMSTER_RELEASE_NOTES" => notes
      }, log: "package.log")
      raise "Checkout changed during packaging" unless clean_commit! == commit
      release_dir = File.join(@root, "build/cotabby-release")
      dmg = File.join(output, "Cotabby-#{release_label}-arm64.dmg")
      FileUtils.cp(File.join(release_dir, File.basename(dmg)), dmg)
      source_archive(output, release_label, commit, release_dir)
      run("ditto", "-c", "-k", "--keepParent", File.join(release_dir, "Cotabby.xcarchive/dSYMs"),
          File.join(output, "Cotabby-#{release_label}-dSYMs.zip"))
      metadata.merge!("commit" => commit, "tag" => "cohamster-v#{release_label}", "prerelease" => !suffix.to_s.empty?,
                      "native_commit" => capture("git", "-C", File.join(release_dir, "CotabbyInference"), "rev-parse", "HEAD").strip,
                      "native_patch_sha256" => Digest::SHA256.file(File.join(@root, "patches/cotabbyinference-upstream-pending.patch")).hexdigest,
                      "xcode" => capture("xcodebuild", "-version").strip, "created_at" => Time.now.utc.iso8601)
      File.write(File.join(output, "release.json"), JSON.pretty_generate(metadata) + "\n")
      FileUtils.cp(File.join(@root, notes), File.join(output, "Release-Notes.md"))
      assets = Dir.glob(File.join(output, "*")).sort
      checksum_file = File.join(output, "SHA256SUMS.txt")
      File.write(checksum_file, assets.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{File.basename(path)}\n" }.join)
      raise "Checkout changed while collecting artifacts" unless clean_commit! == commit
      puts "Verified package: #{output}"
      { metadata: metadata, assets: assets + [checksum_file], notes: File.join(@root, notes) }
    end

    def publish(suffix: nil)
      commit = clean_commit!
      metadata = current_version
      tag = "cohamster-v#{self.class.label(metadata.fetch('version'), suffix)}"
      preflight_publish!(tag, metadata)
      api("repos/#{REPOSITORY}/commits/#{commit}") # Reject local commits that have not been pushed.
      verify
      raise "Checkout changed during verification" unless clean_commit! == commit
      artifact = package(suffix: suffix)
      # Repeat immediately before mutation: another checkout may have published
      # while this one built. Existing tags/releases are never overwritten.
      preflight_publish!(tag, metadata)
      raise "Checkout changed before publication" unless clean_commit! == commit
      # Creating a ref fails atomically if another publisher took the same tag.
      # The draft therefore cannot silently reuse a tag pointing at other code.
      api("repos/#{REPOSITORY}/git/refs", method: "POST", data: { ref: "refs/tags/#{tag}", sha: commit })
      draft = api("repos/#{REPOSITORY}/releases", method: "POST", data: {
        tag_name: tag, target_commitish: commit, name: "Cotabby #{self.class.label(metadata.fetch('version'), suffix)}",
        body: File.read(artifact.fetch(:notes)), draft: true, prerelease: !suffix.to_s.empty?, make_latest: "false"
      })
      puts "Draft created: #{draft.fetch('html_url')}"
      run("gh", "release", "upload", tag, *artifact.fetch(:assets), "--repo", REPOSITORY)
      uploaded = api("repos/#{REPOSITORY}/releases/#{draft.fetch('id')}/assets", paginate: true).flatten
      self.class.verify_assets!(artifact.fetch(:assets), uploaded)
      published = api("repos/#{REPOSITORY}/releases/#{draft.fetch('id')}", method: "PATCH", data: {
        draft: false, prerelease: !suffix.to_s.empty?, make_latest: suffix.to_s.empty? ? "true" : "false"
      })
      puts "Published: #{published.fetch('html_url')}"
    end

    private

    def identity
      ENV.fetch("COHAMSTER_SIGNING_IDENTITY", IDENTITY)
    end

    def notary_profile
      ENV.fetch("NOTARY_PROFILE", "McHamster")
    end

    def notary_args
      args = ["--keychain-profile", notary_profile]
      args += ["--keychain", ENV.fetch("NOTARY_KEYCHAIN")] if ENV["NOTARY_KEYCHAIN"] && !ENV["NOTARY_KEYCHAIN"].empty?
      args
    end

    def current_version
      self.class.version(File.read(File.join(@root, "Config/Version.xcconfig")))
    end

    def clean_commit!
      raise "Commit or stash changes before packaging/publishing (including untracked files)" unless
        capture("git", "status", "--porcelain", "--untracked-files=normal").strip.empty?
      capture("git", "rev-parse", "HEAD").strip
    end

    def check_signing!
      raise "Use a Developer ID Application certificate for distribution" unless identity.start_with?("Developer ID Application:")
      identities = capture("security", "find-identity", "-v", "-p", "codesigning")
      raise "Signing identity/private key unavailable: #{identity}" unless identities.include?(%Q("#{identity}"))
    end

    def preflight_publish!(tag, metadata)
      releases = api("repos/#{REPOSITORY}/releases", paginate: true).flatten
      raise "Release #{tag} already exists; published assets are immutable" if releases.any? { |item| item["tag_name"] == tag }
      tags = api("repos/#{REPOSITORY}/git/matching-refs/tags/#{tag}")
      raise "Tag #{tag} already exists; choose a new version/suffix" if tags.any? { |item| item["ref"] == "refs/tags/#{tag}" }
      releases.reject { |item| item["draft"] }.each do |release|
        next unless release.fetch("tag_name").start_with?("cohamster-v")
        # The canonical file is read from each published tag, so legacy releases
        # without release.json still participate in the build-number gate.
        file = api("repos/#{REPOSITORY}/contents/Config/Version.xcconfig?ref=#{release.fetch('tag_name')}", allow_missing: true)
        if file
          previous = self.class.version(Base64.decode64(file.fetch("content")))
        else
          legacy_version = release.fetch("tag_name")[/\Acohamster-v(\d+\.\d+\.\d+)(?:-(?:alpha|beta|rc)\.\d+)?\z/, 1]
          raise "Cannot establish version of #{release.fetch('tag_name')}" unless legacy_version
          puts "Legacy #{release.fetch('tag_name')} has no canonical build number; checking its version only."
          previous = { "version" => legacy_version, "build_number" => "0" }
        end
        self.class.check_newer!(metadata, previous, stable: !release.fetch("prerelease"))
      end
    end

    def source_archive(output, label, commit, release_dir)
      Dir.mktmpdir("cohamster-source-") do |temporary|
        source = File.join(temporary, "Cotabby-#{label}")
        FileUtils.mkdir_p(source)
        archive = File.join(temporary, "source.tar")
        run("git", "archive", "--format=tar", "--output=#{archive}", commit)
        run("tar", "-xf", archive, "-C", source)
        native = File.join(source, "vendor/CotabbyInference")
        FileUtils.mkdir_p(native)
        run("git", "-C", File.join(release_dir, "CotabbyInference"), "archive", "--format=tar", "--output=#{archive}", "HEAD")
        run("tar", "-xf", archive, "-C", native)
        run("git", "-C", native, "apply", File.join(source, "patches/cotabbyinference-upstream-pending.patch"))
        File.write(File.join(source, "BUILDING-SOURCE.txt"), <<~TEXT)
          This archive contains Cotabby commit #{commit} and the patched native source in vendor/CotabbyInference.
          Model weights are not included. See THIRD_PARTY_LICENSES.md and releases/README.md.
          Install Xcode and XcodeGen. From this directory:
            xcodegen generate
            python3 scripts/create-inference-workspace.py vendor/CotabbyInference --output build/source/Cotabby.xcworkspace
            mkdir -p build/source/Cotabby.xcworkspace/xcshareddata/swiftpm
            cp Config/Package.resolved build/source/Cotabby.xcworkspace/xcshareddata/swiftpm/Package.resolved
            xcodebuild -workspace build/source/Cotabby.xcworkspace -scheme Cotabby -configuration Release -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
          SwiftPM downloads the other pinned dependencies. This produces an unsigned local build.
        TEXT
        run("tar", "-czf", File.join(output, "Cotabby-#{label}-source.tar.gz"), "-C", temporary, File.basename(source))
      end
    end

    def api(path, method: "GET", data: nil, paginate: false, allow_missing: false)
      args = ["gh", "api", path, "--method", method]
      args += ["--paginate", "--slurp"] if paginate
      args += ["--input", "-"] if data
      response = capture(*args, input: data ? JSON.generate(data) : "", allow_not_found: allow_missing)
      response && JSON.parse(response)
    end

    def capture(*args, input: "", allow_not_found: false)
      output, error, status = Open3.capture3(*args, stdin_data: input, chdir: @root)
      if !status.success? && allow_not_found
        response = JSON.parse(output) rescue {}
        return nil if response["status"].to_s == "404"
      end
      raise "#{args.first} failed (#{status.exitstatus}): #{error}\n#{output}" unless status.success?
      output
    end

    def run(*args, env: {}, log: nil)
      FileUtils.mkdir_p(@log_dir)
      file = log && File.open(File.join(@log_dir, log), "a")
      puts "Running #{args.first} #{args[1]}#{log ? " (log: #{File.join(@log_dir, log)})" : ''}"
      Open3.popen2e(env, *args, chdir: @root) do |stdin, output, process|
        stdin.close
        output.each_line { |line| $stdout.print(line); file&.write(line) }
        raise "#{args.first} failed; see #{log || 'output above'}" unless process.value.success?
      end
    ensure
      file&.close
    end
  end
end
