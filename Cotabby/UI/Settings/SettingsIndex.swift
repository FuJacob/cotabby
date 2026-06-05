import Foundation

/// File overview:
/// A searchable index of individual settings that powers the Settings search field. Each item knows
/// its display title, the pane (`SettingsCategory`) that hosts it, an SF Symbol, and extra keywords
/// so a query like "dark", "tab", or "startup" lands on the right pane.
///
/// This is a navigational map, not the rendering source: panes still own their own rows and labels.
/// Keeping the index here means search coverage is reviewed in one place and a new setting is one
/// case away from being findable.
enum SettingsItem: String, CaseIterable, Identifiable {
    // General
    case enableGlobally
    case fastMode
    case openAtLogin
    case includeClipboardContext
    case allowMultiLine
    case acceptPunctuation
    case inlineMacros
    case onboarding
    // Appearance
    case suggestionDisplay
    case showFieldIndicator
    case showWordCount
    case showKeyHint
    case ghostTextColor
    case ghostTextOpacity
    // Emoji
    case emojiPicker
    case emojiSkinTone
    case emojiPeopleStyle
    case emojiHistory
    // Writing
    case length
    case name
    case languages
    // Context
    case extendedContext
    case contextLivePreview
    // Engine & Model
    case engine
    case selectedModel
    case modelsFolder
    case lmStudio
    // Shortcuts
    case acceptanceMode
    case acceptWord
    case acceptEntireSuggestion
    case toggleTabby
    // Apps
    case disabledApps
    // Permissions
    case accessibility
    case inputMonitoring
    case screenRecording
    // Performance
    case performanceTracking
    case resourceUsage
    // About
    case checkForUpdates
    case support
    case acknowledgements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enableGlobally: return "Enable Globally"
        case .fastMode: return "Fast Mode"
        case .openAtLogin: return "Open at Login"
        case .includeClipboardContext: return "Include Clipboard Context"
        case .allowMultiLine: return "Allow Multi-line Suggestions"
        case .acceptPunctuation: return "Accept Punctuation With Word"
        case .inlineMacros: return "Inline Macros"
        case .onboarding: return "Onboarding"
        case .suggestionDisplay: return "Suggestion Display"
        case .showFieldIndicator: return "Show Field Indicator"
        case .showWordCount: return "Show Word Count in Menu Bar"
        case .showKeyHint: return "Show Accept-Key Hint"
        case .ghostTextColor: return "Ghost Text Color"
        case .ghostTextOpacity: return "Ghost Text Opacity"
        case .emojiPicker: return "Inline Emoji Picker"
        case .emojiSkinTone: return "Skin Tone"
        case .emojiPeopleStyle: return "People Emoji Style"
        case .emojiHistory: return "Emoji History"
        case .length: return "Length"
        case .name: return "Name"
        case .languages: return "Languages"
        case .extendedContext: return "Extended Context"
        case .contextLivePreview: return "Live Preview"
        case .engine: return "Engine"
        case .selectedModel: return "Selected Model"
        case .modelsFolder: return "Models Folder"
        case .lmStudio: return "LM Studio Models"
        case .acceptanceMode: return "Acceptance Mode"
        case .acceptWord: return "Accept Word"
        case .acceptEntireSuggestion: return "Accept Entire Suggestion"
        case .toggleTabby: return "Toggle Tabby"
        case .disabledApps: return "Disabled Apps"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .performanceTracking: return "Performance Tracking"
        case .resourceUsage: return "Live Resource Usage"
        case .checkForUpdates: return "Check for Updates"
        case .support: return "Support Cotabby"
        case .acknowledgements: return "Acknowledgements"
        }
    }

    var systemImage: String {
        switch self {
        case .enableGlobally: return "power"
        case .fastMode: return "bolt.fill"
        case .openAtLogin: return "arrow.right.circle"
        case .includeClipboardContext: return "doc.on.clipboard"
        case .allowMultiLine: return "text.alignleft"
        case .acceptPunctuation: return "textformat.abc"
        case .inlineMacros: return "slash.circle"
        case .onboarding: return "graduationcap"
        case .suggestionDisplay: return "text.cursor"
        case .showFieldIndicator: return "dot.viewfinder"
        case .showWordCount: return "number"
        case .showKeyHint: return "keyboard"
        case .ghostTextColor: return "paintpalette"
        case .ghostTextOpacity: return "circle.lefthalf.filled"
        case .emojiPicker: return "face.smiling"
        case .emojiSkinTone: return "hand.raised.fingers.spread"
        case .emojiPeopleStyle: return "person.2"
        case .emojiHistory: return "clock.arrow.circlepath"
        case .length: return "ruler"
        case .name: return "person"
        case .languages: return "globe"
        case .extendedContext: return "doc.text"
        case .contextLivePreview: return "text.cursor"
        case .engine: return "cpu"
        case .selectedModel: return "shippingbox"
        case .modelsFolder: return "folder"
        case .lmStudio: return "square.stack.3d.up"
        case .acceptanceMode: return "textformat.abc"
        case .acceptWord: return "arrow.right.to.line"
        case .acceptEntireSuggestion: return "text.insert"
        case .toggleTabby: return "power.circle"
        case .disabledApps: return "nosign"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "camera.viewfinder"
        case .performanceTracking: return "stopwatch"
        case .resourceUsage: return "chart.line.uptrend.xyaxis"
        case .checkForUpdates: return "arrow.triangle.2.circlepath"
        case .support: return "heart.fill"
        case .acknowledgements: return "doc.text"
        }
    }

    var category: SettingsCategory {
        switch self {
        case .enableGlobally, .fastMode, .openAtLogin, .includeClipboardContext,
             .allowMultiLine, .acceptPunctuation, .inlineMacros, .onboarding:
            return .general
        case .suggestionDisplay, .showFieldIndicator, .showWordCount, .showKeyHint,
             .ghostTextColor, .ghostTextOpacity:
            return .appearance
        case .emojiPicker, .emojiSkinTone, .emojiPeopleStyle, .emojiHistory:
            return .emoji
        case .length, .name, .languages:
            return .writing
        case .extendedContext, .contextLivePreview:
            return .context
        case .engine, .selectedModel, .modelsFolder, .lmStudio:
            return .engineAndModel
        case .acceptanceMode, .acceptWord, .acceptEntireSuggestion, .toggleTabby:
            return .shortcuts
        case .disabledApps:
            return .apps
        case .accessibility, .inputMonitoring, .screenRecording:
            return .permissions
        case .performanceTracking, .resourceUsage:
            return .performance
        case .checkForUpdates, .support, .acknowledgements:
            return .about
        }
    }

    /// Extra terms a user might type that are not in the title, so search still finds the row.
    var keywords: [String] {
        switch self {
        case .enableGlobally: return ["on", "off", "disable", "toggle", "global", "pause"]
        case .fastMode: return ["speed", "fast", "screenshot", "ocr", "context"]
        case .openAtLogin: return ["startup", "launch", "boot", "login", "start"]
        case .includeClipboardContext: return ["clipboard", "paste", "copy"]
        case .allowMultiLine: return ["multiline", "line", "newline", "wrap"]
        case .acceptPunctuation: return ["punctuation", "comma", "period", "accept"]
        case .inlineMacros: return ["macro", "macros", "math", "convert", "currency", "date", "random", "expansion", "slash"]
        case .onboarding: return ["welcome", "guide", "tutorial", "intro"]
        case .suggestionDisplay: return ["inline", "popup", "ghost", "card", "display", "mirror"]
        case .showFieldIndicator: return ["indicator", "icon", "field", "ready"]
        case .showWordCount: return ["word count", "menu bar", "stats", "counter"]
        case .showKeyHint: return ["hint", "badge", "keycap", "accept key"]
        case .ghostTextColor: return ["color", "ghost", "theme", "dark", "light"]
        case .ghostTextOpacity: return ["opacity", "transparency", "fade", "alpha"]
        case .emojiPicker: return ["emoji", "smile", "picker", "inline", "colon"]
        case .emojiSkinTone: return ["skin", "tone", "color"]
        case .emojiPeopleStyle: return ["gender", "person", "man", "woman", "people"]
        case .emojiHistory: return ["history", "recent", "clear", "reset"]
        case .length: return ["length", "words", "short", "long", "count", "verbose"]
        case .name: return ["name", "persona", "profile", "you"]
        case .languages: return ["language", "locale", "translate", "multilingual"]
        case .extendedContext: return ["context", "glossary", "reference", "notes", "jargon"]
        case .contextLivePreview: return ["live", "preview", "test", "ghost", "try", "playground"]
        case .engine: return ["engine", "apple intelligence", "open source", "llama", "backend"]
        case .selectedModel: return ["model", "gguf", "pick", "selected"]
        case .modelsFolder: return ["folder", "path", "directory", "models"]
        case .lmStudio: return ["lm studio", "lmstudio", "import", "library"]
        case .acceptanceMode: return ["acceptance", "word", "phrase", "mode"]
        case .acceptWord: return ["accept", "word", "tab", "key", "shortcut"]
        case .acceptEntireSuggestion: return ["accept all", "entire", "full", "shortcut"]
        case .toggleTabby: return ["toggle", "global", "on off", "shortcut", "hotkey"]
        case .disabledApps: return ["apps", "disable", "exclude", "block", "ignore"]
        case .accessibility: return ["accessibility", "ax", "permission", "access"]
        case .inputMonitoring: return ["input", "monitoring", "keystrokes", "permission"]
        case .screenRecording: return ["screen", "recording", "screenshot", "permission", "ocr"]
        case .performanceTracking: return ["performance", "tracking", "latency", "metrics"]
        case .resourceUsage: return ["cpu", "memory", "ram", "usage", "resource"]
        case .checkForUpdates: return ["update", "version", "upgrade", "sparkle"]
        case .support: return ["donate", "support", "ko-fi", "kofi", "tip"]
        case .acknowledgements: return ["licenses", "credits", "open source", "acknowledgements"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        if category.label.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }

    /// Items whose title or keywords match the query, in declaration order. Empty for a blank query.
    static func results(for query: String) -> [SettingsItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return allCases.filter { $0.matches(trimmed) }
    }
}
