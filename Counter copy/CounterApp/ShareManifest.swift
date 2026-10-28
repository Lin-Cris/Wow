import Foundation

struct SharedInboxItem: Codable {
    var id: String
    var filename: String
    var kind: String

    static let maximumImageBytes = 25 * 1_024 * 1_024
    static let maximumTextCharacters = 20_000
    static let maximumTextBytes = maximumTextCharacters * 4

    @discardableResult
    static func persist(_ data: Data, id: String, kind: String, in inbox: URL) throws -> String {
        guard UUID(uuidString: id) != nil else { throw SharedInboxError.invalidIdentifier }
        let fileExtension: String
        switch kind {
        case "image":
            guard !data.isEmpty, data.count <= maximumImageBytes else { throw SharedInboxError.invalidPayload }
            fileExtension = imageExtension(for: data)
            guard fileExtension != "img" else { throw SharedInboxError.invalidPayload }
        case "text":
            guard !data.isEmpty, data.count <= maximumTextBytes,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty,
                  text.count <= maximumTextCharacters else { throw SharedInboxError.invalidPayload }
            fileExtension = "txt"
        default:
            throw SharedInboxError.invalidPayload
        }

        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let filename = "\(id).\(fileExtension)"
        let payloadURL = inbox.appendingPathComponent(filename)
        let manifestURL = inbox.appendingPathComponent("\(id).json")
        do {
            try data.write(to: payloadURL, options: .atomic)
            let item = SharedInboxItem(id: id, filename: filename, kind: kind)
            try JSONEncoder().encode(item).write(to: manifestURL, options: .atomic)
            return filename
        } catch {
            try? FileManager.default.removeItem(at: payloadURL)
            try? FileManager.default.removeItem(at: manifestURL)
            throw error
        }
    }

    static func imageExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if String(bytes: bytes.prefix(6), encoding: .ascii).map({ $0 == "GIF87a" || $0 == "GIF89a" }) == true { return "gif" }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return "heic" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        return "img"
    }
}

enum SharedInboxError: LocalizedError {
    case invalidIdentifier, invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "待记账任务编号无效"
        case .invalidPayload: "分享内容为空、格式不支持或超过大小限制"
        }
    }
}
