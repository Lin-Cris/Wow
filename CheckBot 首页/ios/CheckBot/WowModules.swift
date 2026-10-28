import SwiftUI
import UIKit
import AppIntents
import CounterTool

struct WowCounterIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [CounterToolAppIntentsPackage.self]
    }
}

struct WowCounterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CounterQuickEntryIntent(),
            phrases: ["在 \(.applicationName) 记一笔", "用 \(.applicationName) 记账"],
            shortTitle: "记一笔",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: CounterImageDraftIntent(),
            phrases: ["用 \(.applicationName) 核对这张账单截图"],
            shortTitle: "截图待记账",
            systemImageName: "photo.badge.plus"
        )
    }
}

enum WowModule: String, Identifiable, Equatable {
    case pictureRemarker
    case teleprompter
    case counter

    var id: String { rawValue }
}

// The original screens keep their own navigation and state. Only their App
// entry points are excluded from Wow's target, which has one UIApplication.
struct WowModuleRoot: View {
    let module: WowModule
    @ObservedObject var context: WowAppContext
    @ObservedObject var router: WowRouter
    @ObservedObject var draftStore: TeleprompterDraftStore
    let returnHome: () -> Void

    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.defaultValue.rawValue

    var body: some View {
        switch module {
        case .pictureRemarker:
            NavigationStack {
                HomeView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            homeButton
                        }
                    }
            }
            .environment(\.locale, (AppLanguage(rawValue: languageRawValue) ?? .defaultValue).locale)
            .tint(AppTheme.accent)
            .onAppear { context.report(screen: .pictureRemarker) }
        case .teleprompter:
            NavigationStack {
                let draft = draftStore.draft(id: router.selectedTeleprompterDraftID)
                ScriptEditorView(
                    initialScript: draft?.body ?? "",
                    draftID: draft?.id,
                    onScriptChanged: { id, value in
                        try? draftStore.update(id: id, body: value)
                    }
                )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack {
                            homeButton
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .background(Color(uiColor: .systemBackground))
                    }
            }
            .onAppear {
                context.report(
                    screen: .teleprompterEditor,
                    focusedEntity: router.selectedTeleprompterDraftID.map(WowContextEntity.teleprompterDraft)
                )
            }
        case .counter:
            CounterToolEntryView(initialURL: router.selectedCounterURL) {
                returnHome()
            }
            .onAppear { context.report(screen: .counter) }
        }
    }

    private var homeButton: some View {
        Button(action: returnHome) {
            Label("Wow", systemImage: "chevron.left")
                .frame(minHeight: 44)
        }
        .accessibilityLabel("返回 Wow 首页")
        .accessibilityIdentifier("wowHomeButton")
    }
}
