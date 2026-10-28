import Foundation
import CryptoKit

actor WowPlanService {
    private let store: PlanFolderStore

    init(store: PlanFolderStore = PlanFolderStore()) {
        self.store = store
    }

    func read(now: Date = Date()) throws -> WowPlanSnapshot {
        let raw = try store.read(now: now)
        return try WowPlanParser.snapshot(from: raw)
    }

    func toggle(_ plan: WowItem, now: Date = Date()) throws -> WowPlanSnapshot {
        guard let source = plan.source else {
            throw NSError(domain: "Wow.Plan", code: 1, userInfo: [NSLocalizedDescriptionKey: "This plan is not connected to Obsidian."])
        }
        let raw = try store.toggle(source: source.dictionary, now: now)
        return try WowPlanParser.snapshot(from: raw)
    }

    func connect(_ url: URL) throws {
        try store.connect(url)
    }
}

enum WowPlanParser {
    private static let datePattern = #"(\d{4})\s*(?:年|-)\s*(\d{1,2})\s*(?:月|-)\s*(\d{1,2})\s*日?"#
    private static let headingPattern = #"^###\s+(\d{1,2}):(\d{2})\s*[-–—~～]\s*(\d{1,2}):(\d{2})\s*[｜|]\s*(.+?)\s*$"#
    private static let taskPattern = #"^\s*[-*+]\s+\[([ xX])\]\s+(.+?)\s*$"#
    private static let colonClockWithPeriodPattern = #"^(上午|下午|早上|晚上|中午)\s*([01]?\d|2[0-3]):([0-5]\d)"#
    private static let colonClockPattern = #"^([01]?\d|2[0-3]):([0-5]\d)"#
    private static let chineseClockWithPeriodPattern = #"^(上午|下午|早上|晚上|中午)\s*([01]?\d|2[0-3])点(?:(半)|([0-5]\d)分)?"#
    private static let chineseClockPattern = #"^([01]?\d|2[0-3])点(?:(半)|([0-5]\d)分)?"#
    private static let rangeSeparatorPattern = #"^\s*[-–—~～]\s*"#
    private static let headingLinePattern = #"^#{1,6}\s"#
    private static let blockIdPattern = #"\s\^([A-Za-z0-9-]+)\s*$"#
    private static let behaviorPattern = #"^\s*[-*+]\s+\[[ xX]\]\s+(?:\*\*|__)?Behavior[：:](?:\*\*|__)?"#
    private static let tableSeparatorPattern = #"^:?-{3,}:?$"#

    private struct ClockMatch {
        let value: String
        let endIndex: String.Index
    }

    private struct ParsedBody {
        let startTime: String?
        let endTime: String?
        let title: String
    }

    private struct TableDefinition {
        let headerLineIndex: Int
        let completionColumn: Int
        let timeColumn: Int
        let contentColumn: Int
        let locationColumn: Int
    }

    private struct ParsedTableRow {
        let marker: String
        let time: String
        let title: String
        let location: String
        let completionColumn: Int
    }

    static func snapshot(from raw: [String: Any]) throws -> WowPlanSnapshot {
        let today = raw["today"] as? String ?? PlanFolderStore.day(Date())
        let source = raw["source"] as? String ?? ""
        let markdown = raw["markdown"] as? String
        let defaultYear = Int(today.prefix(4))
        let parsed = markdown.map { parse($0, filename: source, defaultYear: defaultYear) } ?? ParsedResult(date: nil, plans: [], warnings: [], summary: "No note content was read")
        let filenameDate = date(from: source, defaultYear: defaultYear)
        let date = filenameDate ?? parsed.date
        let isToday = date == today
        return WowPlanSnapshot(
            plans: isToday ? stablePlanIDs(parsed.plans) : [],
            source: source,
            date: date,
            today: today,
            isToday: isToday,
            warnings: parsed.warnings,
            summary: parsed.summary,
            connected: raw["connected"] as? Bool ?? false,
            status: raw["status"] as? String ?? "unknown"
        )
    }

