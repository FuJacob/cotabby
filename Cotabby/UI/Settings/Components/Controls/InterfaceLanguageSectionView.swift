import SwiftUI

/// The General pane's interface-language controls. It observes the environment-owned model, so
/// opening and closing Settings never creates a second preference owner; the injected restart
/// action stays at the app boundary where AppKit process lifetime is managed.
struct InterfaceLanguageSectionView: View {
    @ObservedObject var languageSettings: InterfaceLanguageSettingsModel
    let onRestart: () throws -> Void

    @State private var restartErrorMessage: String?

    var body: some View {
        Section("Interface") {
            Picker(selection: selectionBinding) {
                if case let .preservedUnsupported(code) = languageSettings.selection {
                    Text(String(localized: "Existing app language: \(code)"))
                        .tag(InterfaceLanguageSelection.preservedUnsupported(code))
                }
                Text("Follow System")
                    .tag(InterfaceLanguageSelection.followSystem)
                ForEach(InterfaceLanguage.allCases) { language in
                    Text(language.nativeName)
                        .tag(InterfaceLanguageSelection.language(language))
                }
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Interface Language"),
                    description: String(localized: "Choose the language used in Cotabby's interface. Changes apply after restarting."),
                    systemImage: "globe"
                )
            }
            .pickerStyle(.menu)
            .settingsItem(.interfaceLanguage)

            if languageSettings.restartRequired {
                LabeledContent {
                    Button("Restart Now") {
                        do {
                            try onRestart()
                            restartErrorMessage = nil
                        } catch {
                            restartErrorMessage = String(
                                localized: "Cotabby could not restart. Quit and reopen it to apply the selected language."
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                } label: {
                    SettingsRowLabel(
                        title: String(localized: "Restart Required"),
                        description: String(localized: "Restart Cotabby to apply the selected interface language."),
                        systemImage: "arrow.clockwise"
                    )
                }

                if let restartErrorMessage {
                    Text(restartErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: languageSettings.restartRequired) { _, restartRequired in
            if !restartRequired {
                restartErrorMessage = nil
            }
        }
    }

    private var selectionBinding: Binding<InterfaceLanguageSelection> {
        Binding(
            get: { languageSettings.selection },
            set: { languageSettings.select($0) }
        )
    }
}
