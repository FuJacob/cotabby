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
    case customRules
    case hideSuggestionsOnTypo
    case offerTypoCorrections
    case spellingDictionaries
    case automaticallyFixTypos
    // Context
    case extendedContext
    case contextLivePreview
    // Engine & Model
    case engine
    case appleIntelligenceAvailability
    case selectedModel
    case powerBasedModelSwitching
    case batteryModel
    case pluggedInModel
    case downloadModels
    case huggingFaceBrowser
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
    case recentRequests
    // About
    case checkForUpdates
    case support
    case githubRepository
    case wiki
    case acknowledgements
    case uninstall

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
        case .customRules: return "Custom Rules"
        case .hideSuggestionsOnTypo: return "Hide Suggestions on Typo"
        case .offerTypoCorrections: return "Offer Corrections on Typo"
        case .spellingDictionaries: return "Spelling Dictionaries"
        case .automaticallyFixTypos: return "Automatically Fix Typos"
        case .extendedContext: return "Extended Context"
        case .contextLivePreview: return "Live Preview"
        case .engine: return "Engine"
        case .appleIntelligenceAvailability: return "Apple Intelligence Availability"
        case .selectedModel: return "Selected Model"
        case .powerBasedModelSwitching: return "Switch Models Based on Power Source"
        case .batteryModel: return "Battery Model"
        case .pluggedInModel: return "Plugged-in Model"
        case .downloadModels: return "Download Models"
        case .huggingFaceBrowser: return "Hugging Face Model Browser"
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
        case .recentRequests: return "Recent Requests"
        case .checkForUpdates: return "Check for Updates"
        case .support: return "Support Cotabby"
        case .githubRepository: return "GitHub Repository"
        case .wiki: return "Wiki & Contributor Guide"
        case .acknowledgements: return "Acknowledgements"
        case .uninstall: return "Uninstall"
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
        case .customRules: return "list.bullet.rectangle"
        case .hideSuggestionsOnTypo: return "eye.slash"
        case .offerTypoCorrections: return "checkmark.bubble"
        case .spellingDictionaries: return "character.book.closed"
        case .automaticallyFixTypos: return "checkmark.circle"
        case .extendedContext: return "doc.text"
        case .contextLivePreview: return "text.cursor"
        case .engine: return "cpu"
        case .appleIntelligenceAvailability: return "apple.logo"
        case .selectedModel: return "shippingbox"
        case .powerBasedModelSwitching: return "battery.100"
        case .batteryModel: return "battery.50"
        case .pluggedInModel: return "powerplug"
        case .downloadModels: return "arrow.down.circle"
        case .huggingFaceBrowser: return "magnifyingglass"
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
        case .recentRequests: return "list.bullet.clipboard"
        case .checkForUpdates: return "arrow.triangle.2.circlepath"
        case .support: return "heart.fill"
        case .githubRepository: return "chevron.left.forwardslash.chevron.right"
        case .wiki: return "book"
        case .acknowledgements: return "doc.text"
        case .uninstall: return "trash"
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
        case .length, .name, .languages, .customRules,
             .hideSuggestionsOnTypo, .offerTypoCorrections, .spellingDictionaries, .automaticallyFixTypos:
            return .writing
        case .extendedContext, .contextLivePreview:
            return .context
        case .engine, .appleIntelligenceAvailability, .selectedModel,
             .powerBasedModelSwitching, .batteryModel, .pluggedInModel,
             .downloadModels, .huggingFaceBrowser, .modelsFolder, .lmStudio:
            return .engineAndModel
        case .acceptanceMode, .acceptWord, .acceptEntireSuggestion, .toggleTabby:
            return .shortcuts
        case .disabledApps:
            return .apps
        case .accessibility, .inputMonitoring, .screenRecording:
            return .permissions
        case .performanceTracking, .resourceUsage, .recentRequests:
            return .performance
        case .checkForUpdates, .support, .githubRepository, .wiki,
             .acknowledgements, .uninstall:
            return .about
        }
    }

    /// Extra terms a user might type that are not in the title, so search still finds the row.
    /// Lean toward generous synonyms (UI vocab, common typos, prior names, related features) so
    /// search behaves more like "find anything that mentions this" than strict label matching.
    var keywords: [String] {
        switch self {
        case .enableGlobally:
            return ["on", "off", "disable", "toggle", "global", "pause", "resume",
                    "active", "status", "stop", "start", "turn off", "turn on"]
        case .fastMode:
            return ["speed", "fast", "screenshot", "ocr", "context", "vision",
                    "quick", "performance", "screen", "image"]
        case .openAtLogin:
            return ["startup", "launch", "boot", "login", "start", "autostart",
                    "auto-start", "launch at login", "login items", "open at startup"]
        case .includeClipboardContext:
            return ["clipboard", "paste", "copy", "pasteboard", "context"]
        case .allowMultiLine:
            return ["multiline", "multi-line", "line", "newline", "wrap", "paragraph",
                    "long", "multiple lines", "line break"]
        case .acceptPunctuation:
            return ["punctuation", "comma", "period", "accept", "trailing", "auto accept",
                    "auto-accept", "space"]
        case .inlineMacros:
            return ["macro", "macros", "math", "convert", "currency", "date", "random",
                    "expansion", "slash", "snippet", "shortcut", "formula", "calculator"]
        case .onboarding:
            return ["welcome", "guide", "tutorial", "intro", "help", "getting started",
                    "first run", "walkthrough"]
        case .suggestionDisplay:
            return ["inline", "popup", "ghost", "card", "display", "mirror", "auto",
                    "appearance", "style", "show suggestion", "rendering", "ui"]
        case .showFieldIndicator:
            return ["indicator", "icon", "field", "ready", "dot", "marker", "badge",
                    "show", "hide"]
        case .showWordCount:
            return ["word count", "words", "menu bar", "menubar", "stats", "counter",
                    "statistics", "show count"]
        case .showKeyHint:
            return ["hint", "badge", "keycap", "accept key", "tip", "label", "key hint",
                    "show key"]
        case .ghostTextColor:
            return ["color", "ghost", "theme", "dark", "light", "tint", "appearance",
                    "highlight", "shade"]
        case .ghostTextOpacity:
            return ["opacity", "transparency", "fade", "alpha", "translucent", "dim",
                    "brightness", "visibility"]
        case .emojiPicker:
            return ["emoji", "smile", "picker", "inline", "colon", "emoticon", "face",
                    "symbol"]
        case .emojiSkinTone:
            return ["skin", "tone", "color", "skin tone", "complexion", "fitzpatrick"]
        case .emojiPeopleStyle:
            return ["gender", "person", "man", "woman", "people", "neutral", "default",
                    "people style"]
        case .emojiHistory:
            return ["history", "recent", "clear", "reset", "recents", "clear history",
                    "emoji history", "frequently used"]
        case .length:
            return ["length", "words", "short", "long", "count", "verbose", "brief",
                    "tokens", "size", "concise", "min", "max", "range", "custom"]
        case .name:
            return ["name", "persona", "profile", "you", "user", "first name",
                    "what to call", "identity"]
        case .languages:
            return ["language", "locale", "translate", "multilingual", "english", "spanish",
                    "french", "german", "japanese", "chinese", "lang", "bilingual"]
        case .customRules:
            return ["rules", "custom rules", "style", "guidelines", "constraints",
                    "instructions", "directives", "writing rules"]
        case .hideSuggestionsOnTypo:
            return ["typo", "misspell", "spelling", "hide", "suppress", "correction",
                    "error", "mistake"]
        case .offerTypoCorrections:
            return ["typo", "correct", "correction", "fix", "spelling", "autocorrect",
                    "spell check", "mistake", "rewrite"]
        case .spellingDictionaries:
            return ["dictionary", "dictionaries", "spelling", "language", "multilingual",
                    "english", "german", "spanish", "french", "hebrew", "italian",
                    "russian", "symspell", "autocorrect"]
        case .automaticallyFixTypos:
            return ["typo", "automatic", "automatically", "autocorrect", "fix", "spelling",
                    "replace", "space", "instant", "without accepting"]
        case .extendedContext:
            return ["context", "glossary", "reference", "notes", "jargon", "instructions",
                    "memory", "background", "system prompt", "vocabulary"]
        case .contextLivePreview:
            return ["live", "preview", "test", "ghost", "try", "playground", "sandbox",
                    "demo", "try it", "test field"]
        case .engine:
            return ["engine", "apple intelligence", "open source", "llama", "backend",
                    "provider", "runtime", "foundation models", "oss", "local",
                    "on-device", "model engine"]
        case .appleIntelligenceAvailability:
            return ["apple intelligence", "availability", "available", "supported",
                    "compatibility", "status", "macos", "device support"]
        case .selectedModel:
            return ["model", "gguf", "pick", "selected", "active model", "choose model",
                    "current model", "default model"]
        case .powerBasedModelSwitching:
            return ["power", "battery", "plugged", "energy", "ac", "charger",
                    "switch model", "power source", "auto switch", "adaptive",
                    "battery model", "plugged in"]
        case .batteryModel:
            return ["battery", "unplugged", "low power", "energy saver", "on battery",
                    "model", "power"]
        case .pluggedInModel:
            return ["plugged", "plugged in", "ac", "charger", "wall power", "wired",
                    "model", "power", "performance model"]
        case .downloadModels:
            return ["download", "models", "catalog", "fetch", "install model",
                    "get model", "downloadable", "library"]
        case .huggingFaceBrowser:
            return ["hugging face", "huggingface", "hf", "browse", "search models",
                    "discover", "find model", "model hub"]
        case .modelsFolder:
            return ["folder", "path", "directory", "models", "open folder", "reveal",
                    "finder", "location", "storage", "refresh"]
        case .lmStudio:
            return ["lm studio", "lmstudio", "import", "library", "external", "source",
                    "third party"]
        case .acceptanceMode:
            return ["acceptance", "word", "phrase", "mode", "tap", "hold", "behavior",
                    "how to accept"]
        case .acceptWord:
            return ["accept", "word", "tab", "key", "shortcut", "keybind", "binding",
                    "hotkey", "accept word", "next word"]
        case .acceptEntireSuggestion:
            return ["accept all", "entire", "full", "shortcut", "complete", "all",
                    "whole", "everything", "keybind", "binding"]
        case .toggleTabby:
            return ["toggle", "global", "on off", "shortcut", "hotkey", "pause",
                    "enable", "disable", "keybind", "binding", "tabby"]
        case .disabledApps:
            return ["apps", "disable", "exclude", "block", "ignore", "blacklist",
                    "deny list", "exception", "app exclusion", "skip", "off in"]
        case .accessibility:
            return ["accessibility", "ax", "permission", "access", "system settings",
                    "privacy", "grant", "allow"]
        case .inputMonitoring:
            return ["input", "monitoring", "keystrokes", "permission", "keyboard",
                    "privacy", "system settings", "grant", "allow"]
        case .screenRecording:
            return ["screen", "recording", "screenshot", "permission", "ocr", "vision",
                    "privacy", "system settings", "grant", "allow"]
        case .performanceTracking:
            return ["performance", "tracking", "latency", "metrics", "timing",
                    "telemetry", "analytics", "diagnostics", "measure"]
        case .resourceUsage:
            return ["cpu", "memory", "ram", "usage", "resource", "graph", "chart",
                    "live", "load", "monitor"]
        case .recentRequests:
            return ["recent", "requests", "history", "log", "completions", "latency",
                    "clear", "list", "past"]
        case .checkForUpdates:
            return ["update", "version", "upgrade", "sparkle", "release", "new version",
                    "check updates", "auto update"]
        case .support:
            return ["donate", "support", "ko-fi", "kofi", "tip", "donation", "sponsor",
                    "contribute money", "help"]
        case .githubRepository:
            return ["github", "repo", "repository", "source code", "code", "git",
                    "contribute", "issues", "open source"]
        case .wiki:
            return ["wiki", "docs", "documentation", "contributor", "guide", "help",
                    "manual", "readme"]
        case .acknowledgements:
            return ["licenses", "credits", "open source", "acknowledgements", "thanks",
                    "attribution", "third party", "notices"]
        case .uninstall:
            return ["uninstall", "remove", "delete", "wipe", "reset", "clean up",
                    "application support", "remove app"]
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
