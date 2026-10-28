import SwiftUI

@MainActor
public struct CounterToolEntryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    private let onExit: () -> Void
    private let initialURL: URL?

    public init(initialURL: URL? = nil, onExit: @escaping () -> Void) {
        self.initialURL = initialURL
        self.onExit = onExit
    }

    public var body: some View {
        CounterRootView(model: model, onExit: onExit)
            .task {
#if !COUNTER_TOOL_MODULE
                _ = CounterShortcuts.appShortcuts
#endif
                await model.refresh()
                await model.reviewInbox()
                await model.resumeRecoverableDrafts()
                model.consumeIntent()
                if let initialURL { model.handle(initialURL) }
            }
            .onOpenURL { model.handle($0) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await model.reviewInbox()
                    await model.resumeRecoverableDrafts()
                    await model.refresh()
                    model.consumeIntent()
                }
            }
    }

    public static var hasPendingActivation: Bool {
        guard let defaults = UserDefaults(suiteName: CaptureService.appGroup) else { return false }
        let hasIntent = CounterIntentQueue.hasPending(in: defaults)
            || defaults.string(forKey: "counter.pending.intent") == "compose"
        let hasSharedItems = CaptureService.sharedInbox.map { inbox in
            (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil))?
                .contains(where: { $0.pathExtension == "json" }) == true
        } ?? false
        return hasIntent || hasSharedItems
    }
}
