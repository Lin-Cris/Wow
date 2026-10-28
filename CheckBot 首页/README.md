# Wow iOS App

Wow is a native iOS app built with UIKit and SwiftUI. The homepage and its data flow are fully native; the retired React/Vite Web UI is no longer bundled or loaded at launch.

## Build and run

Open `ios/CheckBot.xcodeproj`, select the **Wow** scheme and an iPhone Simulator or a signed physical iPhone, then Build/Run.

The homepage is composed by `ios/CheckBot/WowHomeView.swift` and the related `WowHome*.swift` files. The module cards present Picture Remarker and Teleprompter; the companion entry opens Counter, integrated through a local Swift Package.

## Runtime architecture

- `ios/CheckBot/AppDelegate.swift` creates the native SwiftUI homepage directly.
- `ios/CheckBot/WowHomeView.swift` owns navigation, sheets, folder importing, refresh, and the ambient-light layer.
- `ios/CheckBot/WowDashboardView.swift` renders the existing homepage cards and module entry points.
- `ios/CheckBot/WowPersistence.swift` stores native homepage state and performs current-day rollover cleanup.
- `ios/CheckBot/WowPlanService.swift` and `ios/CheckBot/PlanFolderStore.swift` read and update the selected Plan folder.
- `ios/CheckBot/WowTimeOfDayLighting.swift` calculates and renders the time-based ambient lighting with smooth minute-cadence transitions.

## Tests

For iOS tests, install the app in the desired Simulator, prepare the isolated fixture folder, then run:

```text
node scripts/prepare-ios-picker-test.mjs SIMULATOR_UDID
xcodebuild -project ios/CheckBot.xcodeproj -scheme Wow \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO test
```

The fixture is Simulator-only test data. No Obsidian vault or real iCloud folder is modified by the test helper.
