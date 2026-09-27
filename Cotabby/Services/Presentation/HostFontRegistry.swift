import AppKit
import CoreText
import Foundation
import Logging
import Security

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
/// Trust: parsing a font is parsing untrusted input, and Cotabby is unsandboxed and holds
/// Accessibility, Input Monitoring and Screen Recording. Both the font name a host reports and the
/// files in its bundle are under that host's control, so an arbitrary focused app must never be able
/// to hand its fonts to CoreText inside this process. Fonts are therefore loaded only from hosts on a
/// short allowlist, and only after the bundle on disk passes a code-signing requirement that pins
/// both its identifier and its publisher (see `hostCodeRequirement`). Everything else keeps the
/// system-font fallback.
///
/// Ownership and lifetime: a single process-wide `shared` instance, because the thing it guards —
/// CoreText's per-process font registration table — is itself process-global. Registering the same
/// URL twice is an error, so the set of already-registered files has to be tracked in exactly one
/// place.
///
/// An `actor` rather than a `@MainActor` type because its steps are blocking work that must stay off
/// the main thread: indexing a bundle's font directory reads metadata from every file (about 180 ms
/// for Word's 281 files), and registration itself is another few ms per file. Serializing through
/// the actor also gives the bookkeeping mutual exclusion for free.
actor HostFontRegistry {
    static let shared = HostFontRegistry()

    /// Hosts whose bundled fonts may be loaded. Microsoft Office apps ship their document fonts in
    /// `Contents/Resources/DFonts` and install none of them system-wide, which is the problem this
    /// type exists for. Extending the list means adding the host's publisher to
    /// `hostCodeRequirement` as well.
    nonisolated static let trustedHostBundleIdentifiers: Set<String> = [
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.microsoft.Outlook",
        "com.microsoft.onenote.mac"
    ]

    /// Microsoft's Apple Developer Team ID, as it appears in the leaf certificate of its
    /// Developer ID-signed builds.
    private static let microsoftTeamIdentifier = "UBF8T346G9"

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

    /// Per host bundle: lowercased face name -> file that vends it. Keyed by the bundle's file URL
    /// rather than its identifier, because two copies of an app can share an identifier.
    ///
    /// PostScript and family names are kept in *separate* maps because they need different
    /// tie-breaking, and conflating them is a real bug rather than a nicety. AX reports whichever
    /// name the host happens to use — Word reports the family name "Aptos", other hosts report
    /// PostScript names like "HelveticaNeue-Bold" — so both must be searchable. But a family name
    /// is ambiguous: all sixteen Aptos files report the family "Aptos", so a single first-wins map
    /// resolved "Aptos" to whichever file the directory enumerated first (in practice
    /// `Aptos-Light-Italic.ttf`) and would have drawn ghost text in light italic. PostScript names
    /// are unique and match exactly; family names resolve through `familyRepresentative(among:)`.
    private var postScriptIndexByBundle: [URL: [String: URL]] = [:]
    private var familyIndexByBundle: [URL: [String: URL]] = [:]

    /// Font files already handed to CoreText. Registering the same URL twice returns an error, and
    /// this also keeps repeated misses from re-doing work.
    private var registeredFiles: Set<URL> = []

    /// Bundles whose font directories were indexed but contained nothing, so we never rescan them.
    private var bundlesWithNoFonts: Set<URL> = []

    /// Code-signing verdicts per bundle, so the signature is checked once per bundle, not per font.
    private var bundleTrustVerdicts: [URL: Bool] = [:]

    /// Whether `bundleIdentifier` is a host whose bundled fonts may ever be loaded. A cheap,
    /// synchronous pre-check for callers on the render path; the signature check still follows.
    nonisolated static func isTrustedHost(bundleIdentifier: String) -> Bool {
        trustedHostBundleIdentifiers.contains(bundleIdentifier)
    }

    /// The code requirement a trusted host's bundle must satisfy before any of its fonts are parsed.
    ///
    /// The identifier clause pins the exact app, so a genuine Microsoft app cannot stand in for
    /// another, and neither can any other app that merely claims the identifier. The publisher
    /// clause accepts the two ways Office is distributed: Mac App Store builds, which Apple signs
    /// with its own leaf certificate (Apple only issues those after binding the identifier to the
    /// developer's account), and Developer ID builds, whose leaf carries Microsoft's Team ID.
    nonisolated static func hostCodeRequirement(for bundleIdentifier: String) -> String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic and "
            + "(certificate leaf[field.1.2.840.113635.100.6.1.9] "
            + "or certificate leaf[subject.OU] = \"\(microsoftTeamIdentifier)\")"
    }

    /// Checks that the bundle at `bundleURL` is signed and satisfies `hostCodeRequirement`.
    ///
    /// Validates the signature and the requirement but skips re-hashing the executable and every
    /// resource: a full seal check of a multi-gigabyte Office bundle costs seconds of I/O, and the
    /// trust decision this protects is "who published this bundle", which the signature answers.
    /// Tampering with a signed app's contents in place is what macOS's App Management protection
    /// guards against, and an attacker able to do that could already alter the app itself.
    nonisolated static func bundleSatisfiesHostRequirement(at bundleURL: URL, bundleIdentifier: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            hostCodeRequirement(for: bundleIdentifier) as CFString,
            [],
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            return false
        }

        let flags = SecCSFlags(
            rawValue: SecCSFlags.RawValue(kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        )
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    /// Registers whatever file in the host's bundle vends `fontName`, if any.
    ///
    /// `bundleURL` must be the running host's own bundle — resolved from the process, not looked up
    /// by identifier — so the fonts come from the copy the user is actually typing into.
    ///
    /// Returns `true` when the font is resolvable by `NSFont(name:)` *after* this call — either
    /// because this call registered it or because it was already available. Callers treat a `false`
    /// as "keep using the fallback font"; nothing here is load-bearing for correctness, only for
    /// visual fidelity.
    ///
    /// This is deliberately name-targeted instead of registering the whole directory. Bulk-loading
    /// Word's 281-file `DFonts` folder would dump hundreds of unrelated faces into our font
    /// namespace; indexing metadata once per host (about 180 ms) and registering the single matching
    /// file (a few ms) keeps the process's font table to what ghost text actually draws with.
    func ensureFontAvailable(named fontName: String, bundleIdentifier: String, bundleURL: URL) -> Bool {
        // Already resolvable (system font, previously registered, or another host registered it).
        if NSFont(name: fontName, size: 12) != nil {
            return true
        }

        let bundleKey = bundleURL.standardizedFileURL
        guard Self.isTrustedHost(bundleIdentifier: bundleIdentifier),
              isTrustedBundle(bundleKey, bundleIdentifier: bundleIdentifier),
              !bundlesWithNoFonts.contains(bundleKey)
        else {
            return false
        }

        indexBundleIfNeeded(bundleKey)
        let postScriptIndex = postScriptIndexByBundle[bundleKey] ?? [:]
        let familyIndex = familyIndexByBundle[bundleKey] ?? [:]
        guard !postScriptIndex.isEmpty || !familyIndex.isEmpty else {
            bundlesWithNoFonts.insert(bundleKey)
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

    /// The signature verdict for one bundle, computed on first use and then cached.
    private func isTrustedBundle(_ bundleURL: URL, bundleIdentifier: String) -> Bool {
        if let verdict = bundleTrustVerdicts[bundleURL] {
            return verdict
        }
        let verdict = Self.bundleSatisfiesHostRequirement(at: bundleURL, bundleIdentifier: bundleIdentifier)
        bundleTrustVerdicts[bundleURL] = verdict
        if !verdict {
            CotabbyLogger.focus.info(
                "Host bundle failed the font trust check; keeping the system font",
                metadata: [
                    "bundle_id": .string(bundleIdentifier),
                    "bundle_path": .string(bundleURL.path)
                ]
            )
        }
        return verdict
    }

    /// Builds (once per host bundle) the PostScript and family lookup maps for its font files.
    ///
    /// Reading descriptors is metadata-only — it does not load glyph data — which is what keeps a
    /// Word-sized collection (281 files, over 300 face names) at roughly 180 ms. That cost is paid
    /// once per host bundle, on this actor, off the main thread.
    private func indexBundleIfNeeded(_ bundleURL: URL) {
        guard postScriptIndexByBundle[bundleURL] == nil else { return }

        var postScript: [String: URL] = [:]
        // Local scratch state for building one bundle's family map — nothing the actor keeps.
        var family: [String: (face: FontFace, url: URL)] = [:]

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
                    if let incumbent = family[familyKey],
                       Self.familyRepresentative(among: [incumbent.face, face]) == incumbent.face {
                        continue
                    }
                    family[familyKey] = (face, fileURL)
                }
            }
        }

        postScriptIndexByBundle[bundleURL] = postScript
        familyIndexByBundle[bundleURL] = family.mapValues(\.url)
    }

    /// One face inside a font file, reduced to what face selection needs. `nonisolated` because it is
    /// a plain value built on this actor and compared by the nonisolated selection rule.
    nonisolated struct FontFace: Equatable, Sendable {
        let postScriptName: String
        let familyName: String?
        let isItalic: Bool
        /// `kCTFontWeightTrait`: 0 is regular, negative is lighter, positive is bolder.
        let weight: CGFloat
        /// `kCTFontWidthTrait`: 0 is normal, negative is condensed, positive is expanded.
        let width: CGFloat
    }

    /// The face a bare family name should resolve to.
    ///
    /// A family name means the family's regular face: upright before italic, then the weight and
    /// width closest to normal, then the PostScript name, so the choice never depends on the order a
    /// directory happens to list its files. Weight has to be compared numerically, not just by the
    /// bold bit: Light, Semilight and Medium faces carry neither the bold nor the italic bit, and a
    /// first-regular-wins rule resolved Malgun Gothic to Semilight, Microsoft YaHei to Light and
    /// Dubai to Medium purely from Word's file order.
    nonisolated static func familyRepresentative(among faces: [FontFace]) -> FontFace? {
        faces.min { lhs, rhs in
            (lhs.isItalic ? 1 : 0, abs(lhs.weight), abs(lhs.width), lhs.postScriptName)
                < (rhs.isItalic ? 1 : 0, abs(rhs.weight), abs(rhs.width), rhs.postScriptName)
        }
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
            // Traits come from the descriptor's metadata without instantiating the font.
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait as String] as? UInt32).map(CTFontSymbolicTraits.init)
            return FontFace(
                postScriptName: postScriptName,
                familyName: familyName,
                isItalic: symbolic?.contains(.traitItalic) ?? false,
                weight: (traits?[kCTFontWeightTrait as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0,
                width: (traits?[kCTFontWidthTrait as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            )
        }
    }
}
