import Foundation

enum ObsidianURI {
    static let vaultName = "Plan"
    private static let queryValueCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(notePath: String, sourceHeading: String? = nil, sourceBlockId: String? = nil) -> URL? {
        let trimmed = notePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let note = trimmed.lowercased().hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
        let destination: String
        if let block = sourceBlockId?.trimmingCharacters(in: .whitespacesAndNewlines), block.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil {
            destination = "\(note)#^\(block)"
        } else if let heading = sourceHeading?.trimmingCharacters(in: .whitespacesAndNewlines), !heading.isEmpty {
            destination = "\(note)#\(heading)"
        } else {
            destination = note
        }
        guard !note.isEmpty,
              let vault = vaultName.addingPercentEncoding(withAllowedCharacters: queryValueCharacters),
              let file = destination.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) else { return nil }
        return URL(string: "obsidian://open?vault=\(vault)&file=\(file)")
    }
}
