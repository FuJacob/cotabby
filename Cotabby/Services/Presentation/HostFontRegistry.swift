import AppKit
import CoreText
import Foundation
import Logging

/// Makes a host application's *privately bundled* fonts resolvable by name inside Cotabby's process,
/// so ghost text can be drawn in the typeface the user is actually looking at.
///
/// Why this exists as its own boundary: `OverlayController` renders ghost text in the font that
/// `resolveFieldStyle` read out of Accessibility, via `NSFont(name:size:)`. That lookup only searches
/// fonts the *font system* knows about — system fonts plus anything installed in a Fonts directory.
/// Several major hosts never install their fonts at all; they ship them inside their own app bundle
/// and register them process-locally at launch. Microsoft Word is the motivating case: Aptos (its
/// default body font since Office 2024) and Calibri live in
/// `Microsoft Word.app/Contents/Resources/DFonts/` and are absent from every system font directory,
/// so `NSFont(name: "Aptos", size:)` returns nil in our process and ghost text silently falls back
/// to the system font — visibly different from the host's text.
///
/// The fix is to register the one font file we need, from the host app's own bundle, into *our*
/// process. Nothing is installed for the user or the system: `CTFontManagerScope.process` scopes the
/// registration to this running process and it disappears when Cotabby quits.
///
/// Ownership and lifetime: a single process-wide `shared` instance, because the thing it guards —
/// CoreText's per-process font registration table — is itself process-global. Registering the same
/// URL twice is an error, so the set of already-registered files has to be tracked in exactly one
/// place.
///
/// An `actor` rather than a `@MainActor` type because both of its steps are blocking disk work that
/// must stay off the main thread: indexing a bundle's font directory costs ~25 ms for a Word-sized
/// collection (280 files), and registration itself is another few ms per file. Serializing through
/// the actor also gives the dedup bookkeeping mutual exclusion for free.
actor HostFontRegistry {
    static let shared = HostFontRegistry()

    /// Font-file extensions worth probing. `.ttc` and `.dfont` are containers that can vend several
    /// faces from one file, which is why the index maps *names to files* rather than assuming 1:1.
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]

    /// Bundle-relative directories that hosts conventionally use for bundled fonts. Kept as a short
    /// fixed list rather than a recursive bundle walk: a full crawl of a multi-gigabyte app bundle
    /// on a focus change would be far more expensive than the problem it solves.
    private static let bundleFontSubpaths = [
        "Contents/Resources/DFonts",
        "Contents/Resources/OtherFonts",
        "Contents/Resources/Fonts"
    ]

    /// Per host bundle ID: lowercased face name -> file that vends it.
    ///
    /// PostScript and family names are kept in *separate* maps because they need different
    /// tie-breaking, and conflating them is a real bug rather than a nicety. AX reports whichever
    /// name the host happens to use — Word reports the family name "Aptos", other hosts report
    /// PostScript names like "HelveticaNeue-Bold" — so both must be searchable. But a family name
    /// is ambiguous: all sixteen Aptos files report the family "Aptos", so a single first-wins map
    /// resolved "Aptos" to whichever file the directory enumerated first (in practice
    /// `Aptos-Light-Italic.ttf`) and would have drawn ghost text in light italic. PostScript names
    /// are unique and match exactly; family names resolve to that family's regular face.
    private var postScriptIndexByBundle: [String: [String: URL]] = [:]
    private var familyIndexByBundle: [String: [String: URL]] = [:]

    /// Font files already handed to CoreText. Registering the same URL twice returns an error, and
    /// this also keeps repeated misses from re-doing work.
    private var registeredFiles: Set<URL> = []

    /// Bundles whose font directories were indexed but contained nothing, so we never rescan them.
    private var bundlesWithNoFonts: Set<String> = []

    /// Registers whatever file in `bundleIdentifier`'s bundle vends `fontName`, if any.
    ///
    /// Returns `true` when the font is resolvable by `NSFont(name:)` *after* this call — either
    /// because this call registered it or because it was already available. Callers treat a `false`
    /// as "keep using the fallback font"; nothing here is load-bearing for correctness, only for
    /// visual fidelity.
    ///
    /// This is deliberately name-targeted instead of registering the whole directory. Bulk-loading
    /// Word's 280-file `DFonts` folder measures ~307 ms and would dump hundreds of unrelated faces
    /// into our font namespace; indexing metadata and registering the single matching file costs
    /// ~25 ms once per host, then ~2 ms for the file itself.
    func ensureFontAvailable(named fontName: String, bundleIdentifier: String) -> Bool {
        // Already resolvable (system font, previously registered, or another host registered it).
        if NSFont(name: fontName, size: 12) != nil {
            return true
        }
        guard !bundlesWithNoFonts.contains(bundleIdentifier) else { return false }

        indexBundleIfNeeded(bundleIdentifier)
        let postScriptIndex = postScriptIndexByBundle[bundleIdentifier] ?? [:]
        let familyIndex = familyIndexByBundle[bundleIdentifier] ?? [:]
        guard !postScriptIndex.isEmpty || !familyIndex.isEmpty else {
            bundlesWithNoFonts.insert(bundleIdentifier)
            return false
        }

        // Exact PostScript name first — it identifies one specific face, including its weight and
        // slant, which is what we want when the host names the styled face the user is typing in.
        // Only then fall back to interpreting the name as a family, which yields its regular face.
        let key = fontName.lowercased()
        guard let fileURL = postScriptIndex[key] ?? familyIndex[key] else { return false }

        if !registeredFiles.contains(fileURL) {
            var error: Unmanaged<CFError>?
            // `.process` scope: visible to this process only, never installed for the user or the
            // system, and torn down automatically when Cotabby exits.
            let registered = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
            // Record the URL either way. A failure here is almost always "already registered" from
            // a race with another lookup; retrying it on every keystroke would be pure waste.
            registeredFiles.insert(fileURL)
            if !registered {
                let message = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
                CotabbyLogger.focus.debug(
                    "Host font registration failed",
                    metadata: [
                        "font_name": .string(fontName),
                        "bundle_id": .string(bundleIdentifier),
                        "error": .string(message)
                    ]
                )
            }
        }

        let resolved = NSFont(name: fontName, size: 12) != nil
        if resolved {
            CotabbyLogger.focus.info(
                "Registered host-bundled font for ghost text",
                metadata: [
                    "font_name": .string(fontName),
                    "bundle_id": .string(bundleIdentifier),
                    "file": .string(fileURL.lastPathComponent)
                ]
            )
        }
        return resolved
    }

    /// Builds (once per host) the PostScript and family lookup maps for a bundle's font files.
    ///
    /// Reading descriptors is metadata-only — it does not load glyph data — which is what keeps a
    /// Word-sized collection (280 files, 427 face names) at roughly 200 ms. That cost is paid once
    /// per host application, on this actor, off the main thread; the alternative of bulk-registering
    /// the whole directory measures ~307 ms *and* dumps hundreds of unrelated faces into our font
    /// namespace, where they would shadow nothing useful.
    private func indexBundleIfNeeded(_ bundleIdentifier: String) {
        guard postScriptIndexByBundle[bundleIdentifier] == nil else { return }

        var postScript: [String: URL] = [:]
        // The value carries whether the chosen file is the family's *regular* face, so a regular
        // face found later can displace a styled one chosen earlier. Local scratch state for
        // building one bundle's map — nothing the actor needs to keep afterwards.
        var family: [String: (url: URL, isRegular: Bool)] = [:]

        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            for subpath in Self.bundleFontSubpaths {
                let directory = bundleURL.appending(path: subpath, directoryHint: .isDirectory)
                for fileURL in fontFiles(in: directory) {
                    for face in faces(in: fileURL) {
                        // PostScript names are unique per face, so first-wins is unambiguous here;
                        // a duplicate would be the same face shipped twice.
                        let postScriptKey = face.postScriptName.lowercased()
                        postScript[postScriptKey] = postScript[postScriptKey] ?? fileURL

                        guard let familyName = face.familyName else { continue }
                        let familyKey = familyName.lowercased()
                        // A bare family name must resolve to that family's regular face. Taking the
                        // first file seen instead is how "Aptos" resolved to Aptos-Light-Italic:
                        // all sixteen Aptos files report the family "Aptos", so directory order won.
                        let incumbent = family[familyKey]
                        if incumbent == nil || (face.isRegular && !incumbent!.isRegular) {
                            family[familyKey] = (fileURL, face.isRegular)
                        }
                    }
                }
            }
        }

        postScriptIndexByBundle[bundleIdentifier] = postScript
        familyIndexByBundle[bundleIdentifier] = family.mapValues(\.url)
    }

    /// One face inside a font file, reduced to what face selection needs.
    private struct FontFace {
        let postScriptName: String
        let familyName: String?
        /// Neither bold nor italic — the face a bare family name should resolve to.
        let isRegular: Bool
    }

    private func fontFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return contents.filter { Self.fontExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Every face in one font file, with the traits needed to pick a family's regular member.
    /// A `.ttc` container vends several descriptors, so this returns a list rather than one face.
    private func faces(in fileURL: URL) -> [FontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL)
            as? [CTFontDescriptor]
        else {
            return []
        }
        return descriptors.compactMap { descriptor -> FontFace? in
            guard let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
            else {
                return nil
            }
            let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            // Symbolic traits carry the bold/italic bits without instantiating the font. A face with
            // neither bit set is the family's regular member.
            var isRegular = true
            if let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any],
               let symbolic = traits[kCTFontSymbolicTrait as String] as? UInt32 {
                let styled = CTFontSymbolicTraits(rawValue: symbolic)
                    .intersection([.traitBold, .traitItalic, .traitCondensed, .traitExpanded])
                isRegular = styled.isEmpty
            }
            return FontFace(postScriptName: postScriptName, familyName: familyName, isRegular: isRegular)
        }
    }
}
