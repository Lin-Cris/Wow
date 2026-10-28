# Wow
Native iOS app using Swift, UIKit and SwiftUI; deployment target iOS 18. Read the existing implementation before editing. Keep changes small and preserve established UI/UX, business behavior and user data. Never delete user data or change signing, entitlements or bundle identifiers unless explicitly requested.

## Source and verification
- `CheckBot 首页/ios/CheckBot/`: app entry, home, persistence and Plan integration.
- `picture-remarker(mainIOS) copy/`: picture editor sources.
- `提词器 copy/`: teleprompter sources. Preserve these relative paths.
- `Counter copy/`: local Counter Swift package plus widget/share sources.
- Open `Wow.xcworkspace`, scheme `Wow`, with Xcode on Mac.
- Simulator build: `xcodebuild -workspace Wow.xcworkspace -scheme Wow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- XCTest: run `CheckBotTests` and task-relevant `WowNavigationTests` with an available iPhone simulator; select its real UDID.
- Minimum check for development/documentation changes: `python3 scripts/cloud-check.py`. For Swift/app changes, also build and run relevant tests on Mac when available. Cloud must explicitly report Mac/Xcode checks it cannot run.
- No npm application install is needed. Cloud needs Python 3, Git and Node 22+ for the existing converter tests in WowBeta. UIKit, SwiftUI, AppIntents, CoreData/Photos and signing require Apple SDKs. The Developer Tools CLI currently uses `xcrun` and needs Mac.

## Finish one meaningful coding task
A task is complete when it can be independently described and the code is reasonably complete; do not commit each tiny edit.
1. Inspect `git status` and changes. Never include credentials, generated files or unrelated user work in the task commit.
2. Run the smallest appropriate checks above.
3. Commit only the completed task locally with a short message describing the actual change; do not auto-stash unrelated user edits.
4. This project is maintained locally. Do not fetch, push, publish, or configure remote synchronization unless the user explicitly requests it.
Preserve local Git history and unrelated user changes. Never hard reset, delete unknown files, or select one side blindly when resolving conflicts. Do not place tokens in the repository.
