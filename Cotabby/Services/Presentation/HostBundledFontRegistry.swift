import AppKit
import CoreText
import Foundation
import Logging

/// File overview:
/// Makes the text faces an Electron host ships inside its own bundle available to the pixel
/// typeface match, so a ghost in that host can be drawn in the host's real face.
///
/// Why this exists: `TypefaceMatcher` can only name a face this Mac can render, and Electron apps
/// bring their own. The Claude desktop composer sets its text in Anthropic Sans, a TrueType file
/// under the app's `Contents/Resources/fonts` that no system font approximates: measured
/// 2026-09-10 on a strip of that composer, the bundled face scored 0.91 while the best installed
/// candidate reached 0.87 at some other size, so without the file the match could only decline or
/// name the wrong face. Registering the file process-wide (`CTFontManagerRegisterFontsForURL`
/// with `.process` scope: visible to Cotabby alone, gone when it quits, nothing installed) turns
/// it into an ordinary candidate that `NSFont(name:size:)` resolves at any size.
///
/// What is scanned: the bundle's `Contents/Resources` tree, a bounded number of levels and files
/// deep, for TrueType and OpenType files (WOFF is a web format CoreText cannot load). Of each
/// file's faces only the upright, regular-weight text faces are candidates: bold and italic are not
/// how a composer sets its body, and icon fonts carry no letters at all. The scan runs once per
/// bundle identifier, off the main actor, and its answer is cached for the process's life; until
/// it lands the match proceeds with the installed candidates, as before.
///
/// Trust: this is the same untrusted-input problem `HostFontRegistry` guards against. Parsing and
/// registering a font hands a file from the focused app's bundle to CoreText inside Cotabby, which
/// is unsandboxed and holds Accessibility, Input Monitoring and Screen Recording, and every
/// non-browser app with a web field reaches this registry. So only allowlisted hosts are scanned,
/// and only after their bundle passes the same code requirement `HostFontRegistry` applies (exact
/// identifier, pinned publisher). Any other app keeps the installed candidates.
///
/// Owned by `HostTypefaceResolver` because the candidates are a presentation concern: they only
/// matter when a ghost is about to be drawn in a stand-in face.
@MainActor
final class HostBundledFontRegistry {
    /// Levels below `Contents/Resources` the scan descends; deeper trees are asset stores.
    static let maximumDepth = 4
    /// Font files examined per bundle at most; more is a font vendor, not an app.
    static let maximumFiles = 40
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// Hosts whose bundled faces may be loaded, each with the Apple Team ID that must sign it.
    /// Matched exactly, as the code requirement's identifier clause is. Add a host only for a
    /// measured need (its editor is set in a face it bundles under `Contents/Resources`), together
    /// with its publisher's Team ID.
    nonisolated static let trustedHostTeamIdentifiers: [String: String] = [
        // Claude desktop: its composer is set in the bundled Anthropic Sans (see the file overview).
        "com.anthropic.claudefordesktop": "Q6L2SF6YDW"
    ]

    /// How far the one scan of a bundle has got. A bundle identifier with no entry has not been
    /// asked about yet.
    private enum Scan {
        case scanning
        /// The bundle failed the code-signature check: none of its font files are ever opened.
        case untrusted
        /// PostScript names of the bundle's text faces, possibly none.
        case scanned([String])
    }

    private var scans: [String: Scan] = [:]

    // Xcode 26.0-26.3 emits an isolated deinit for a stored-property @MainActor class whose
    // teardown double-frees when a test-scoped instance deallocates ("pointer being freed was not
    // allocated"). Nothing here needs main-actor cleanup, so a nonisolated deinit is equivalent.
    nonisolated deinit {}

    /// Whether `bundleIdentifier` is a host whose bundled faces may ever be loaded. A cheap,
    /// synchronous pre-check on the render path; the signature check still follows.
    nonisolated static func isTrustedHost(bundleIdentifier: String) -> Bool {
        trustedHostTeamIdentifiers[bundleIdentifier] != nil
    }

