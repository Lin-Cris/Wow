import SwiftUI

#if !COUNTER_TOOL_MODULE
@main
struct CounterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            CounterRootView(model: model)
                .task {
                    await model.refresh()
                    await model.reviewInbox()
                    await model.resumeRecoverableDrafts()
                    model.consumeIntent()
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
    }
}
#endif

struct CounterRootView: View {
    @Bindable var model: AppModel
    var onExit: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $model.path) {
            HomeView(model: model)
                .navigationBarHidden(true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let onExit {
                        HStack {
                            Button(action: onExit) {
                                Label("Wow", systemImage: "chevron.left")
                                    .frame(minHeight: 44)
                            }
                            .accessibilityLabel("返回 Wow 首页")
                            .accessibilityIdentifier("wowHomeButton")
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .background(CounterPalette.canvas)
                    }
                }
                .navigationDestination(for: CounterRoute.self) { route in
                    switch route {
                    case .monthBill(let date): MonthlyBillView(model: model, month: date)
                    case .category(let date, let id): CategoryDetailView(model: model, month: date, categoryID: id)
                    case .categorySettings: SettingsView(model: model, focusCategories: true)
                    case .settings: SettingsView(model: model)
                    case .accounts: AccountsView(model: model)
                    case .drafts: DraftsView(model: model)
                    case .draft(let id): DraftsView(model: model, initialDraftID: id)
                    }
                }
        }
        .tint(CounterPalette.ink)
        .sheet(item: $model.editorRoute, onDismiss: { model.consumeIntent() }) { route in
            EntryEditorView(model: model, route: route)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast)
                    if let deleted = model.recentlyDeleted {
                        Button("撤销") { Task { await model.undo(deleted); model.toast = nil } }
                            .fontWeight(.bold)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(CounterPalette.ink.opacity(0.86), in: Capsule())
                .padding(.top, 7)
                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    if reduceMotion {
                        model.toast = nil
                        model.recentlyDeleted = nil
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) {
                            model.toast = nil
                            model.recentlyDeleted = nil
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: model.toast)
    }
}
