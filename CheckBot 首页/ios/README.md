# Wow for iOS

## Open and run

Open `CheckBot.xcodeproj`, select the **Wow** scheme and an iPhone Simulator or a physical iPhone, then Build/Run. The minimum deployment target is iOS 18.

The installed app is fully native UIKit/SwiftUI. The homepage is `CheckBot/WowHomeView.swift`; there is no Web UI, local Web bundle, localhost server, or WebKit bridge in the app target.

The selected Plan folder is accessed through a security-scoped bookmark. No iCloud container entitlement is required. After the user grants folder access, Wow reads existing Markdown notes and can update their task checkboxes; if there is no note for today, it reports that no today note was found and does not create a file.

## Architecture

- `CheckBot/AppDelegate.swift`: creates the native SwiftUI root view.
- `CheckBot/WowHomeView.swift` and the `WowHome*.swift` files: compose the homepage and detail/editor/archive flows.
- `CheckBot/WowTimeOfDayLighting.swift`: calculates the ambient light state and renders smooth minute-cadence transitions.
- `CheckBot/PlanFolderStore.swift`: persists the selected folder bookmark, finds dated Markdown notes in nested folders, and safely toggles the original task checkbox without creating a daily-note template.
- `CheckBot/WowPlanService.swift`: provides the native async plan read/toggle service and parses the fixed Markdown table (`checkbox`, `时间`, `内容`, `地点`). Older dated/checklist formats remain readable for compatibility.
- `CheckBot/WowModules.swift`: presents the native Picture Remarker and Teleprompter module roots.

## Verification

Install Wow in the desired Simulator, then prepare only its isolated test folder:

```text
node scripts/prepare-ios-picker-test.mjs SIMULATOR_UDID
xcodebuild -project CheckBot.xcodeproj -scheme Wow \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO test
```

The helper creates synthetic data inside the Simulator App container. It never reads or writes the real Obsidian vault.
