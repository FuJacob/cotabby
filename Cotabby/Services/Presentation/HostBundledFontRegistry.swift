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
/// Owned by `OverlayController` because the candidates are a presentation concern: they only
/// matter when a ghost is about to be drawn in a stand-in face.
@MainActor
final class HostBundledFontRegistry {
    /// Levels below `Contents/Resources` the scan descends; deeper trees are asset stores.
    static let maximumDepth = 4
    /// Font files examined per bundle at most; more is a font vendor, not an app.
    static let maximumFiles = 40
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    private var namesByBundle: [String: [String]] = [:]
    private var scanning: Set<String> = []

    /// PostScript names of the text faces bundled by the app `bundleIdentifier`, once scanned.
    /// Empty until the scan for that bundle completes (it starts on the first call).
    func candidateFontNames(forBundleIdentifier bundleIdentifier: String?) -> [String] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        if let known = namesByBundle[bundleIdentifier] {
            return known
        }
        guard !scanning.contains(bundleIdentifier),
              let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL
        else {
            return []
        }
        scanning.insert(bundleIdentifier)
        Task { @MainActor [weak self] in
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            let names = await Task.detached(priority: .utility) {
                Self.registerTextFaces(under: resources)
            }.value
            guard let self else { return }
            self.namesByBundle[bundleIdentifier] = names
            self.scanning.remove(bundleIdentifier)
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
        let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        guard abs(weight) <= 0.15 else { return false }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        var characters: [UniChar] = [0x61, 0x65, 0x6E] // a e n
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return false }
        return glyphs.allSatisfy { $0 != 0 }
    }
}
