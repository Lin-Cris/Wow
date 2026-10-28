import Foundation

enum WowScreen: Hashable {
    case home
    case section(WowSection)
    case recentlyDeleted
    case pictureRemarker
    case teleprompterEditor
    case teleprompterPresenter
    case counter
}

enum WowContextEntity: Hashable {
    case item(section: WowSection, id: String)
    case teleprompterDraft(UUID)
}

struct WowAppContextSnapshot: Equatable {
    let screen: WowScreen
    let focusedEntity: WowContextEntity?
}

struct WowAgentContext: Sendable {
    let screen: String
    let focusedEntity: String?
}

@MainActor
final class WowAppContext: ObservableObject {
    @Published private(set) var snapshot = WowAppContextSnapshot(screen: .home, focusedEntity: nil)

    func report(screen: WowScreen, focusedEntity: WowContextEntity? = nil) {
        snapshot = WowAppContextSnapshot(screen: screen, focusedEntity: focusedEntity)
    }

    var agentContext: WowAgentContext {
        WowAgentContext(
            screen: String(describing: snapshot.screen),
            focusedEntity: snapshot.focusedEntity.map(String.init(describing:))
        )
    }
}
