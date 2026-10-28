import SwiftUI

@MainActor
final class WowRouter: ObservableObject {
    @Published var path: [WowRoute] = []
    @Published var presentedModule: WowModule?
    @Published var editor: WowEditorSelection?
    @Published var folderImporterPresented = false
    @Published var selectedTeleprompterDraftID: UUID?
    @Published var selectedCounterURL: URL?

    func openSection(_ section: WowSection) {
        path.append(.section(section))
    }

    func openDeleted() {
        path.append(.deleted)
    }

    func openModule(_ module: WowModule, draftID: UUID? = nil, counterURL: URL? = nil) {
        selectedTeleprompterDraftID = module == .teleprompter ? draftID : nil
        selectedCounterURL = module == .counter ? counterURL : nil
        presentedModule = module
    }

    func openEditor(section: WowSection, item: WowItem?) {
        editor = WowEditorSelection(section: section, item: item)
    }

    func closeModule() {
        presentedModule = nil
        selectedCounterURL = nil
    }
}
