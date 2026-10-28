// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CounterTool",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CounterTool", type: .static, targets: ["CounterTool"])
    ],
    targets: [
        .target(
            name: "CounterTool",
            path: "CounterApp",
            exclude: [
                "Assets.xcassets",
                "CompanionLoopSilent.mp4",
                "CounterApp-Info.plist",
                "CounterApp.entitlements",
                "CounterShare-Info.plist",
                "CounterShare.entitlements",
                "CounterWidget-Info.plist",
                "CounterWidget.entitlements",
                "ActivityWidget.swift",
                "ShareExtension.swift"
            ],
            sources: [
                "AccountsView.swift",
                "AppIntents.swift",
                "AppModel.swift",
                "AppStyle.swift",
                "CaptureService.swift",
                "CounterApp.swift",
                "CounterToolEntryView.swift",
                "DraftsView.swift",
                "EntryEditorView.swift",
                "HomeView.swift",
                "ImportExport.swift",
                "LiveActivity.swift",
                "LocalStore.swift",
                "Models.swift",
                "ReminderNotifications.swift",
                "MonthlyBillView.swift",
                "SettingsView.swift",
                "ShareManifest.swift"
            ],
            swiftSettings: [.define("COUNTER_TOOL_MODULE")],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("AppIntents")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
