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
    case useScreenContext
    case openAtLogin
    case includeClipboardContext
    case includeAppContext
    case allowMultiLine
    case suggestWithinWords
    case predictAheadWhileTyping
    case showFollowingWords
    case inlineMacros
    case onboarding
    case interfaceLanguage
    case resetAllSettings
    #if DEBUG
    case developmentDebugOverlays
    #endif
    // Appearance
    case suggestionDisplay
    case streamWhileGenerating
    case fadeInSuggestions
    case showFieldIndicator
    case showWordCount
    case showMenuBarIcon
    case showKeyHint
    case ghostTextColor
    case ghostTextOpacity
    case ghostTextSize
    case ghostTextSizeFloor
    case ghostTextSizeCeiling
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
    case typingHistory
    case contextLivePreview
    // Engine & Model
    case engine
    case appleIntelligenceAvailability
    case appleLanguageFallback
    case keepFallbackModelLoaded
    case appleLanguageFallbackModel
    case modelStatus
    case selectedModel
    case lowPowerModeAutoDisable
    case powerBasedModelSwitching
    case batteryModel
    case pluggedInModel
    case downloadModels
    case huggingFaceBrowser
    case modelsFolder
    case lmStudio
    case endpointBaseURL
    case endpointAPIMode
    case endpointAPIKey
    case endpointStatus
    case endpointModel
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

    /// Display copy is localized at its literal source; rawValue remains the stable navigation ID.
    /// Search uses these same localized titles and summaries, while English synonyms remain aliases.
    var title: String {
        switch self {
        case .enableGlobally: return String(localized: "Enable Globally")
        case .useScreenContext: return String(localized: "Use screen context")
        case .openAtLogin: return String(localized: "Open at Login")
        case .includeClipboardContext: return String(localized: "Include Clipboard Context")
        case .includeAppContext: return String(localized: "Include App Context")
        case .allowMultiLine: return String(localized: "Allow Multi-line Suggestions")
        case .predictAheadWhileTyping: return String(localized: "Predict Ahead While Typing")
        case .suggestWithinWords: return String(localized: "Suggest while typing a word")
        case .showFollowingWords: return String(localized: "Show following words")
        case .acceptPunctuation: return String(localized: "Accept Punctuation With Word")
        case .addSpaceAfterAccept: return String(localized: "Add Space After Accepting")
        case .inlineMacros: return String(localized: "Inline Macros")
        case .onboarding: return String(localized: "Onboarding")
        case .interfaceLanguage: return String(localized: "Interface Language")
        case .resetAllSettings: return String(localized: "Reset All Settings")
        #if DEBUG
        case .developmentDebugOverlays: return String(localized: "Show Development Debug Overlays")
        #endif
        case .suggestionDisplay: return String(localized: "Suggestion Display")
        case .streamWhileGenerating: return String(localized: "Stream Suggestions While Generating")
        case .fadeInSuggestions: return String(localized: "Fade In Suggestions")
        case .showFieldIndicator: return String(localized: "Show Field Indicator")
        case .showWordCount: return String(localized: "Show Word Count in Menu Bar")
        case .showMenuBarIcon: return String(localized: "Show Cotabby in Menu Bar")
        case .showKeyHint: return String(localized: "Show Accept-Key Hint")
        case .ghostTextColor: return String(localized: "Ghost Text Color")
        case .ghostTextOpacity: return String(localized: "Ghost Text Opacity")
        case .ghostTextSize: return String(localized: "Ghost Text Size")
        case .ghostTextSizeFloor: return String(localized: "Smallest Ghost Text")
        case .ghostTextSizeCeiling: return String(localized: "Largest Ghost Text")
        case .emojiPicker: return String(localized: "Inline Emoji Picker")
        case .emojiSkinTone: return String(localized: "Skin Tone")
        case .emojiPeopleStyle: return String(localized: "People Emoji Style")
        case .emojiHistory: return String(localized: "Emoji History")
        case .length: return String(localized: "Length")
        case .name: return String(localized: "Name")
        case .languages: return String(localized: "Languages")
        case .customRules: return String(localized: "Custom Rules")
        case .hideSuggestionsOnTypo: return String(localized: "Hide Suggestions on Typo")
        case .offerTypoCorrections: return String(localized: "Offer Corrections on Typo")
        case .spellingDictionaries: return String(localized: "Spelling Dictionaries")
        case .automaticallyFixTypos: return String(localized: "Automatically Fix Typos")
        case .extendedContext: return String(localized: "Extended Context")
        case .typingHistory: return String(localized: "Typing History")
        case .contextLivePreview: return String(localized: "Live Preview")
        case .engine: return String(localized: "Engine")
        case .appleIntelligenceAvailability: return String(localized: "Apple Intelligence Availability")
        case .appleLanguageFallback: return String(localized: "Fall Back to Open Source Model")
        case .keepFallbackModelLoaded: return String(localized: "Keep Fallback Model Loaded")
        case .appleLanguageFallbackModel: return String(localized: "Fallback Model")
        case .modelStatus: return String(localized: "Model Status")
        case .selectedModel: return String(localized: "Selected Model")
        case .lowPowerModeAutoDisable: return String(localized: "Pause in Low Power Mode")
        case .powerBasedModelSwitching: return String(localized: "Switch Based on Power Source")
        case .batteryModel: return String(localized: "On Battery")
        case .pluggedInModel: return String(localized: "Plugged In")
        case .downloadModels: return String(localized: "Download Models")
        case .huggingFaceBrowser: return String(localized: "Hugging Face Model Browser")
        case .modelsFolder: return String(localized: "Models Folder")
        case .lmStudio: return String(localized: "LM Studio Models")
        case .endpointBaseURL: return String(localized: "Endpoint Server URL")
        case .endpointAPIMode: return String(localized: "Endpoint API Format")
        case .endpointAPIKey: return String(localized: "Endpoint API Key")
        case .endpointStatus: return String(localized: "Endpoint Status")
        case .endpointModel: return String(localized: "Endpoint Model")
        case .acceptanceMode: return String(localized: "Acceptance Mode")
        case .acceptWord: return String(localized: "Accept Word")
        case .acceptEntireSuggestion: return String(localized: "Accept Entire Suggestion")
        case .toggleTabby: return String(localized: "Toggle Cotabby")
        case .disabledApps: return String(localized: "Disabled Apps")
        case .suggestInIntegratedTerminals: return String(localized: "Suggest in Integrated Terminals")
        case .accessibility: return String(localized: "Accessibility")
        case .inputMonitoring: return String(localized: "Input Monitoring")
        case .screenRecording: return String(localized: "Screen Recording")
        case .performanceTracking: return String(localized: "Enable Performance Tracking")
        case .suggestionQualityStats: return String(localized: "Suggestion Quality")
        case .resourceUsage: return String(localized: "Live Resource Usage")
        case .recentRequests: return String(localized: "Recent Requests")
        case .checkForUpdates: return String(localized: "Check for Updates")
        case .support: return String(localized: "Contribute to Cotabby")
        case .githubRepository: return String(localized: "GitHub Repository")
        case .wiki: return String(localized: "Contributor Guide")
        case .acknowledgements: return String(localized: "Acknowledgements")
        case .uninstall: return String(localized: "Uninstall")
        }
    }

    var systemImage: String {
        switch self {
        case .enableGlobally: return "power"
        case .useScreenContext: return "text.viewfinder"
        case .openAtLogin: return "arrow.right.circle"
        case .includeClipboardContext: return "doc.on.clipboard"
        case .includeAppContext: return "macwindow"
        case .allowMultiLine: return "text.alignleft"
        case .predictAheadWhileTyping: return "bolt.horizontal.circle"
        case .suggestWithinWords: return "text.cursor"
        case .showFollowingWords: return "text.word.spacing"
        case .acceptPunctuation: return "textformat.abc"
        case .addSpaceAfterAccept: return "space"
        case .inlineMacros: return "slash.circle"
        case .onboarding: return "graduationcap"
        case .interfaceLanguage: return "globe"
        case .resetAllSettings: return "arrow.counterclockwise"
        #if DEBUG
        case .developmentDebugOverlays: return "ladybug"
        #endif
        case .suggestionDisplay: return "text.cursor"
        case .streamWhileGenerating: return "text.append"
        case .fadeInSuggestions: return "sparkles"
        case .showFieldIndicator: return "dot.viewfinder"
        case .showWordCount: return "number"
        case .showMenuBarIcon: return "menubar.rectangle"
        case .showKeyHint: return "keyboard"
        case .ghostTextColor: return "paintpalette"
        case .ghostTextOpacity: return "circle.lefthalf.filled"
        case .ghostTextSize: return "textformat.size"
        case .ghostTextSizeFloor: return "arrow.down.to.line"
        case .ghostTextSizeCeiling: return "arrow.up.to.line"
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
        case .typingHistory: return "clock.arrow.circlepath"
        case .contextLivePreview: return "text.cursor"
        case .engine: return "cpu"
        case .appleIntelligenceAvailability: return "apple.logo"
        case .appleLanguageFallback: return "arrow.triangle.branch"
        case .keepFallbackModelLoaded: return "memorychip"
        case .appleLanguageFallbackModel: return "shippingbox"
        case .modelStatus: return "info.circle"
        case .selectedModel: return "shippingbox"
        case .lowPowerModeAutoDisable: return "bolt.slash.circle"
        case .powerBasedModelSwitching: return "battery.100.bolt"
        case .batteryModel: return "battery.25"
        case .pluggedInModel: return "powerplug"
        case .downloadModels: return "arrow.down.circle"
        case .huggingFaceBrowser: return "magnifyingglass"
        case .modelsFolder: return "folder"
        case .lmStudio: return "square.stack.3d.up"
        case .endpointBaseURL: return "network"
        case .endpointAPIMode: return "arrow.left.arrow.right"
        case .endpointAPIKey: return "key"
        case .endpointStatus: return "info.circle"
        case .endpointModel: return "shippingbox"
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
        #if DEBUG
        case .developmentDebugOverlays: return .general
        #endif
        case .enableGlobally, .useScreenContext, .openAtLogin, .includeClipboardContext, .includeAppContext,
             .allowMultiLine, .suggestWithinWords, .predictAheadWhileTyping, .showFollowingWords,
             .inlineMacros, .onboarding, .interfaceLanguage, .resetAllSettings:
            return .general
        case .suggestionDisplay, .streamWhileGenerating, .fadeInSuggestions, .showFieldIndicator,
             .showWordCount, .showMenuBarIcon, .showKeyHint, .ghostTextColor,
             .ghostTextOpacity, .ghostTextSize, .ghostTextSizeFloor, .ghostTextSizeCeiling:
            return .appearance
        case .emojiPicker, .emojiSkinTone, .emojiPeopleStyle, .emojiHistory:
            return .emoji
        case .length, .acceptPunctuation, .addSpaceAfterAccept, .name, .languages, .customRules,
             .hideSuggestionsOnTypo, .offerTypoCorrections, .spellingDictionaries, .automaticallyFixTypos:
            return .writing
        case .extendedContext, .contextLivePreview, .typingHistory:
            return .context
        case .engine, .appleIntelligenceAvailability, .appleLanguageFallback, .keepFallbackModelLoaded,
             .appleLanguageFallbackModel, .modelStatus, .selectedModel, .lowPowerModeAutoDisable,
             .powerBasedModelSwitching, .batteryModel, .pluggedInModel,
             .downloadModels, .huggingFaceBrowser, .modelsFolder, .lmStudio,
             .endpointBaseURL, .endpointAPIMode, .endpointAPIKey, .endpointStatus, .endpointModel:
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
        case .enableGlobally: return String(localized: "Turn Cotabby on or off everywhere without quitting.")
        case .useScreenContext: return String(localized: """
        Help suggestions understand surrounding text using screenshots of the focused window.
        """)
        case .openAtLogin: return String(localized: "Start Cotabby automatically when you log in.")
        case .includeClipboardContext: return String(localized: "Let suggestions reference what you last copied.")
        case .includeAppContext: return String(localized: "Tell the model which app and window you are typing in.")
        case .allowMultiLine: return String(localized: "Allow continuations that span more than one line.")
        case .predictAheadWhileTyping: return String(localized: """
        Keep on-device predictions ready through matching typing for a faster pause.
        """)
        case .suggestWithinWords: return String(localized: "Show new suggestions inside a word, or wait for a space or punctuation.")
        case .showFollowingWords: return String(localized: """
        Preview the following phrase, or reveal one word at a time as you type or accept.
        """)
        case .acceptPunctuation: return String(localized: "Also accept trailing commas and periods with a word.")
        case .addSpaceAfterAccept: return String(localized: "Add a space when an accept finishes a word.")
        case .inlineMacros: return String(localized: "Type / for dates, math, units, currency, and randoms.")
        case .onboarding: return String(localized: "Replay the first-run setup walkthrough.")
        case .interfaceLanguage:
            return String(localized: "Choose the language used in Cotabby's interface. Changes apply after restarting.")
        case .resetAllSettings: return String(localized: "Restore every Cotabby setting to its original default.")
        #if DEBUG
        case .developmentDebugOverlays: return String(localized: "Show caret, field, focus polling, and screen-context debug panels.")
        #endif
        case .suggestionDisplay: return String(localized: "Inline ghost text, popup card, or automatic per app.")
        case .streamWhileGenerating: return String(localized: "Reveal ghost text token by token as the model writes.")
        case .fadeInSuggestions: return String(localized: "Fade new suggestions in smoothly instead of all at once.")
        case .showFieldIndicator: return String(localized: "Show a small icon when a field is ready for suggestions.")
        case .showWordCount: return String(localized: "Count accepted words next to the menu bar icon.")
        case .showMenuBarIcon: return String(localized: "Hide menu bar clutter while Cotabby keeps running.")
        case .showKeyHint: return String(localized: "Show the accept-key badge beside the ghost text.")
        case .ghostTextColor: return String(localized: "Pick the color of the inline suggestion.")
        case .ghostTextOpacity: return String(localized: "How faint the suggestion looks before you accept it.")
        case .ghostTextSize: return String(localized: "Scale suggestions if the ghost text looks too big or small.")
        case .ghostTextSizeFloor:
            return String(localized: "The smallest point size ghost text may render at.")
        case .ghostTextSizeCeiling:
            return String(localized: "The largest point size ghost text may render at.")
        case .emojiPicker: return String(localized: "Type :name to search and insert emoji inline.")
        case .emojiSkinTone: return String(localized: "Prefer a skin tone in emoji suggestions.")
        case .emojiPeopleStyle: return String(localized: "Person, man, or woman variants when available.")
        case .emojiHistory: return String(localized: "Clear recently and frequently used emoji.")
        case .length: return String(localized: "How many words Cotabby aims for per suggestion.")
        case .name: return String(localized: "What Cotabby should call you.")
        case .languages: return String(localized: "Languages suggestions should be written in.")
        case .customRules: return String(localized: "Your own style rules passed to the model.")
        case .hideSuggestionsOnTypo: return String(localized: "Pause completions while a word looks misspelled.")
        case .offerTypoCorrections: return String(localized: "Offer a green replacement for the misspelled word.")
        case .spellingDictionaries: return String(localized: "Dictionaries used to detect typos.")
        case .automaticallyFixTypos: return String(localized: "Replace a misspelled word right after you press Space.")
        case .extendedContext: return String(localized: "A glossary or notes sent with every suggestion.")
        case .typingHistory: return String(localized: "Learn from what you type, and import Cotypist history.")
        case .contextLivePreview: return String(localized: "A real field that exercises the full pipeline.")
        case .engine: return String(localized: "Apple Intelligence, bundled Open Source, or a local endpoint.")
        case .appleIntelligenceAvailability: return String(localized: "Whether this Mac can run Apple Intelligence.")
        case .appleLanguageFallback: return String(localized: "Use the local model for languages Apple Intelligence doesn't support.")
        case .keepFallbackModelLoaded: return String(localized: "Preload the fallback model so its first suggestion is fast.")
        case .appleLanguageFallbackModel: return String(localized: "Which downloaded model the language fallback uses.")
        case .modelStatus: return String(localized: "Whether the local model is loaded and ready.")
        case .selectedModel: return String(localized: "Which downloaded model generates suggestions.")
        case .lowPowerModeAutoDisable: return String(localized: "Pause suggestions while Low Power Mode is active.")
        case .powerBasedModelSwitching: return String(localized: "Use a different engine or model by power source.")
        case .batteryModel: return String(localized: "Engine and model used while on battery.")
        case .pluggedInModel: return String(localized: "Engine and model used while plugged in.")
        case .downloadModels: return String(localized: "Curated models you can download and run.")
        case .huggingFaceBrowser: return String(localized: "Search Hugging Face for GGUF models.")
        case .modelsFolder: return String(localized: "Where downloaded model files live on this Mac.")
        case .lmStudio: return String(localized: "Also load models from your LM Studio library.")
        case .endpointBaseURL: return String(localized: "The OpenAI-compatible server address; /v1 is added when omitted.")
        case .endpointAPIMode: return String(localized: "Choose Chat Completions or Text Completions for this model.")
        case .endpointAPIKey: return String(localized: "Optional bearer token stored securely in Keychain.")
        case .endpointStatus: return String(localized: "Whether Cotabby can reach the server and list its models.")
        case .endpointModel: return String(localized: "The model identifier sent to the configured endpoint.")
        case .acceptanceMode: return String(localized: "Whether the accept key takes a word or a phrase.")
        case .acceptWord: return String(localized: "The key that inserts the next word.")
        case .acceptEntireSuggestion: return String(localized: """
        The key, or the Accept Word key pressed twice, that inserts the whole suggestion.
        """)
        case .toggleTabby: return String(localized: "A global hotkey that turns Cotabby on or off.")
        case .disabledApps: return String(localized: "Apps where Cotabby never autocompletes.")
        case .suggestInIntegratedTerminals: return String(localized: "Ghost text in VS Code and Cursor terminals.")
        case .accessibility: return String(localized: "Required to read the focused field and caret.")
        case .inputMonitoring: return String(localized: "Required to see keystrokes and the accept key.")
        case .screenRecording: return String(localized: "Optional visual context from the focused window.")
        case .performanceTracking: return String(localized: "Record timing for every model request.")
        case .suggestionQualityStats: return String(localized: "Shown, accepted, and withheld counters.")
        case .resourceUsage: return String(localized: "Live CPU, memory, and GPU graphs for the app.")
        case .recentRequests: return String(localized: "Latency log of the most recent generations.")
        case .checkForUpdates: return String(localized: "See if a newer Cotabby is available.")
        case .support: return String(localized: "Report bugs, suggest features, or contribute code.")
        case .githubRepository: return String(localized: "Browse the source code and issues.")
        case .wiki: return String(localized: "Documentation and the contributor guide.")
        case .acknowledgements: return String(localized: "Third-party packages Cotabby ships with.")
        case .uninstall: return String(localized: "Remove Cotabby and its data from this Mac.")
        }
    }

    /// Extra terms a user might type that are not in the title, so search still finds the row.
    /// Lean toward generous synonyms (UI vocab, common typos, prior names, related features) so
    /// search behaves more like "find anything that mentions this" than strict label matching.
    var keywords: [String] {
        switch self {
        #if DEBUG
        case .developmentDebugOverlays:
            return ["development", "developer", "debug", "overlays", "caret", "outline", "focus", "ocr", "diagnostics"]
        #endif
        case .enableGlobally:
            return ["on", "off", "disable", "toggle", "global", "pause", "resume",
                    "active", "status", "stop", "start", "turn off", "turn on"]
        case .useScreenContext:
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
        case .predictAheadWhileTyping:
            return ["predict", "predictive", "ahead", "background", "typing", "latency", "faster", "pause",
                    "speculative", "reuse", "local", "on device", "power"]
        case .suggestWithinWords:
            return ["typing", "mid word", "midword", "unfinished", "word boundary", "space", "pause",
                    "wait", "complete word", "word ending", "autocomplete"]
        case .showFollowingWords:
            return ["following words", "next words", "phrase preview", "one word", "word at a time",
                    "preview length", "quiet", "distraction", "autocomplete"]
        case .addSpaceAfterAccept:
            return ["space", "spacebar", "trailing space", "auto space", "add space",
                    "accept", "after accept", "whitespace", "gap", "separator"]
        case .inlineMacros:
            return ["macro", "macros", "math", "convert", "currency", "date", "random",
                    "expansion", "slash", "snippet", "shortcut", "formula", "calculator"]
        case .onboarding:
            return ["welcome", "guide", "tutorial", "intro", "help", "getting started",
                    "first run", "walkthrough"]
        case .interfaceLanguage:
            return ["interface", "language", "locale", "localization", "display", "system", "restart"]
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
        case .fadeInSuggestions:
            return ["fade", "fade in", "animation", "animate", "opacity", "transition", "smooth",
                    "appear", "instant", "instantly", "motion", "ease", "reveal", "gradual",
                    "reduce motion", "effect", "fade speed", "speed", "duration", "faster", "slower",
                    "quick", "ramp"]
        case .showFieldIndicator:
            return ["indicator", "icon", "field", "ready", "dot", "marker", "badge",
                    "show", "hide"]
        case .showWordCount:
            return ["word count", "words", "menu bar", "menubar", "stats", "counter",
                    "statistics", "show count"]
        case .showMenuBarIcon:
            return ["menu bar", "menubar", "status item", "icon", "hide", "hidden",
                    "clutter", "launch", "reopen", "settings"]
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
        case .ghostTextSizeFloor:
            return ["smallest", "minimum", "floor", "limit", "min", "tiny", "too small",
                    "point size", "pt", "clamp", "size"]
        case .ghostTextSizeCeiling:
            return ["largest", "maximum", "ceiling", "cap", "limit", "max", "too big",
                    "oversized", "point size", "pt", "clamp", "size"]
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
        case .typingHistory:
            return ["history", "typing history", "personalize", "personalization", "learn", "record",
                    "cotypist", "import", "phrases", "my writing", "privacy", "delete"]
        case .contextLivePreview:
            return ["live", "preview", "test", "ghost", "try", "playground", "sandbox",
                    "demo", "try it", "test field"]
        case .engine:
            return ["engine", "apple intelligence", "open source", "llama", "backend",
                    "provider", "runtime", "foundation models", "oss", "local", "endpoint",
                    "ollama", "openai compatible", "lm studio", "vllm",
                    "on-device", "model engine"]
        case .appleLanguageFallbackModel:
            return ["fallback model", "fallback", "model", "gemma", "gguf", "local model", "choose model"]
        case .appleLanguageFallback:
            return ["fallback", "fall back", "unsupported language", "language", "macedonian",
                    "open source", "local model", "gemma", "llama"]
        case .keepFallbackModelLoaded:
            return ["keep loaded", "preload", "warm", "memory", "ram", "resident", "fallback",
                    "first suggestion", "load time"]
        case .appleIntelligenceAvailability:
            return ["apple intelligence", "availability", "available", "supported",
                    "compatibility", "status", "macos", "device support"]
        case .modelStatus:
            return ["status", "loaded", "ready", "runtime", "running", "health",
                    "model loaded", "loading"]
        case .selectedModel:
            return ["model", "gguf", "pick", "selected", "active model", "choose model",
                    "current model", "default model"]
        case .lowPowerModeAutoDisable:
            return ["low power mode", "battery saver", "pause", "power", "automatic", "auto disable"]
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
        case .endpointBaseURL:
            return ["endpoint", "url", "server", "host", "ollama", "localhost", "openai", "v1"]
        case .endpointAPIMode:
            return ["completion", "chat completion", "text completion", "api", "format",
                    "mode", "request", "openai"]
        case .endpointAPIKey:
            return ["api key", "token", "bearer", "credential", "keychain", "authentication"]
        case .endpointStatus:
            return ["connect", "connection", "server", "status", "refresh", "health", "models"]
        case .endpointModel:
            return ["model", "identifier", "ollama", "lm studio", "vllm", "endpoint"]
        case .acceptanceMode:
            return ["acceptance", "word", "phrase", "mode", "tap", "hold", "behavior",
                    "how to accept"]
        case .acceptWord:
            return ["accept", "word", "tab", "key", "shortcut", "keybind", "binding",
                    "hotkey", "accept word", "next word"]
        case .acceptEntireSuggestion:
            return ["accept all", "entire", "full", "shortcut", "complete", "all",
                    "whole", "everything", "keybind", "binding", "double tap", "double-tap",
                    "twice", "tab tab", "press twice"]
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
            return ["cpu", "memory", "ram", "gpu", "graphics", "metal", "usage", "resource", "graph",
                    "chart", "live", "load", "monitor"]
        case .recentRequests:
            return ["recent", "requests", "history", "log", "completions", "latency",
                    "clear", "list", "past"]
        case .checkForUpdates:
            return ["update", "version", "upgrade", "sparkle", "release", "new version",
                    "check updates", "auto update"]
        case .support:
            return ["support", "contribute", "bugs", "features", "feedback", "help"]
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