    /// Parser row indices move after edits. Bind reminders to note + block ID (or normalized content),
    /// with an occurrence suffix for duplicate lines, rather than to a transient row position.
    private static func stablePlanIDs(_ plans: [WowItem]) -> [WowItem] {
        var occurrences: [String: Int] = [:]
        return plans.map { item in
            guard let source = item.source else { return item }
            let line = source.scheduleLine.replacingOccurrences(of: #"\[([ xX])\]"#, with: "[ ]", options: .regularExpression)
            let key = source.filename + "|" + (source.sourceBlockId ?? line)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let digest = SHA256.hash(data: Data((key + "|\(occurrence)").utf8)).map { String(format: "%02x", $0) }.joined()
            var copy = item
            copy.id = "obsidian-" + digest
            return copy
        }
    }

    private struct ParsedResult {
        let date: String?
        let plans: [WowItem]
        let warnings: [String]
        let summary: String
    }

    private static func parse(_ markdown: String, filename: String, defaultYear: Int? = nil) -> ParsedResult {
        let lines = markdown.components(separatedBy: .newlines)
        let heading = lines.first(where: { $0.range(of: #"^#\s+"#, options: .regularExpression) != nil }) ?? ""
        let parsedDate = date(from: heading, defaultYear: defaultYear) ?? date(from: filename, defaultYear: defaultYear)
        var plans: [WowItem] = []
        var warnings: [String] = []
        var candidateCount = 0
        var importedCount = 0
        var untimedCount = 0
        var consumedBehaviorLines = Set<Int>()
        var consumedTableLines = Set<Int>()
        var inFence = false
        var inFrontMatter = false

        for lineIndex in lines.indices {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if lineIndex == 0 && trimmed == "---" {
                inFrontMatter = true
                continue
            }
            if inFrontMatter {
                if trimmed == "---" { inFrontMatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if let table = tableDefinition(at: lineIndex, in: lines) {
                consumedTableLines.insert(lineIndex)
                consumedTableLines.insert(lineIndex + 1)
                var rowIndex = lineIndex + 2
                while rowIndex < lines.count,
                      let cells = tableCells(in: lines[rowIndex]) {
                    consumedTableLines.insert(rowIndex)
                    if let row = parseTableRow(cells, definition: table) {
                        if !row.title.isEmpty {
                            candidateCount += 1
                            var startTime: String?
                            var endTime: String?
                            if !row.time.isEmpty {
                                guard let parsedTime = parseTableTime(row.time) else {
                                    warnings.append("Invalid table time: \(lines[rowIndex])")
                                    rowIndex += 1
                                    continue
                                }
                                startTime = parsedTime.startTime
                                endTime = parsedTime.endTime
                                if let startTime, let endTimeValue = endTime,
                                   WowTime.minutes(endTimeValue) <= WowTime.minutes(startTime) {
                                    warnings.append("Invalid table time range; kept the start time only: \(lines[rowIndex])")
                                    endTime = nil
                                }
                            }

                            let sourceFileName = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
                            let source = WowPlanSource(
                                filename: filename,
                                sourceFileName: sourceFileName,
                                sourceNotePath: filename,
                                sourceRelativePath: filename,
                                lineIndex: rowIndex,
                                line: lines[rowIndex],
                                identity: normalizedTablePlanLine(lines[rowIndex], completionColumn: row.completionColumn),
                                sourceLineIndex: rowIndex,
                                sourceRawLine: lines[rowIndex],
                                sourceHeading: "",
                                scheduleLineIndex: rowIndex,
                                scheduleLine: lines[rowIndex],
                                hasBehaviorCheckbox: false,
                                behaviorLineIndex: nil,
                                behaviorLine: nil,
                                sourceBlockId: firstCapture(blockIdPattern, in: lines[rowIndex]),
                                sourceFormat: "table",
                                completionColumn: row.completionColumn
                            )
                            let dateKey = parsedDate ?? "unknown"
                            plans.append(WowItem(
                                id: "obsidian-\(dateKey)-table-\(rowIndex)-\(plans.count)",
                                title: row.title,
                                note: "",
                                location: row.location,
                                startTime: startTime,
                                endTime: endTime,
                                completed: row.marker.lowercased() == "x",
                                source: source,
                                origin: .localParser,
                                completionBehavior: .obsidianCheckbox
                            ))
                            importedCount += 1
                            if startTime == nil { untimedCount += 1 }
                        }
                    }
                    rowIndex += 1
                }
                continue
            }

            if consumedTableLines.contains(lineIndex) { continue }

            if let headingMatch = captures(headingPattern, in: line), headingMatch.count == 5 {
                candidateCount += 1
                let startHour = headingMatch[0]
                let startMinute = headingMatch[1]
                let endHour = headingMatch[2]
                let endMinute = headingMatch[3]
                guard validTimeRange(startHour, startMinute, endHour, endMinute) else {
                    warnings.append("Invalid time range: \(line)")
                    continue
                }

                var behaviorIndex: Int?
                var behaviorLine: String?
                if lineIndex + 1 < lines.count {
                    for candidateIndex in (lineIndex + 1)..<lines.count {
                        let candidate = lines[candidateIndex]
                        if candidate.range(of: headingLinePattern, options: .regularExpression) != nil { break }
                        if isBehaviorLine(candidate) {
                            behaviorIndex = candidateIndex
                            behaviorLine = candidate
                            consumedBehaviorLines.insert(candidateIndex)
                            break
                        }
                    }
                }

                let sourceHeading = line
                    .replacingOccurrences(of: #"^###\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+\^[A-Za-z0-9-]+\s*$"#, with: "", options: .regularExpression)
                let sourceLine = behaviorLine ?? ""
                let sourceFileName = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
                let sourceBlockId = firstCapture(blockIdPattern, in: sourceLine.isEmpty ? line : sourceLine) ?? firstCapture(blockIdPattern, in: line)
                let completed = behaviorLine.flatMap { captures(taskPattern, in: $0)?.first?.lowercased() == "x" } ?? false
                let source = WowPlanSource(
                    filename: filename,
                    sourceFileName: sourceFileName,
                    sourceNotePath: filename,
                    sourceRelativePath: filename,
                    lineIndex: behaviorIndex ?? lineIndex,
                    line: sourceLine,
                    identity: sourceLine.replacingOccurrences(of: #"\[([ xX])\]"#, with: "[ ]", options: .regularExpression),
                    sourceLineIndex: lineIndex,
                    sourceRawLine: line,
                    sourceHeading: sourceHeading,
                    scheduleLineIndex: lineIndex,
                    scheduleLine: line,
                    hasBehaviorCheckbox: behaviorIndex != nil,
                    behaviorLineIndex: behaviorIndex,
                    behaviorLine: behaviorLine,
                    sourceBlockId: sourceBlockId
                )
                let dateKey = parsedDate ?? "unknown"
                plans.append(WowItem(
                    id: "obsidian-\(dateKey)-\(startHour)-\(startMinute)-\(plans.count)",
                    title: headingMatch[4],
                    note: "",
                    startTime: "\(startHour.padStart(2)):\(startMinute)",
                    endTime: "\(endHour.padStart(2)):\(endMinute)",
                    completed: completed,
                    source: source,
                    origin: .localParser,
                    completionBehavior: behaviorIndex == nil ? .obsidianCheckbox : .obsidianBehavior
                ))
                importedCount += 1
                continue
            }

            if consumedBehaviorLines.contains(lineIndex) || isBehaviorLine(line) { continue }
            guard let taskMatch = captures(taskPattern, in: line), taskMatch.count == 2 else {
                continue
            }

            candidateCount += 1
            let parsedBody = parseBody(taskMatch[1])
            guard !parsedBody.title.isEmpty else {
                warnings.append("A checklist item has no title: \(line)")
                continue
            }

            var endTime = parsedBody.endTime
            if let startTime = parsedBody.startTime, let endTimeValue = endTime,
               WowTime.minutes(endTimeValue) <= WowTime.minutes(startTime) {
                warnings.append("Invalid time range; kept the start time only: \(line)")
                endTime = nil
            }

            let sourceFileName = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
            let sourceBlockId = firstCapture(blockIdPattern, in: line)
            let source = WowPlanSource(
                filename: filename,
                sourceFileName: sourceFileName,
                sourceNotePath: filename,
                sourceRelativePath: filename,
                lineIndex: lineIndex,
                line: line,
                identity: line.replacingOccurrences(of: #"\[([ xX])\]"#, with: "[ ]", options: .regularExpression),
                sourceLineIndex: lineIndex,
                sourceRawLine: line,
                sourceHeading: "",
                scheduleLineIndex: lineIndex,
                scheduleLine: line,
                hasBehaviorCheckbox: false,
                behaviorLineIndex: nil,
                behaviorLine: nil,
                sourceBlockId: sourceBlockId
            )
            let dateKey = parsedDate ?? "unknown"
            let marker = taskMatch[0]
            plans.append(WowItem(
                id: "obsidian-\(dateKey)-\(lineIndex)-\(plans.count)",
                title: parsedBody.title,
                note: "",
                startTime: parsedBody.startTime,
                endTime: endTime,
                completed: marker.lowercased() == "x",
                source: source,
                origin: .localParser,
                completionBehavior: .obsidianCheckbox
            ))
            importedCount += 1
            if parsedBody.startTime == nil { untimedCount += 1 }
        }

        if parsedDate == nil {
            warnings.append("The note has no recognizable date; it is not treated as today’s schedule.")
        }
        if candidateCount > importedCount {
            warnings.append("Some checklist items could not be imported.")
        }
        if candidateCount > 0 && importedCount == 0 {
            warnings.append("Checklist items were found, but none could be imported.")
        }

        let summary: String
        if candidateCount == 0 {
            summary = "No checklist tasks found"
        } else if untimedCount == 0 {
            summary = "Found \(candidateCount) checklist tasks · imported \(importedCount)"
        } else {
            summary = "Found \(candidateCount) checklist tasks · imported \(importedCount) · \(untimedCount) without a time"
        }
        return ParsedResult(date: parsedDate, plans: plans, warnings: warnings, summary: summary)
    }

    private static func parseBody(_ body: String) -> ParsedBody {
        var value = trimMarkdownDecoration(body)
        guard let start = clockPrefix(in: value) else {
            return ParsedBody(startTime: nil, endTime: nil, title: trimMarkdownDecoration(value))
        }

        value = String(value[start.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var endTime: String?
        if let separator = firstMatch(rangeSeparatorPattern, in: value),
           let separatorRange = Range(separator.range, in: value) {
            let afterSeparator = String(value[separatorRange.upperBound...])
            if let end = clockPrefix(in: afterSeparator) {
                endTime = end.value
                value = String(afterSeparator[end.endIndex...])
            }
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"^(左右|大约|约|前后)\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^[｜|]\s*"#, with: "", options: .regularExpression)
        return ParsedBody(startTime: start.value, endTime: endTime, title: trimMarkdownDecoration(value))
    }

    private static func clockPrefix(in value: String) -> ClockMatch? {
        if let match = firstMatch(colonClockWithPeriodPattern, in: value),
           let period = capture(1, in: match, value: value),
           let hour = capture(2, in: match, value: value),
           let minute = capture(3, in: match, value: value),
           let endIndex = Range(match.range, in: value)?.upperBound {
            return ClockMatch(value: normalizedClock(period: period, hour: hour, minute: minute), endIndex: endIndex)
        }
        if let match = firstMatch(colonClockPattern, in: value),
           let hour = capture(1, in: match, value: value),
           let minute = capture(2, in: match, value: value),
           let endIndex = Range(match.range, in: value)?.upperBound {
            return ClockMatch(value: normalizedClock(period: nil, hour: hour, minute: minute), endIndex: endIndex)
        }
        if let match = firstMatch(chineseClockWithPeriodPattern, in: value),
           let period = capture(1, in: match, value: value),
           let hour = capture(2, in: match, value: value),
           let endIndex = Range(match.range, in: value)?.upperBound {
            let minute = capture(3, in: match, value: value) != nil ? "30" : capture(4, in: match, value: value) ?? "00"
            return ClockMatch(value: normalizedClock(period: period, hour: hour, minute: minute), endIndex: endIndex)
        }
        if let match = firstMatch(chineseClockPattern, in: value),
           let hour = capture(1, in: match, value: value),
           let endIndex = Range(match.range, in: value)?.upperBound {
            let minute = capture(2, in: match, value: value) != nil ? "30" : capture(3, in: match, value: value) ?? "00"
            return ClockMatch(value: normalizedClock(period: nil, hour: hour, minute: minute), endIndex: endIndex)
        }
        return nil
    }

    private static func normalizedClock(period: String?, hour: String, minute: String) -> String {
        var hourValue = Int(hour) ?? 0
        let minuteValue = Int(minute) ?? 0
        if let period {
            if ["下午", "晚上"].contains(period), hourValue < 12 { hourValue += 12 }
            if ["上午", "早上"].contains(period), hourValue == 12 { hourValue = 0 }
            if period == "中午", hourValue < 12 { hourValue += 12 }
        }
        return String(format: "%02d:%02d", hourValue, minuteValue)
    }

    private static func trimMarkdownDecoration(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("**") || result.hasPrefix("__") {
            result.removeFirst(2)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while result.hasSuffix("**") || result.hasSuffix("__") {
            result.removeLast(2)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func isBehaviorLine(_ line: String) -> Bool {
        line.range(of: behaviorPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func validTimeRange(_ hour: String, _ minute: String, _ endHour: String, _ endMinute: String) -> Bool {
        guard let hour = Int(hour), let minute = Int(minute), let endHour = Int(endHour), let endMinute = Int(endMinute),
              hour <= 23, endHour <= 23, minute <= 59, endMinute <= 59 else { return false }
        return endHour * 60 + endMinute > hour * 60 + minute
    }

    private static func date(from value: String, defaultYear: Int? = nil) -> String? {
        if let values = captures(datePattern, in: value), values.count == 3,
           let year = Int(values[0]), let month = Int(values[1]), let day = Int(values[2]) {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        let shortPattern = #"(?:^|[^0-9])(\d{1,2})\.(\d{1,2})(?:\.md)?$"#
        guard let values = captures(shortPattern, in: value), values.count == 2,
              let year = defaultYear,
              let month = Int(values[0]), let day = Int(values[1]) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func tableDefinition(at lineIndex: Int, in lines: [String]) -> TableDefinition? {
        guard lineIndex + 1 < lines.count,
              let header = tableCells(in: lines[lineIndex]),
              let separator = tableCells(in: lines[lineIndex + 1]),
              header.count == separator.count,
              header.count >= 4,
              separator.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).range(of: tableSeparatorPattern, options: .regularExpression) != nil }) else { return nil }

        func findColumn(_ aliases: Set<String>) -> Int? {
            header.firstIndex { aliases.contains(normalizedTableHeader($0)) }
        }

        guard let completionColumn = findColumn(["完成", "checkbox", "check", "done", "状态"]),
              let timeColumn = findColumn(["时间", "time", "时段"]),
              let contentColumn = findColumn(["内容", "计划", "任务", "plan", "content"]),
              let locationColumn = findColumn(["地点", "位置", "场所", "location", "place"]) else { return nil }
        return TableDefinition(
            headerLineIndex: lineIndex,
            completionColumn: completionColumn,
            timeColumn: timeColumn,
            contentColumn: contentColumn,
            locationColumn: locationColumn
        )
    }

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func normalizedTableHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .lowercased()
    }

    private static func parseTableRow(_ cells: [String], definition: TableDefinition) -> ParsedTableRow? {
        guard definition.completionColumn < cells.count,
              definition.timeColumn < cells.count,
              definition.contentColumn < cells.count,
              definition.locationColumn < cells.count,
              let marker = tableCheckboxMarker(in: cells[definition.completionColumn]) else { return nil }
        return ParsedTableRow(
            marker: marker,
            time: cells[definition.timeColumn].trimmingCharacters(in: .whitespacesAndNewlines),
            title: trimMarkdownDecoration(cells[definition.contentColumn]),
            location: trimMarkdownDecoration(cells[definition.locationColumn]),
            completionColumn: definition.completionColumn
        )
    }

    private static func tableCheckboxMarker(in cell: String) -> String? {
        let pattern = #"^\s*\[([ xX])\]\s*$"#
        guard let values = captures(pattern, in: cell), values.count == 1 else { return nil }
        return values[0]
    }

    private static func normalizedTablePlanLine(_ line: String, completionColumn: Int) -> String {
        guard let cells = tableCells(in: line), completionColumn < cells.count,
              let markerRange = tableCheckboxMarkerRange(in: cells[completionColumn]) else { return line }
        let ranges = tableCellRanges(in: line)
        guard completionColumn < ranges.count else { return line }
        let normalized = NSMutableString(string: line)
        normalized.replaceCharacters(in: NSRange(location: ranges[completionColumn].location + markerRange.location, length: 1), with: " ")
        return normalized as String
    }

    private static func tableCheckboxMarkerRange(in cell: String) -> NSRange? {
        let pattern = #"^\s*\[([ xX])\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) else { return nil }
        return match.range(at: 1)
    }

    private static func tableCellRanges(in line: String) -> [NSRange] {
        let text = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return ranges
    }

    private static func parseTableTime(_ value: String) -> (startTime: String, endTime: String?)? {
        guard let start = clockPrefix(in: value) else { return nil }
        let remainder = String(value[start.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return (start.value, nil) }
        guard let separator = firstMatch(rangeSeparatorPattern, in: remainder),
              let separatorRange = Range(separator.range, in: remainder) else { return nil }
        let endValue = String(remainder[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = clockPrefix(in: endValue),
              endValue[end.endIndex...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (start.value, end.value)
    }

    private static func firstMatch(_ pattern: String, in value: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func capture(_ index: Int, in match: NSTextCheckingResult, value: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        return String(value[swiftRange])
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let match = firstMatch(pattern, in: value) else { return nil }
        return (1..<match.numberOfRanges).compactMap { capture($0, in: match, value: value) }
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        captures(pattern, in: value)?.first
    }
}

private extension String {
    func padStart(_ length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