    /// Whether the bundle at `bundleURL` is a genuine build of the allowlisted `bundleIdentifier`,
    /// by the `HostFontRegistry` code requirement with that host's publisher. Blocking disk I/O, so
    /// it runs in the detached scan, before any font file is opened.
    nonisolated static func bundleIsTrusted(at bundleURL: URL, bundleIdentifier: String) -> Bool {
        guard let teamIdentifier = trustedHostTeamIdentifiers[bundleIdentifier] else { return false }
        return HostFontRegistry.bundleSatisfies(
            requirementText: HostFontRegistry.codeRequirement(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier),
            at: bundleURL
        )
    }

    /// PostScript names of the text faces bundled by the app `bundleIdentifier`, once scanned.
    /// Empty until the scan for that bundle completes (it starts on the first call), and always
    /// empty for a host that is not allowlisted or whose bundle fails the signature check.
    func candidateFontNames(forBundleIdentifier bundleIdentifier: String?) -> [String] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              Self.isTrustedHost(bundleIdentifier: bundleIdentifier)
        else { return [] }
        switch scans[bundleIdentifier] {
        case .scanned(let names)?:
            return names
        case .scanning?, .untrusted?:
            return []
        case nil:
            break
        }
        // A host that is not running yet is asked again on the next call rather than marked.
        guard let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL else {
            return []
        }
        scans[bundleIdentifier] = .scanning
        Task { @MainActor [weak self] in
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            // The signature check reads the bundle's code signature from disk, so it shares the
            // detached task with the scan, and it comes first so no font file of a bundle that
            // fails it is ever opened. nil means it failed.
            let scanned = await Task.detached(priority: .utility) { () -> [String]? in
                guard Self.bundleIsTrusted(at: bundleURL, bundleIdentifier: bundleIdentifier) else {
                    return nil
                }
                return Self.registerTextFaces(under: resources)
            }.value
            guard let self else { return }
            guard let names = scanned else {
                self.scans[bundleIdentifier] = .untrusted
                CotabbyLogger.suggestion.info(
                    "Host bundle failed the font trust check; keeping installed faces",
                    metadata: [
                        "stage": .string("host-fonts"),
                        "bundle": .string(bundleIdentifier),
                        "bundle_path": .string(bundleURL.path)
                    ]
                )
                return
            }
            self.scans[bundleIdentifier] = .scanned(names)
            CotabbyLogger.suggestion.debug(
                "Host bundled fonts registered",
                metadata: [
                    "stage": .string("host-fonts"),
                    "bundle": .string(bundleIdentifier),
                    "faces": .string(names.joined(separator: ","))
                ]
            )
        }
        return []
    }

    /// Registers the font files under `directory` for this process and returns the PostScript
    /// names of the upright, regular-weight text faces among them. A file whose faces CoreText can
    /// already render (an app bundling a font that is installed here too) is not registered again:
    /// a second copy of an installed face would shadow the installed one, and the bundle's copy
    /// can vanish with the host while the installed one cannot.
    nonisolated static func registerTextFaces(under directory: URL) -> [String] {
        var names: [String] = []
        for file in fontFiles(under: directory) {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else { continue }
            let faceNames = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            guard !faceNames.isEmpty else { continue }
            if !faceNames.allSatisfy({ NSFont(name: $0, size: 12)?.fontName == $0 }) {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
            for descriptor in descriptors where isUprightRegularTextFace(descriptor) {
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                   !names.contains(name), NSFont(name: name, size: 12) != nil {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// TrueType/OpenType files under `directory`, bounded in depth and count.
    nonisolated static func fontFiles(under directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let baseDepth = directory.standardizedFileURL.pathComponents.count
        var files: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.standardizedFileURL.pathComponents.count - baseDepth
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            guard fontExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            files.append(url)
            if files.count >= maximumFiles {
                break
            }
        }
        return files
    }

    /// A body-text face: upright, regular weight, and able to set letters (icon fonts cannot).
    nonisolated static func isUprightRegularTextFace(_ descriptor: CTFontDescriptor) -> Bool {
        guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any] else { return false }
        let symbolic = (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0
        guard symbolic & CTFontSymbolicTraits.traitItalic.rawValue == 0 else { return false }
        let weight: Double = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        // `.magnitude` rather than `abs`: Xcode 26.3 finds `abs` ambiguous for this Double.
        guard weight.magnitude <= 0.15 else { return false }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        var characters: [UniChar] = [0x61, 0x65, 0x6E] // a e n
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return false }
        return glyphs.allSatisfy { $0 != 0 }
    }
}
