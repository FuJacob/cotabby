import Foundation

/// The surface description that conditions a prompt: what kind of app the user is writing in,
/// plus the sanitized window title, web domain, and field placeholder when available.
nonisolated struct SurfaceContext: Equatable, Sendable {
    let surfaceClass: AppSurfaceClass
    let applicationName: String
    let windowTitle: String?
    let domain: String?
    let fieldPlaceholder: String?
}

/// Builds the surface description from raw focus-capture metadata and renders it as the short
/// declarative preface the base model conditions on.
///
/// Two invariants matter here:
///
/// - **Omission beats noise.** Code editors and terminals get NO surface section at all: app
///   metadata biases a small base model toward code/numbers over prose, which is exactly wrong in
///   the one class of app where the text itself already screams "code". An unrecognized app with
///   nothing else to say is also omitted, preserving the old bare-prefix behavior.
/// - **Declaratives, not instructions.** A base model has no instruction channel; like the persona
///   and style lines around it, the section describes the document ("An email being written in
///   Mail.") rather than commanding the model.
nonisolated enum SurfaceContextComposer {
    /// Window titles are capped hard: they exist to carry the subject/document/channel cue, and a
    /// runaway title would crowd the budgeted preface.
    private static let maxTitleLength = 80
    private static let maxPlaceholderLength = 60

    static func compose(
        surfaceClass: AppSurfaceClass,
        applicationName: String,
        windowTitle: String?,
        focusedURLString: String?,
        fieldPlaceholder: String?
    ) -> SurfaceContext? {
        switch surfaceClass {
        case .codeEditor, .terminal:
            return nil
        case .email, .chat, .browser, .other:
            break
        }

        let cleanedApplicationName = collapseWhitespace(applicationName)
        guard !cleanedApplicationName.isEmpty else { return nil }
        let title = sanitizedTitle(windowTitle, applicationName: cleanedApplicationName)
        let placeholder = sanitizedPlaceholder(fieldPlaceholder)
        let domain = registrableDomain(from: focusedURLString)

        // A generic app with no title, domain, or placeholder has nothing useful to say; keep the
        // prompt bare like before rather than stating an app name of unknown signal.
        if surfaceClass == .other, title == nil, domain == nil, placeholder == nil {
            return nil
        }

        return SurfaceContext(
            surfaceClass: surfaceClass,
            applicationName: cleanedApplicationName,
            windowTitle: title,
            domain: domain,
            fieldPlaceholder: placeholder
        )
    }

    /// The conditioning sentences for the base-model preface, ready to join into one section.
    static func prefaceLines(for surface: SurfaceContext) -> [String] {
        var lines: [String] = []
        switch surface.surfaceClass {
        case .email:
            lines.append("An email being written in \(surface.applicationName).")
        case .chat:
            lines.append("A chat message being typed in \(surface.applicationName).")
        case .browser:
            if let domain = surface.domain {
                lines.append("Text being typed on \(domain) in \(surface.applicationName).")
            } else {
                lines.append("Text being typed in \(surface.applicationName).")
            }
        case .other:
            lines.append("Text being typed in \(surface.applicationName).")
        case .codeEditor, .terminal:
            // compose() never produces these; returning nothing keeps the invariant obvious here.
            return []
        }
        if let title = surface.windowTitle {
            lines.append("The window is titled \"\(title)\".")
        }
        if let placeholder = surface.fieldPlaceholder {
            lines.append("The text field is labeled \"\(placeholder)\".")
        }
        return lines
    }

    // MARK: - Sanitization

    /// Strips the app-name suffix browsers and many apps append (`Inbox - Google Chrome`,
    /// `Notes — Pages`), collapses whitespace, drops control characters and quotes (they would
    /// corrupt the quoted prompt line), and caps the length.
    static func sanitizedTitle(_ rawTitle: String?, applicationName: String) -> String? {
        guard var title = nonEmptyCleaned(rawTitle) else { return nil }
        for separator in [" - ", " — ", " – "] {
            let suffix = separator + applicationName
            // Anchored backwards range search instead of fold-then-count: characters that expand
            // under case folding would make a lowercased `hasSuffix` length disagree with the
            // original title's character count and clip the wrong amount.
            if let range = title.range(
                of: suffix,
                options: [.caseInsensitive, .anchored, .backwards]
            ) {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maxTitleLength))
    }

    private static func sanitizedPlaceholder(_ rawPlaceholder: String?) -> String? {
        guard let placeholder = nonEmptyCleaned(rawPlaceholder) else { return nil }
        return String(placeholder.prefix(maxPlaceholderLength))
    }

    /// The registrable host of the page URL with a leading `www.` dropped: enough to say which
    /// site the user is on without leaking the path or query, which can carry identifiers.
    static func registrableDomain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty,
              let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty
        else { return nil }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmptyCleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = collapseWhitespace(
            String(text.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar) && scalar != "\""
            })
        )
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
