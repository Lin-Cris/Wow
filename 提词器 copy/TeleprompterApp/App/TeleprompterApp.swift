import SwiftUI

@main
struct TeleprompterApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScriptEditorView()
            }
        }
    }
}
