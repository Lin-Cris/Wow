import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum WowRoute: Hashable {
    case section(WowSection)
    case deleted
}

struct WowHomeView: View {
    @ObservedObject var store: WowHomeStore
    @ObservedObject var router: WowRouter
    @ObservedObject var context: WowAppContext
    @ObservedObject var draftStore: TeleprompterDraftStore
    // Keep the homepage clock aligned with the ambient-light preview clock.
    // In Release this resolves to the real current date; in DEBUG it honors
    // WOW_AMBIENT_LIGHT_TIME so simulator previews show the selected checkpoint.
    @State private var now = TimeOfDayLighting.renderingDate(for: Date())
    var body: some View {
        NavigationStack(path: $router.path) {
            ZStack(alignment: .top) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                ScrollView {
                    WowDashboardView(
                        store: store,
                        now: now,
                        openSection: { section in
                            context.report(screen: .section(section))
                            router.openSection(section)
                        },
                        openDeleted: {
                            context.report(screen: .recentlyDeleted)
                            router.openDeleted()
                        },
                        openModule: { module in
                            switch module {
                            case .pictureRemarker: context.report(screen: .pictureRemarker)
                            case .teleprompter: context.report(screen: .teleprompterEditor)
                            case .counter: context.report(screen: .counter)
                            }
                            router.openModule(module)
                        },
                        connectPlanFolder: { router.folderImporterPresented = true }
                    )
                    .frame(maxWidth: 430)
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await store.refresh()
                }

                AmbientLightLayer()
                    .frame(height: 360)
                    .ignoresSafeArea(edges: .top)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: WowRoute.self) { route in
                switch route {
                case .section(let section):
                        WowDetailView(store: store, section: section) { item in
                            router.openEditor(section: section, item: item)
                        }
                        .onAppear { context.report(screen: .section(section)) }
                case .deleted:
                    WowArchiveView(store: store)
                        .onAppear { context.report(screen: .recentlyDeleted) }
                }
            }
        }
        .fullScreenCover(item: $router.presentedModule) { module in
            WowModuleRoot(module: module, context: context, router: router, draftStore: draftStore) {
                router.closeModule()
            }
        }
        .sheet(item: $router.editor) { selection in
            WowEditorSheet(store: store, selection: selection)
        }
        .fileImporter(
            isPresented: $router.folderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await store.connect(to: url) }
        }
        .task {
            await store.start()
        }
        .task {
            while !Task.isCancelled {
                let currentDate = Date()
                let delay = TimeOfDayLighting.intervalUntilNextMinute(after: currentDate)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    break
                }
                now = TimeOfDayLighting.renderingDate(for: Date())
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            now = TimeOfDayLighting.renderingDate(for: Date())
            Task { await store.refresh() }
        }
    }
}

struct WowHomeView_Previews: PreviewProvider {
    static var previews: some View {
        let router = WowRouter()
        let context = WowAppContext()
        let draftStore = TeleprompterDraftStore()
        WowHomeView(
            store: WowHomeStore(
                state: .seed,
                archived: [],
                persistence: WowPersistence(defaults: UserDefaults(suiteName: "WowPreview")!),
                planService: WowPlanService()
            ),
            router: router,
            context: context,
            draftStore: draftStore
        )
    }
}
