import SwiftUI

@main
struct PictureMarkerApp: App {
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .defaultValue
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .environment(\.locale, language.locale)
            .tint(AppTheme.accent)
        }
    }
}
