import Foundation

/// File overview:
/// A searchable index of individual settings that powers Settings search (the sidebar field and
/// the Home hero search). Each item knows its display title, the pane (`SettingsCategory`) that
/// hosts it, an SF Symbol, a one-line summary, and extra keywords so a query like "dark", "tab",
/// or "startup" lands on the right row. Relevance ordering comes from the pure
/// `SettingsSearchRanker`; this file only declares the catalog.
///
/// This is a navigational map, not the rendering source: panes still own their own rows and labels.
/// Keeping the index here means search coverage is reviewed in one place and a new setting is one
/// case away from being findable. Panes mark the matching row with `.settingsItem(_:)` so search
/// can scroll to and highlight it on arrival.
enum SettingsItem: String, CaseIterable, Identifiable {
    // General
    case enableGlobally
    case fastMode
    case openAtLogin
    case includeClipboardContext
    case includeAppContext
    case allowMultiLine
    case inlineMacros
    case onboarding
    case resetAllSettings
    // Appearance
    case suggestionDisplay
    case streamWhileGenerating
    case showFieldIndicator
    case showWordCount
    case showKeyHint
    case ghostTextColor
    case ghostTextOpacity
    case ghostTextSize
    // Emoji
    case emojiPicker
    case emojiSkinTone
    case emojiPeopleStyle
    case emojiHistory
    // Writing
    case length
    case acceptPunctuation
    case addSpaceAfterAccept
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
    case modelStatus
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
    case suggestInIntegratedTerminals
    // Permissions
    case accessibility
    case inputMonitoring
    case screenRecording
    // Performance
    case performanceTracking
    case suggestionQualityStats
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
        case .includeAppContext: return "Include App Context"
        case .allowMultiLine: return "Allow Multi-line Suggestions"
        case .acceptPunctuation: return "Accept Punctuation With Word"
        case .addSpaceAfterAccept: return "Add Space After Accepting"
        case .inlineMacros: return "Inline Macros"
        case .onboarding: return "Onboarding"
        case .resetAllSettings: return "Reset All Settings"
        case .suggestionDisplay: return "Suggestion Display"
        case .streamWhileGenerating: return "Stream Suggestions While Generating"
        case .showFieldIndicator: return "Show Field Indicator"
        case .showWordCount: return "Show Word Count in Menu Bar"
        case .showKeyHint: return "Show Accept-Key Hint"
        case .ghostTextColor: return "Ghost Text Color"
        case .ghostTextOpacity: return "Ghost Text Opacity"
        case .ghostTextSize: return "Ghost Text Size"
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
        case .modelStatus: return "Model Status"
        case .selectedModel: return "Selected Model"
        case .powerBasedModelSwitching: return "Switch Based on Power Source"
        case .batteryModel: return "On Battery"
        case .pluggedInModel: return "Plugged In"
        case .downloadModels: return "Download Models"
        case .huggingFaceBrowser: return "Hugging Face Model Browser"
        case .modelsFolder: return "Models Folder"
        case .lmStudio: return "LM Studio Models"
        case .acceptanceMode: return "Acceptance Mode"
        case .acceptWord: return "Accept Word"
        case .acceptEntireSuggestion: return "Accept Entire Suggestion"
        case .toggleTabby: return "Toggle Cotabby"
        case .disabledApps: return "Disabled Apps"
        case .suggestInIntegratedTerminals: return "Suggest in Integrated Terminals"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .performanceTracking: return "Enable Performance Tracking"
        case .suggestionQualityStats: return "Suggestion Quality"
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
        case .includeAppContext: return "macwindow"
        case .allowMultiLine: return "text.alignleft"
        case .acceptPunctuation: return "textformat.abc"
        case .addSpaceAfterAccept: return "space"
        case .inlineMacros: return "slash.circle"
        case .onboarding: return "graduationcap"
        case .resetAllSettings: return "arrow.counterclockwise"
        case .suggestionDisplay: return "text.cursor"
        case .streamWhileGenerating: return "text.append"
        case .showFieldIndicator: return "dot.viewfinder"
        case .showWordCount: return "number"
        case .showKeyHint: return "keyboard"
        case .ghostTextColor: return "paintpalette"
        case .ghostTextOpacity: return "circle.lefthalf.filled"
        case .ghostTextSize: return "textformat.size"
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
        case .modelStatus: return "info.circle"
        case .selectedModel: return "shippingbox"
        case .powerBasedModelSwitching: return "battery.100.bolt"
        case .batteryModel: return "battery.25"
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
        case .suggestInIntegratedTerminals: return "terminal"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "camera.viewfinder"
        case .performanceTracking: return "stopwatch"
        case .suggestionQualityStats: return "checkmark.seal"
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
        case .enableGlobally, .fastMode, .openAtLogin, .includeClipboardContext, .includeAppContext,
             .allowMultiLine, .inlineMacros, .onboarding, .resetAllSettings:
            return .general
        case .suggestionDisplay, .streamWhileGenerating, .showFieldIndicator, .showWordCount, .showKeyHint,
             .ghostTextColor, .ghostTextOpacity, .ghostTextSize:
            return .appearance
        case .emojiPicker, .emojiSkinTone, .emojiPeopleStyle, .emojiHistory:
            return .emoji
        case .length, .acceptPunctuation, .addSpaceAfterAccept, .name, .languages, .customRules,
             .hideSuggestionsOnTypo, .offerTypoCorrections, .spellingDictionaries, .automaticallyFixTypos:
            return .writing
        case .extendedContext, .contextLivePreview:
            return .context
        case .engine, .appleIntelligenceAvailability, .modelStatus, .selectedModel,
             .powerBasedModelSwitching, .batteryModel, .pluggedInModel,
             .downloadModels, .huggingFaceBrowser, .modelsFolder, .lmStudio:
            return .engineAndModel
        case .acceptanceMode, .acceptWord, .acceptEntireSuggestion, .toggleTabby:
            return .shortcuts
        case .disabledApps, .suggestInIntegratedTerminals:
            return .apps
        case .accessibility, .inputMonitoring, .screenRecording:
            return .permissions
        case .performanceTracking, .suggestionQualityStats, .resourceUsage, .recentRequests:
            return .performance
        case .checkForUpdates, .support, .githubRepository, .wiki,
             .acknowledgements, .uninstall:
            return .about
        }
    }

    /// One-line caption shown under the title in search results, and searched for descriptive
    /// phrasing the title doesn't carry ("looks too big", "on every keystroke").
    var summary: String {
        switch self {
        case .enableGlobally: return "Turn Cotabby on or off everywhere without quitting."
        case .fastMode: return "Skip screenshot context for faster suggestions."
        case .openAtLogin: return "Start Cotabby automatically when you log in."
        case .includeClipboardContext: return "Let suggestions reference what you last copied."
        case .includeAppContext: return "Tell the model which app and window you are typing in."
        case .allowMultiLine: return "Allow continuations that span more than one line."
        case .acceptPunctuation: return "Also accept trailing commas and periods with a word."
        case .addSpaceAfterAccept: return "Add a space when an accept finishes a word."
        case .inlineMacros: return "Type / for dates, math, units, currency, and randoms."
        case .onboarding: return "Replay the first-run setup walkthrough."
        case .resetAllSettings: return "Restore every Cotabby setting to its original default."
        case .suggestionDisplay: return "Inline ghost text, popup card, or automatic per app."
        case .streamWhileGenerating: return "Reveal ghost text token by token as the model writes."
        case .showFieldIndicator: return "Show a small icon when a field is ready for suggestions."
        case .showWordCount: return "Count accepted words next to the menu bar icon."
        case .showKeyHint: return "Show the accept-key badge beside the ghost text."
        case .ghostTextColor: return "Pick the color of the inline suggestion."
        case .ghostTextOpacity: return "How faint the suggestion looks before you accept it."
        case .ghostTextSize: return "Scale suggestions if the ghost text looks too big or small."
        case .emojiPicker: return "Type :name to search and insert emoji inline."
        case .emojiSkinTone: return "Prefer a skin tone in emoji suggestions."
        case .emojiPeopleStyle: return "Person, man, or woman variants when available."
        case .emojiHistory: return "Clear recently and frequently used emoji."
        case .length: return "How many words Cotabby aims for per suggestion."
        case .name: return "What Cotabby should call you."
        case .languages: return "Languages suggestions should be written in."
        case .customRules: return "Your own style rules passed to the model."
        case .hideSuggestionsOnTypo: return "Pause completions while a word looks misspelled."
        case .offerTypoCorrections: return "Offer a green replacement for the misspelled word."
        case .spellingDictionaries: return "Dictionaries used to detect typos."
        case .automaticallyFixTypos: return "Replace a misspelled word right after you press Space."
        case .extendedContext: return "A glossary or notes sent with every suggestion."
        case .contextLivePreview: return "A real field that exercises the full pipeline."
        case .engine: return "Apple Intelligence or an open-source local model."
        case .appleIntelligenceAvailability: return "Whether this Mac can run Apple Intelligence."
        case .modelStatus: return "Whether the local model is loaded and ready."
        case .selectedModel: return "Which downloaded model generates suggestions."
        case .powerBasedModelSwitching: return "Use a different engine or model by power source."
        case .batteryModel: return "Engine and model used while on battery."
        case .pluggedInModel: return "Engine and model used while plugged in."
        case .downloadModels: return "Curated models you can download and run."
        case .huggingFaceBrowser: return "Search Hugging Face for GGUF models."
        case .modelsFolder: return "Where downloaded model files live on this Mac."
        case .lmStudio: return "Also load models from your LM Studio library."
        case .acceptanceMode: return "Whether the accept key takes a word or a phrase."
        case .acceptWord: return "The key that inserts the next word."
        case .acceptEntireSuggestion: return "The key that inserts the whole suggestion."
        case .toggleTabby: return "A global hotkey that turns Cotabby on or off."
        case .disabledApps: return "Apps where Cotabby never autocompletes."
        case .suggestInIntegratedTerminals: return "Ghost text in VS Code and Cursor terminals."
        case .accessibility: return "Required to read the focused field and caret."
        case .inputMonitoring: return "Required to see keystrokes and the accept key."
        case .screenRecording: return "Optional visual context from the focused window."
        case .performanceTracking: return "Record timing for every model request."
        case .suggestionQualityStats: return "Shown, accepted, and withheld counters."
        case .resourceUsage: return "Live CPU and memory graphs for the app."
        case .recentRequests: return "Latency log of the most recent generations."
        case .checkForUpdates: return "See if a newer Cotabby is available."
        case .support: return "Tip the two students who build Cotabby."
        case .githubRepository: return "Browse the source code and issues."
        case .wiki: return "Documentation and the contributor guide."
        case .acknowledgements: return "Third-party packages Cotabby ships with."
        case .uninstall: return "Remove Cotabby and its data from this Mac."
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
        case .includeAppContext:
            return ["app", "window", "title", "surface", "domain", "site", "context",
                    "privacy", "metadata", "application"]
        case .allowMultiLine:
            return ["multiline", "multi-line", "line", "newline", "wrap", "paragraph",
                    "long", "multiple lines", "line break"]
        case .acceptPunctuation:
            return ["punctuation", "comma", "period", "accept", "trailing", "auto accept",
                    "auto-accept", "space"]
        case .addSpaceAfterAccept:
            return ["space", "spacebar", "trailing space", "auto space", "add space",
                    "accept", "after accept", "whitespace", "gap", "separator"]
        case .inlineMacros:
            return ["macro", "macros", "math", "convert", "currency", "date", "random",
                    "expansion", "slash", "snippet", "shortcut", "formula", "calculator"]
        case .onboarding:
            return ["welcome", "guide", "tutorial", "intro", "help", "getting started",
                    "first run", "walkthrough"]
        case .resetAllSettings:
            return ["reset", "defaults", "default", "restore", "factory reset", "factory settings",
                    "clear settings", "start over", "revert", "wipe", "erase", "restore defaults",
                    "reset everything"]
        case .suggestionDisplay:
            return ["inline", "popup", "ghost", "card", "display", "mirror", "auto",
                    "appearance", "style", "show suggestion", "rendering", "ui"]
        case .streamWhileGenerating:
            return ["stream", "streaming", "live", "typewriter", "token", "incremental",
                    "progressive", "word by word", "character by character", "reveal",
                    "while generating", "as it types", "decode", "partial", "all at once"]
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
        case .ghostTextSize:
            return ["size", "font size", "scale", "bigger", "smaller", "larger", "text size",
                    "zoom", "multiplier", "too big", "too small"]
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
        case .modelStatus:
            return ["status", "loaded", "ready", "runtime", "running", "health",
                    "model loaded", "loading"]
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
        case .suggestInIntegratedTerminals:
            return ["terminal", "terminals", "integrated terminal", "vscode", "vs code",
                    "cursor", "shell", "xterm", "command line", "cli", "console",
                    "ghost text in terminal"]
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
        case .suggestionQualityStats:
            return ["quality", "acceptance", "accepted", "shown", "suppressed", "withheld",
                    "rate", "stats", "counters", "suggestions"]
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

    /// Items matching the query, most relevant first. Empty for a blank query. Relevance and
    /// typo tolerance come from `SettingsSearchRanker`, so this stays a thin catalog accessor.
    static func results(for query: String) -> [SettingsItem] {
        SettingsSearchRanker.rank(query, in: allCases)
    }
}

/// Feeds the catalog's fields to the pure ranker without the ranker importing this UI type.
extension SettingsItem: SettingsSearchable {
    var searchTitle: String { title }
    var searchKeywords: [String] { keywords }
    var searchGroupLabel: String { category.label }
    var searchSummary: String { summary }
}
