#!/usr/bin/env ruby
# Adds a `CotabbyTests` unit-test target to Cotabby.xcodeproj and wires the
# existing Swift files in `CotabbyTests/` into it. Idempotent — safe to re-run.
#
# Why a script instead of clicking through Xcode:
#  - Xcode's target template is opaque; running it on every contributor's box
#    risks divergent settings. Source-of-truth in a script keeps the setup
#    reproducible and reviewable.
#  - Test infrastructure should be inspectable like any other code. Diffing a
#    Ruby script is much easier than diffing a pbxproj mutation.
#
# Requires the `xcodeproj` Ruby gem. On macOS with CocoaPods installed, the
# cocoapods GEM_HOME already ships it; the Makefile-free way to invoke is:
#
#   GEM_HOME="/opt/homebrew/Cellar/cocoapods/<ver>/libexec" \
#     ruby scripts/add_test_target.rb

require 'xcodeproj'

PROJECT_PATH      = 'Cotabby.xcodeproj'
HOST_TARGET_NAME  = 'Cotabby'
TEST_TARGET_NAME  = 'CotabbyTests'
DEPLOYMENT_TARGET = '26.0'
TEST_BUNDLE_ID    = 'com.jacobfu.tabby.CotabbyTests'
TESTS_DIR         = 'CotabbyTests'

project = Xcodeproj::Project.open(PROJECT_PATH)

host_target = project.targets.find { |t| t.name == HOST_TARGET_NAME }
raise "Host target '#{HOST_TARGET_NAME}' not found" unless host_target

# --- 1. Ensure the test target exists ---------------------------------------
# `new_target` is not idempotent; guard on presence so re-runs don't duplicate.
test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }
if test_target.nil?
  test_target = project.new_target(
    :unit_test_bundle,
    TEST_TARGET_NAME,
    :osx,
    DEPLOYMENT_TARGET,
    project.products_group,
    :swift
  )
end

# --- 2. Build settings ------------------------------------------------------
# TEST_HOST + BUNDLE_LOADER let the test bundle load the app's symbols at
# test time; this is what makes `@testable import Cotabby` actually resolve.
# We intentionally disable code signing for the test bundle so CI runners
# without the dev cert can still run `xcodebuild test`.
test_target.build_configurations.each do |config|
  config.build_settings.merge!(
    # xcodeproj's `new_target` skips PRODUCT_NAME for unit test bundles; without
    # it the swift compiler sees `-module-name ""` and fails. Setting both
    # keeps `swiftc` happy and keeps the compiled .xctest bundle on a
    # predictable name.
    'PRODUCT_NAME'                 => '$(TARGET_NAME)',
    'PRODUCT_MODULE_NAME'          => '$(TARGET_NAME)',
    'TEST_HOST'                    => '$(BUILT_PRODUCTS_DIR)/Cotabby.app/Contents/MacOS/Cotabby',
    'BUNDLE_LOADER'                => '$(TEST_HOST)',
    'PRODUCT_BUNDLE_IDENTIFIER'    => TEST_BUNDLE_ID,
    'SWIFT_VERSION'                => '5.0',
    'MACOSX_DEPLOYMENT_TARGET'     => DEPLOYMENT_TARGET,
    'GENERATE_INFOPLIST_FILE'      => 'YES',
    'CODE_SIGN_STYLE'              => 'Automatic',
    'CODE_SIGN_IDENTITY'           => '-',
    'CODE_SIGNING_REQUIRED'        => 'NO',
    'CODE_SIGNING_ALLOWED'         => 'NO',
    'LD_RUNPATH_SEARCH_PATHS'      => ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
  )
end

# --- 3. Target dependency on the host app -----------------------------------
unless test_target.dependencies.any? { |dep| dep.target == host_target }
  test_target.add_dependency(host_target)
end

# Xcodeproj's `new_target(:unit_test_bundle, :osx, ...)` helpfully adds
# Cocoa.framework to the Frameworks build phase, but it hardcodes the path
# to whatever SDK string the gem was last updated against (today: MacOSX15.0).
# Our SDK is 26.x; pure Swift XCTest bundles don't need Cocoa anyway. Strip
# the build-file entry so we don't ship a stale reference.
test_target.frameworks_build_phase.files.to_a.each do |build_file|
  file_ref = build_file.file_ref
  next unless file_ref&.path&.include?('Cocoa.framework')

  test_target.frameworks_build_phase.remove_build_file(build_file)
  # Unlink from whichever group the gem parked it in (usually an "OS X" group
  # created as a side effect), then drop the file reference entirely.
  file_ref.remove_from_project
end

# Prune any empty groups left behind after removing Cocoa — otherwise a
# phantom "OS X" group shows up in the Xcode navigator with nothing in it.
project.main_group.recursive_children.to_a.each do |child|
  next unless child.is_a?(Xcodeproj::Project::Object::PBXGroup)
  next unless child.children.empty?
  next if child == project.products_group || child == project.main_group

  child.remove_from_project
end

# --- 4. File group + source membership --------------------------------------
# Idempotent: find-or-create the group, then only add file refs that aren't
# already present. This way re-running after adding new test files just
# incorporates the new ones.
tests_group = project.main_group[TESTS_DIR] ||
              project.main_group.new_group(TESTS_DIR, TESTS_DIR)

test_files = Dir.glob(File.join(TESTS_DIR, '*.swift')).sort
raise "No test files in #{TESTS_DIR}/" if test_files.empty?

existing_paths = tests_group.files.map(&:path)
test_files.each do |path|
  basename = File.basename(path)
  next if existing_paths.include?(basename)

  file_ref = tests_group.new_reference(basename)
  test_target.add_file_references([file_ref])
end

# --- 5. Scheme: add the test target to the Test action ----------------------
# Without this, `xcodebuild test -scheme Cotabby` has nothing to run.
scheme_path = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes', "#{HOST_TARGET_NAME}.xcscheme")
scheme = Xcodeproj::XCScheme.new(scheme_path)

already_testable = scheme.test_action.testables.any? do |testable|
  testable.buildable_references.any? { |ref| ref.target_name == TEST_TARGET_NAME }
end

unless already_testable
  testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
  scheme.test_action.add_testable(testable)
end

# --- 6. Save ----------------------------------------------------------------
scheme.save_as(PROJECT_PATH, HOST_TARGET_NAME, true)
project.save

puts "Target '#{TEST_TARGET_NAME}' present: #{!project.targets.find { |t| t.name == TEST_TARGET_NAME }.nil?}"
puts "Files wired:"
test_target.source_build_phase.files_references.each do |ref|
  puts "  - #{ref.path}"
end
puts "Scheme updated: #{scheme_path}"
