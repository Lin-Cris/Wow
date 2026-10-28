import Foundation
import os

private let planFolderLog = Logger(subsystem: "com.chris.CheckBot", category: "PlanFolder")

/// Persists only the user's folder permission bookmark; Markdown remains the source of truth.
final class PlanFolderStore {
    private let defaults: UserDefaults
    private let key = "planFolderBookmark"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func connect(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        debugLog("Selected folder: \(url.lastPathComponent) | URL: \(url.absoluteString) | security scope granted: \(accessing)")
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw failure("Select the Plan folder, not an individual file.")
        }
        let files = try coordinatedContents(of: url, manager: .default)
        debugEnumerate(files)
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: key)
        debugLog("Saved security-scoped bookmark for: \(url.lastPathComponent)")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func filename(for date: Date = Date()) -> String {
        "\(monthDay(date)).md"
    }

    static func monthDay(_ date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        return "\(parts.month!).\(parts.day!)"
    }

    static func dateInFilename(_ filename: String) -> String? {
        let fullPattern = #"^(\d{4})\s*(?:年|-)\s*(\d{1,2})\s*(?:月|-)\s*(\d{1,2})\s*日?\.md$"#
        if let regex = try? NSRegularExpression(pattern: fullPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: filename).flatMap { Int(filename[$0]) } }
            guard parts.count == 3 else { return nil }
            return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
        }

        let shortPattern = #"^(\d{1,2})\.(\d{1,2})\.md$"#
        guard let regex = try? NSRegularExpression(pattern: shortPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let month = Range(match.range(at: 1), in: filename).flatMap({ Int(filename[$0]) }),
              let day = Range(match.range(at: 2), in: filename).flatMap({ Int(filename[$0]) }) else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func read(now: Date = Date()) throws -> [String: Any] {
        let today = Self.day(now)
        let todayFilename = Self.filename(for: now)
        var result: [String: Any] = ["today": today, "expectedFilename": todayFilename, "source": "", "connected": false, "status": "disconnected", "folderState": "folder_not_connected"]
        guard let bookmark = defaults.data(forKey: key) else { return result }
        var stale = false
        let folder: URL
        do { folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch {
            debugLog("Folder access failed while resolving bookmark: \(error.localizedDescription)")
            result["status"] = "folder_access_failed"
            result["folderState"] = "folder_access_failed"
            return result
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        debugLog("Connected folder: \(folder.lastPathComponent)")
        debugLog("Restored folder: \(folder.lastPathComponent) | URL: \(folder.absoluteString) | security scope granted: \(accessing) | stale: \(stale)")
        if stale { try connect(folder) }
        result["connected"] = true
        let manager = FileManager.default
        let files: [URL]
        do { files = try coordinatedContents(of: folder, manager: manager) }
        catch {
            debugLog("Folder access failed while enumerating \(folder.lastPathComponent): \(error.localizedDescription)")
            result["status"] = "folder_access_failed"
            result["folderState"] = "folder_access_failed"
            return result
        }
        debugEnumerate(files)
        let markdownFiles = files
            .filter { file in
                file.pathExtension.caseInsensitiveCompare("md") == .orderedSame
                    && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { relativePath(for: $0, from: folder).localizedStandardCompare(relativePath(for: $1, from: folder)) == .orderedAscending }
        result["markdownFileCount"] = markdownFiles.count
        result["markdownFiles"] = markdownFiles.map { relativePath(for: $0, from: folder) }
        result["folderState"] = "markdown_files_found"
        debugLog("Found Markdown files: \(markdownFiles.count)")
        let matching = matchingTodayFiles(in: markdownFiles, folder: folder, today: today, expectedFilename: todayFilename)
        guard matching.count <= 1 else { throw failure("More than one note matches today. Keep one daily note for this date.") }
        let file: URL
        if let existing = matching.first {
            file = existing
        } else {
            result["status"] = "no_today_note"
            result["folderState"] = "no_today_note"
            debugLog("No Markdown note found for today; no file was created")
            return result
        }
        let sourcePath = relativePath(for: file, from: folder)
        result["source"] = sourcePath
        result["status"] = "today_note_found"
        debugLog("TODAY NOTE FOUND")
        debugLog("filename: \(sourcePath)")
        let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let downloadStatus = self.downloadStatus(values.ubiquitousItemDownloadingStatus)
        let isDownloaded = values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus != .notDownloaded
        let isReadable = values.isReadable == true
        result["isReadable"] = isReadable
        result["isDownloaded"] = isDownloaded
        result["downloadStatus"] = downloadStatus
        debugLog("filename: \(sourcePath) | isReadable: \(isReadable) | isDownloaded: \(isDownloaded) | downloadStatus: \(downloadStatus)")
        if values.isUbiquitousItem == true && !isDownloaded {
            try manager.startDownloadingUbiquitousItem(at: file)
            result["status"] = "downloading"
            debugLog("Requested iCloud download for today’s note: \(sourcePath)")
            return result
        }
        do {
            let markdown = try coordinatedText(at: file)
            result["markdown"] = markdown
            debugLog("characters: \(markdown.count)")
            debugLog("read success: true")
        } catch {
            debugLog("read success: false | filename: \(sourcePath) | error: \(error.localizedDescription)")
            throw error
        }
        result["status"] = "ready"
        return result
    }

    func toggle(source: [String: Any], now: Date = Date()) throws -> [String: Any] {
        guard let filename = source["filename"] as? String,
              let scheduleLineIndex = source["scheduleLineIndex"] as? Int,
              let scheduleLine = source["scheduleLine"] as? String,
              !scheduleLine.isEmpty else {
            throw failure("The task source reference is incomplete. Refresh the plan and try again.")
        }
        let inlineSourceLine = (source["sourceRawLine"] as? String) ?? scheduleLine
        let sourceLineIndex = source["sourceLineIndex"] as? Int
        let isInlinePlan = sourceLineIndex == scheduleLineIndex && taskCheckboxCharacterRange(in: inlineSourceLine) != nil

        let todayFilename = Self.filename(for: now)
        let sourceFileName = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
        guard Self.isTodayFilename(sourceFileName, now: now) else {
            throw failure("The task is no longer from today’s note. Refresh the plan and try again.")
        }
        guard let bookmark = defaults.data(forKey: key) else {
            throw failure("Connect your Plan folder before completing a task.")
        }

        var stale = false
        let folder: URL
        do { folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw failure("The Plan folder permission is unavailable. Reconnect the Plan folder and try again.") }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if stale { try connect(folder) }

        let files = try coordinatedContents(of: folder, manager: .default)
            .filter { file in
                file.pathExtension.caseInsensitiveCompare("md") == .orderedSame
                    && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        let sourceMatch = files.first { relativePath(for: $0, from: folder) == filename }
        let matches = matchingTodayFiles(in: files, folder: folder, today: Self.day(now), expectedFilename: todayFilename)
        let file = sourceMatch ?? (matches.count == 1 ? matches.first : nil)
        guard matches.count <= 1 || sourceMatch != nil, let file else {
            throw failure("Today’s Markdown note could not be located safely. Refresh the plan and try again.")
        }

        var coordinationError: NSError?
        var writeResult: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { coordinatedFile in
            writeResult = Result {
                let latest = try self.readTextDirectly(at: coordinatedFile)
                let lines = self.markdownLines(latest)
                let updated = NSMutableString(string: latest)
                if source["sourceFormat"] as? String == "table" {
                    let sourceLineIndex = (source["sourceLineIndex"] as? Int) ?? (source["lineIndex"] as? Int)
                    guard let sourceLineIndex,
                          sourceLineIndex >= 0,
                          sourceLineIndex < lines.count else {
                        throw self.failure("The table row is unavailable. Refresh the plan and try again.")
                    }
                    let matchedLine = lines[sourceLineIndex]
                    let rawLine = (source["sourceRawLine"] as? String) ?? (source["line"] as? String)
                    let identity = source["identity"] as? String
                    let completionColumn = source["completionColumn"] as? Int
                    let rawMatches = rawLine.map { $0 == matchedLine.content } ?? false
                    let identityMatches: Bool
                    if let identity, let completionColumn {
                        identityMatches = self.normalizedTablePlanLine(matchedLine.content, completionColumn: completionColumn) == identity
                    } else {
                        identityMatches = false
                    }
                    guard rawMatches || identityMatches else {
                        throw self.failure("The table row changed externally and could not be located safely. Refresh the plan and try again.")
                    }
                    guard let completionColumn,
                          let cells = self.tableCells(in: matchedLine.content),
                          completionColumn >= 0,
                          completionColumn < cells.count,
                          let checkboxCharacter = self.tableCheckboxCharacterRange(in: cells[completionColumn].content) else {
                        throw self.failure("The table checkbox changed externally. No file changes were made.")
                    }
                    let currentMarker = (cells[completionColumn].content as NSString).substring(with: checkboxCharacter)
                    let replacement = currentMarker.lowercased() == "x" ? " " : "x"
                    let lineRange = NSRange(location: cells[completionColumn].range.location + checkboxCharacter.location, length: 1)
                    let globalRange = NSRange(location: matchedLine.fullRange.location + lineRange.location, length: lineRange.length)
                    updated.replaceCharacters(in: globalRange, with: replacement)
                    self.debugLog("Toggled table Plan row \(sourceLineIndex)")
                } else if isInlinePlan {
                    let sourceLineIndex = (source["sourceLineIndex"] as? Int) ?? (source["lineIndex"] as? Int)
                    guard let sourceLineIndex,
                          sourceLineIndex >= 0,
                          sourceLineIndex < lines.count else {
                        throw self.failure("The task source line is unavailable. Refresh the plan and try again.")
                    }
                    let matchedLine = lines[sourceLineIndex]
                    guard let checkboxCharacter = self.taskCheckboxCharacterRange(in: matchedLine.content) else {
                        throw self.failure("The task source line changed externally and could not be located safely. Refresh the plan and try again.")
                    }
                    let rawLine = (source["sourceRawLine"] as? String) ?? (source["line"] as? String)
                    let identity = source["identity"] as? String
                    let rawMatches = rawLine.map { $0 == matchedLine.content } ?? false
                    let identityMatches = identity.map { self.normalizedInlinePlanLine(matchedLine.content) == Optional($0) } ?? false
                    guard rawMatches || identityMatches else {
                        throw self.failure("The task source line changed externally and could not be located safely. Refresh the plan and try again.")
                    }
                    let currentMarker = (matchedLine.content as NSString).substring(with: checkboxCharacter)
                    let replacement = currentMarker.lowercased() == "x" ? " " : "x"
                    let globalRange = NSRange(location: matchedLine.fullRange.location + checkboxCharacter.location, length: 1)
                    updated.replaceCharacters(in: globalRange, with: replacement)
                    self.debugLog("Toggled inline Plan line \(sourceLineIndex)")
                } else {
                    let scheduleMatches = lines.enumerated().compactMap { index, line -> Int? in
                        line.content == scheduleLine ? index : nil
                    }
                    guard scheduleMatches.count == 1, let scheduleIndex = scheduleMatches.first else {
                        if scheduleMatches.isEmpty { throw self.failure("The schedule heading changed externally and could not be located safely. Refresh the plan and try again.") }
                        throw self.failure("More than one matching schedule heading was found. No file changes were made.")
                    }
                    self.debugLog("Resolved schedule source line \(scheduleLineIndex) to latest line \(scheduleIndex)")

                    let searchStart = scheduleIndex + 1
                    let nextHeadingIndex: Int
                    if searchStart < lines.count {
                        nextHeadingIndex = lines[searchStart..<lines.count].firstIndex { line in
                            line.content.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
                        } ?? lines.count
                    } else {
                        nextHeadingIndex = lines.count
                    }
                    let behaviorMatches: [Int]
                    if searchStart < nextHeadingIndex {
                        behaviorMatches = lines[searchStart..<nextHeadingIndex].enumerated().compactMap { offset, line in
                            self.behaviorCheckboxCharacterRange(in: line.content) == nil ? nil : searchStart + offset
                        }
                    } else {
                        behaviorMatches = []
                    }
                    guard behaviorMatches.count <= 1 else {
                        throw self.failure("More than one Behavior checkbox was found in this schedule. No file changes were made.")
                    }

                    if let behaviorIndex = behaviorMatches.first {
                        let matchedLine = lines[behaviorIndex]
                        guard let checkboxCharacter = self.behaviorCheckboxCharacterRange(in: matchedLine.content) else {
                            throw self.failure("The task checkbox changed externally. No file changes were made.")
                        }
                        let currentMarker = (matchedLine.content as NSString).substring(with: checkboxCharacter)
                        let replacement = currentMarker.lowercased() == "x" ? " " : "x"
                        let globalRange = NSRange(location: matchedLine.fullRange.location + checkboxCharacter.location, length: 1)
                        updated.replaceCharacters(in: globalRange, with: replacement)
                        self.debugLog("Toggled Behavior line \(behaviorIndex)")
                    } else {
                        let headingLine = lines[scheduleIndex]
                        let lineEnding = headingLine.lineEnding.isEmpty ? self.firstLineEnding(in: latest) : headingLine.lineEnding
                        let prefix = headingLine.lineEnding.isEmpty ? lineEnding : ""
                        let insertion = "\(prefix)- [x] **Behavior：**\(lineEnding)"
                        updated.insert(insertion, at: NSMaxRange(headingLine.fullRange))
                        self.debugLog("Inserted Behavior line below schedule line \(scheduleIndex)")
                    }
                }
                guard let data = (updated as String).data(using: .utf8) else {
                    throw self.failure("The Markdown note could not be encoded safely.")
                }
                try data.write(to: coordinatedFile, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let writeResult else { throw failure("The Markdown note could not be coordinated for writing.") }
        try writeResult.get()
        return try read(now: now)
    }

    private struct MarkdownLine {
        let content: String
        let fullRange: NSRange
        let lineEnding: String
    }

    private func markdownLines(_ markdown: String) -> [MarkdownLine] {
        let text = markdown as NSString
        var lines: [MarkdownLine] = []
        var location = 0
        while location < text.length {
            let fullRange = text.lineRange(for: NSRange(location: location, length: 0))
            let fullText = text.substring(with: fullRange)
            let lineEnding: String
            if fullText.hasSuffix("\r\n") { lineEnding = "\r\n" }
            else if fullText.hasSuffix("\n") { lineEnding = "\n" }
            else if fullText.hasSuffix("\r") { lineEnding = "\r" }
            else { lineEnding = "" }
            lines.append(MarkdownLine(content: fullText.trimmingCharacters(in: .newlines), fullRange: fullRange, lineEnding: lineEnding))
            let next = NSMaxRange(fullRange)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    private func behaviorCheckboxCharacterRange(in line: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([ xX])\]\s+(?:\*\*|__)?Behavior[：:](?:\*\*|__)?"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return match.range(at: 1)
    }

    private func taskCheckboxCharacterRange(in line: String) -> NSRange? {
        let pattern = #"^\s*[-*+]\s+\[([ xX])\](?:\s+.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return match.range(at: 1)
    }

    private func normalizedInlinePlanLine(_ line: String) -> String? {
        guard let checkboxCharacter = taskCheckboxCharacterRange(in: line) else { return nil }
        let normalized = NSMutableString(string: line)
        normalized.replaceCharacters(in: checkboxCharacter, with: " ")
        return normalized as String
    }

    private struct TableCell {
        let content: String
        let range: NSRange
    }

    private func tableCells(in line: String) -> [TableCell]? {
        let text = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return nil }
        var ranges: [NSRange] = []
        var start = 0
        for index in 0...text.length {
            if index == text.length || text.character(at: index) == 124 {
                ranges.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
        }
        if trimmed.hasPrefix("|"), !ranges.isEmpty { ranges.removeFirst() }
        if trimmed.hasSuffix("|"), !ranges.isEmpty { ranges.removeLast() }
        guard !ranges.isEmpty else { return nil }
        return ranges.map { range in
            TableCell(content: text.substring(with: range), range: range)
        }
    }

    private func tableCheckboxCharacterRange(in cell: String) -> NSRange? {
        let pattern = #"^\s*\[([ xX])\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) else { return nil }
        return match.range(at: 1)
    }

    private func normalizedTablePlanLine(_ line: String, completionColumn: Int) -> String? {
        guard let cells = tableCells(in: line), completionColumn >= 0, completionColumn < cells.count else { return nil }
        guard let marker = tableCheckboxCharacterRange(in: cells[completionColumn].content) else { return nil }
        let normalized = NSMutableString(string: line)
        let lineRange = NSRange(location: cells[completionColumn].range.location + marker.location, length: 1)
        normalized.replaceCharacters(in: lineRange, with: " ")
        return normalized as String
    }

    private func firstLineEnding(in markdown: String) -> String {
        if markdown.contains("\r\n") { return "\r\n" }
        if markdown.contains("\n") { return "\n" }
        if markdown.contains("\r") { return "\r" }
        return "\n"
    }

    private func readTextDirectly(at file: URL) throws -> String {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw failure("The plan note is too large (maximum 2 MB).") }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func coordinatedContents(of folder: URL, manager: FileManager) throws -> [URL] {
        var coordinationError: NSError?
        var contents: Result<[URL], Error>?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { coordinatedFolder in
            contents = Result {
                var found: [URL] = []
                guard let enumerator = manager.enumerator(
                    at: coordinatedFolder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return found }
                for case let url as URL in enumerator {
                    found.append(url)
                }
                return found
            }
        }
        if let coordinationError { throw coordinationError }
        guard let contents else { throw failure("Cannot access the Plan folder. Check Files/iCloud availability or reconnect the folder.") }
        do { return try contents.get() }
        catch { throw failure("Cannot access the Plan folder. Check Files/iCloud availability or reconnect the folder.") }
    }

    private func coordinatedText(at file: URL) throws -> String {
        var coordinationError: NSError?
        var content: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { coordinated in
            content = Result {
                let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw self.failure("The plan note is too large (maximum 2 MB).") }
                return try String(contentsOf: coordinated, encoding: .utf8)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let content else { throw failure("The note is not available yet. Try Refresh after iCloud downloads it.") }
        return try content.get()
    }

    private func debugEnumerate(_ files: [URL]) {
        #if DEBUG
        let markdownFiles = files
            .filter { $0.pathExtension.caseInsensitiveCompare("md") == .orderedSame }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        debugLog("Markdown files:")
        if markdownFiles.isEmpty { debugLog("  (none)") }
        for file in markdownFiles {
            do {
                let values = try file.resourceValues(forKeys: [.isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                let isDownloaded = values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus != .notDownloaded
                debugLog("  \(file.lastPathComponent) | isReadable: \(values.isReadable == true) | isDownloaded: \(isDownloaded) | downloadStatus: \(downloadStatus(values.ubiquitousItemDownloadingStatus))")
            } catch {
                debugLog("  \(file.lastPathComponent) | metadata error: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func downloadStatus(_ status: URLUbiquitousItemDownloadingStatus?) -> String {
        guard let status else { return "not_ubiquitous" }
        if status == .notDownloaded { return "notDownloaded" }
        if status == .downloaded { return "downloaded" }
        if status == .current { return "current" }
        return String(describing: status)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        planFolderLog.debug("\(message, privacy: .public)")
        print("[CheckBot Plan] \(message)")
        #endif
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "CheckBot.Plan", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    private func matchingTodayFiles(in files: [URL], folder: URL, today: String, expectedFilename: String) -> [URL] {
        let exact = files.filter { $0.lastPathComponent == expectedFilename }
        if !exact.isEmpty { return exact.sorted { relativePath(for: $0, from: folder) < relativePath(for: $1, from: folder) } }
        return files
            .filter { Self.isTodayFilename($0.lastPathComponent, today: today) }
            .sorted { relativePath(for: $0, from: folder) < relativePath(for: $1, from: folder) }
    }

    private static func isTodayFilename(_ filename: String, now: Date) -> Bool {
        if filename == Self.filename(for: now) { return true }
        if dateInFilename(filename) == Self.day(now) { return true }
        let shortPattern = #"^(\d{1,2})\.(\d{1,2})\.md$"#
        guard let regex = try? NSRegularExpression(pattern: shortPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let month = Range(match.range(at: 1), in: filename).flatMap({ Int(filename[$0]) }),
              let day = Range(match.range(at: 2), in: filename).flatMap({ Int(filename[$0]) }) else { return false }
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        return month == parts.month && day == parts.day
    }

    private static func isTodayFilename(_ filename: String, today: String) -> Bool {
        if dateInFilename(filename) == today { return true }
        guard let month = Int(today.dropFirst(5).prefix(2)),
              let day = Int(today.suffix(2)) else { return false }
        let shortPattern = #"^(\d{1,2})\.(\d{1,2})\.md$"#
        guard let regex = try? NSRegularExpression(pattern: shortPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let filenameMonth = Range(match.range(at: 1), in: filename).flatMap({ Int(filename[$0]) }),
              let filenameDay = Range(match.range(at: 2), in: filename).flatMap({ Int(filename[$0]) }) else { return false }
        return filenameMonth == month && filenameDay == day
    }

    private func relativePath(for file: URL, from folder: URL) -> String {
        let base = folder.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = file.standardizedFileURL.path
        let prefix = base.isEmpty ? "/" : "/\(base)/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return file.lastPathComponent
    }
}
