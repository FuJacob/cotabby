import XCTest
@testable import Cotabby

final class PerAppSettingsResolverTests: XCTestCase {
    private let teams = "com.microsoft.teams2"

    private func settings(_ behavior: PerAppBehavior? = nil, extendedContext: String = "", autocorrectOn: Bool = true)
        -> SuggestionSettingsSnapshot {
        CotabbyTestFixtures.settingsSnapshot(
            extendedContext: extendedContext,
            suppressCompletionsOnTypo: autocorrectOn,
            offerTypoCorrections: autocorrectOn,
            automaticallyFixTypos: true,
            perAppBehaviors: behavior.map { [teams: $0] } ?? [:]
        )
    }

    func test_midLineDefaultsOnAndFollowsTheAppChoice() {
        XCTAssertTrue(PerAppSettingsResolver.allowsMidLineCompletions(bundleIdentifier: teams, settings: settings()))
        XCTAssertFalse(PerAppSettingsResolver.allowsMidLineCompletions(
            bundleIdentifier: teams, settings: settings(PerAppBehavior(midLineCompletions: .off))
        ))
        XCTAssertTrue(PerAppSettingsResolver.allowsMidLineCompletions(
            bundleIdentifier: "com.apple.mail", settings: settings(PerAppBehavior(midLineCompletions: .off))
        ), "Another app keeps the default")
    }

    func test_autocorrectOffDisablesTheWholeTypoGate() {
        let typo = PerAppSettingsResolver.typoSettings(
            bundleIdentifier: teams, settings: settings(PerAppBehavior(autocorrect: .off))
        )
        XCTAssertFalse(typo.suppressCompletionsOnTypo)
        XCTAssertFalse(typo.offerTypoCorrections)
        XCTAssertFalse(typo.automaticallyFixTypos)
    }

    func test_autocorrectOnEnablesHidingAndOfferingButKeepsGlobalAutoFix() {
        let snapshot = CotabbyTestFixtures.settingsSnapshot(
            suppressCompletionsOnTypo: false, offerTypoCorrections: false, automaticallyFixTypos: false,
            perAppBehaviors: [teams: PerAppBehavior(autocorrect: .on)]
        )
        let typo = PerAppSettingsResolver.typoSettings(bundleIdentifier: teams, settings: snapshot)
        XCTAssertTrue(typo.suppressCompletionsOnTypo)
        XCTAssertTrue(typo.offerTypoCorrections)
        XCTAssertFalse(typo.automaticallyFixTypos)
    }

    func test_defaultAutocorrectUsesTheGlobals() {
        let typo = PerAppSettingsResolver.typoSettings(bundleIdentifier: teams, settings: settings(autocorrectOn: false))
        XCTAssertFalse(typo.suppressCompletionsOnTypo)
        XCTAssertTrue(typo.automaticallyFixTypos)
    }

    func test_appInstructionsJoinGlobalExtendedContext() {
        let snapshot = settings(PerAppBehavior(instructions: "  Reply informally.  "), extendedContext: "I work at Imperum.")

        XCTAssertEqual(
            PerAppSettingsResolver.extendedContext(bundleIdentifier: teams, settings: snapshot),
            "I work at Imperum.\nReply informally."
        )
        XCTAssertEqual(PerAppSettingsResolver.extendedContext(bundleIdentifier: "x", settings: snapshot), "I work at Imperum.")
        XCTAssertNil(PerAppSettingsResolver.extendedContext(bundleIdentifier: "x", settings: settings()))
    }

    func test_requestFactoryUsesTheAppsInstructions() {
        let context = CotabbyTestFixtures.focusedInputContext(bundleIdentifier: teams, precedingText: "Hi team")
        let request = SuggestionRequestFactory.buildRequest(
            context: context, settings: settings(PerAppBehavior(instructions: "Reply informally.")), configuration: .standard
        ).request

        XCTAssertEqual(request.extendedContext, "Reply informally.")
    }

    func test_midLineOffBlocksOnlyWhenTextFollowsOnTheSameLine() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(
            for: "Hello ", trailingText: "world", allowsMidLine: false
        ))
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(
            for: "Hello ", trailingText: "   \nnext line", allowsMidLine: false
        ))
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(
            for: "Hello ", trailingText: "world", allowsMidLine: true
        ))
    }
}

final class AppSettingsListTests: XCTestCase {
    func test_listMergesEveryOwnerAndSortsByUse() {
        let entries = AppSettingsList.entries(
            inputCounts: ["net.whatsapp.WhatsApp": 869, "com.googlecode.iterm2": 997, "unknown": 3],
            disabledRules: [DisabledApplicationRule(bundleIdentifier: "com.1password", displayName: "1Password")],
            overrides: [PerAppShortcutOverride(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal",
                                               behavior: PerAppBehavior(midLineCompletions: .off))],
            excludedFromHistory: ["com.apple.Notes"],
            displayName: { $0 == "com.googlecode.iterm2" ? "iTerm" : $0 }
        )

        XCTAssertEqual(entries.map(\.bundleIdentifier).prefix(2), ["com.googlecode.iterm2", "net.whatsapp.WhatsApp"])
        XCTAssertEqual(entries.first?.displayName, "iTerm")
        XCTAssertFalse(entries.contains { $0.bundleIdentifier == "unknown" })
        XCTAssertEqual(entries.first { $0.bundleIdentifier == "com.1password" }?.isDisabled, true)
        XCTAssertEqual(entries.first { $0.bundleIdentifier == "com.apple.Terminal" }?.hasOverrides, true)
        XCTAssertEqual(entries.first { $0.bundleIdentifier == "com.apple.Notes" }?.isExcludedFromHistory, true)
        XCTAssertEqual(entries.count, 5)
    }

    func test_searchMatchesNameOrBundleIdentifier() {
        let entries = AppSettingsList.entries(
            inputCounts: ["com.microsoft.teams2": 249, "com.apple.mail": 94],
            disabledRules: [], overrides: [], excludedFromHistory: [],
            displayName: { $0 == "com.microsoft.teams2" ? "Microsoft Teams" : "Mail" }
        )

        XCTAssertEqual(AppSettingsList.filter(entries, query: "teams").map(\.displayName), ["Microsoft Teams"])
        XCTAssertEqual(AppSettingsList.filter(entries, query: "com.apple").map(\.displayName), ["Mail"])
        XCTAssertEqual(AppSettingsList.filter(entries, query: "  ").count, 2)
    }
}
