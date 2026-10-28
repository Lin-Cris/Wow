import UIKit
import SwiftUI
import CounterTool

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var router: WowRouter?
    private var context: WowAppContext?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        finishLaunching()
        window.makeKeyAndVisible()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor [weak self] in
            await ReminderNotifications.shared.refreshStoredRepayments()
            guard CounterToolEntryView.hasPendingActivation,
                  let router = self?.router,
                  router.presentedModule == nil else { return }
            router.openModule(.counter)
        }
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.scheme == "wow-counter" else { return false }
        Task { @MainActor [weak self] in
            self?.router?.openModule(.counter, counterURL: url)
        }
        return true
    }

    @MainActor
    private func finishLaunching() {
        let persistence = WowPersistence()
        let initial = persistence.bootstrap()
        let store = WowHomeStore(
            state: initial.state,
            archived: initial.archived,
            persistence: persistence,
            planService: WowPlanService()
        )
        let router = WowRouter()
        let context = WowAppContext()
        let draftStore = TeleprompterDraftStore()
        self.router = router
        self.context = context
        let controller = UIHostingController(rootView: WowHomeView(store: store, router: router, context: context, draftStore: draftStore))
        window?.rootViewController = controller
    }
}
