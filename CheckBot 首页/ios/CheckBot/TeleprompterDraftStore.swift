import Foundation
import SwiftUI

struct TeleprompterDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
}

protocol TeleprompterDraftRepository: Sendable {
    func load() throws -> [TeleprompterDraft]
    func save(_ drafts: [TeleprompterDraft]) throws
}

final class FileTeleprompterDraftRepository: TeleprompterDraftRepository {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("Wow", isDirectory: true)
                .appendingPathComponent("teleprompter-drafts.json")
        }
    }

    func load() throws -> [TeleprompterDraft] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([TeleprompterDraft].self, from: data)
    }

    func save(_ drafts: [TeleprompterDraft]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class TeleprompterDraftStore: ObservableObject {
    @Published private(set) var drafts: [TeleprompterDraft]
    @Published private(set) var loadError: String?

    private let repository: any TeleprompterDraftRepository

    init(repository: any TeleprompterDraftRepository = FileTeleprompterDraftRepository()) {
        self.repository = repository
        do {
            drafts = try repository.load().sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            drafts = []
            loadError = error.localizedDescription
        }
    }

    func draft(id: UUID?) -> TeleprompterDraft? {
        guard let id else { return nil }
        return drafts.first { $0.id == id }
    }

    @discardableResult
    func create(title: String?, body: String, now: Date = Date()) throws -> TeleprompterDraft {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else {
            throw TeleprompterDraftError.emptyBody
        }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = TeleprompterDraft(
            id: UUID(),
            title: normalizedTitle?.isEmpty == false ? normalizedTitle! : "Untitled Draft",
            body: normalizedBody,
            createdAt: now,
            updatedAt: now
        )
        let next = [draft] + drafts
        try repository.save(next)
        drafts = next
        return draft
    }

    func update(id: UUID, body: String, now: Date = Date()) throws {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            throw TeleprompterDraftError.notFound
        }
        var next = drafts
        next[index].body = body
        next[index].updatedAt = now
        try repository.save(next)
        drafts = next.sorted { $0.updatedAt > $1.updatedAt }
    }
}

enum TeleprompterDraftError: LocalizedError {
    case emptyBody
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyBody: return "The generated draft is empty."
        case .notFound: return "The teleprompter draft no longer exists."
        }
    }
}
