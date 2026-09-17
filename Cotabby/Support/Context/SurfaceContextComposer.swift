import Foundation

/// Immutable writing-surface facts carried by a suggestion request: the app class/name plus the
/// sanitized title, URL host, and field placeholder. Keeping facts separate from their rendered
/// labels lets the base-model and Foundation Models renderers use their own prompt formats.
nonisolated struct SurfaceContext: Equatable, Sendable {
    let surfaceClass: AppSurfaceClass
    let applicationName: String
    let windowTitle: String?
    let domain: String?
    let fieldPlaceholder: String?
}

/// Converts focus-capture metadata into bounded surface facts for `SuggestionRequestFactory`,
/// then renders compact labels for `BaseCompletionPromptRenderer`. This deterministic boundary
/// owns sanitization and formatting, with no service lifetime, model access, or mutable state.
///
/// Two invariants matter here:
///
/// - **Omission beats noise.** Code editors and terminals get NO surface section at all: app
///   metadata biases a small base model toward code/numbers over prose, which is exactly wrong in
///   the one class of app where the text itself already screams "code". An unrecognized app with
///   nothing else to say is also omitted, preserving the old bare-prefix behavior.
/// - **Compact document facts.** Labels such as `Format: email; App: Mail` keep situational cues
///   together without turning them into another prose passage. The base renderer budgets this
///   optional section independently and leaves the writer's exact caret prefix last.
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

    /// Renders one optional preface line in stable order: format, app, browser host, title, and field.
    /// A compact representation reduces prose about the UI for the model to imitate. The renderer
    /// still owns the section's final budget and its separation from the writer's actual draft.
    static func prefaceLines(for surface: SurfaceContext) -> [String] {
        let format: String
        switch surface.surfaceClass {
        case .email: format = "email"
        case .chat: format = "chat"
        case .browser: format = "web text"
        case .other: format = "text"
        case .codeEditor, .terminal: return []
        }
        var fields = ["Format: \(format)", "App: \(surface.applicationName)"]
        // Preserve the base preface's existing input scope: only browsers contribute a domain.
        if surface.surfaceClass == .browser, let domain = surface.domain { fields.append("Domain: \(domain)") }
        if let title = surface.windowTitle { fields.append("Title: \(title)") }
        if let placeholder = surface.fieldPlaceholder { fields.append("Field: \(placeholder)") }
        return [fields.joined(separator: "; ") + "."]
    }

    // MARK: - Sanitization

    /// Strips the app-name suffix browsers and many apps append (`Inbox - Google Chrome`,
    /// `Notes — Pages`), collapses whitespace, and caps the length. Existing quote/control cleanup
    /// is retained so compact labels receive the same sanitized facts as the other renderers.
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

    /// The page URL's host with a leading `www.` dropped. Subdomains remain useful site cues;
    /// paths and queries stay out of the prompt because they can carry identifiers. The method
    /// name is historical: this extracts a host, not a public-suffix-based registrable domain.
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
