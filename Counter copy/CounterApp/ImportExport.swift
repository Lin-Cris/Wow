import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreFoundation

struct CSVPreview {
    var records: [BookEntry]
    var categories: [BookCategory]
    var rejectedRows: [String]
    var duplicateCount: Int = 0
    var conflictCount: Int = 0
    var sourceDigest: String = ""
    var inputRowCount: Int = 0

    var totalRows: Int { inputRowCount > 0 ? inputRowCount : records.count + duplicateCount + rejectedRows.count }
}

struct ImportCommitResult {
    var batchID: String? = nil
    var inserted: Int = 0
    var exactDuplicates: Int = 0
    var conflicts: Int = 0
    var invalid: Int = 0
}

enum CounterCSVError: LocalizedError {
    case unreadable, noHeader, malformedCSV, fileTooLarge, unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取文件编码，请另存为 UTF-8 CSV 后重试"
        case .noHeader: "没有找到可识别的账单表头或金额列"
        case .malformedCSV: "CSV 引号或字段结构不完整，请检查原文件后重试"
        case .fileTooLarge: "CSV 文件超过 30 MB 或包含过多行，请拆分后再导入"
        case .unsupportedVersion(let version): "Counter CSV 版本 \(version) 暂不支持"
        }
    }
}

enum CounterCSV {
    private static let currentVersion = 2
    static let maximumFileBytes = 30 * 1_024 * 1_024
    private static let maximumRows = 100_001
    private static let maximumCents = CounterMoney.maximumCents
    private static let amountPattern = try! NSRegularExpression(
        pattern: "^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]{1,2})?$"
    )

    private static let aliases: [String: Set<String>] = [
        "date": ["交易时间", "支付时间", "发生时间", "日期", "时间", "date", "datetime", "occurred_at"],
        "local_day": ["local_day", "记账日期"],
        "time_zone": ["accounting_time_zone", "accounting timezone", "记账时区"],
        "amount": ["金额(元)", "金额（元）", "金额", "交易金额", "订单金额", "amount"],
        "direction": ["收/支", "收支", "收支类型", "资金流向", "direction", "type", "kind", "entry_type"],
        "category": ["交易分类", "消费分类", "商品类别", "分类", "类别", "category"],
        "category_id": ["category_id", "分类编号"],
        "note": ["商品说明", "商品", "商品名称", "交易对方", "商户", "备注", "note"],
        "status": ["交易状态", "当前状态", "状态", "status"],
        "currency": ["币种", "货币", "currency", "currency_code"],
        "record_id": ["record_id", "entry_id", "id", "记录编号"],
        "source_id": ["source_id", "来源编号", "source key"],
        "source_transaction": ["交易订单号", "交易单号", "流水号", "订单号", "交易编号", "transaction id", "transaction_id"],
        "source_provider": ["平台", "来源平台", "provider", "source provider"],
        "original_entry_id": ["original_entry_id", "原交易编号"],
        "account_id": ["account_id", "账户编号"]
    ]

    static func parse(_ data: Data, existingCategories: [BookCategory], existingAccounts: [BookAccount] = []) throws -> CSVPreview {
        guard data.count <= maximumFileBytes else { throw CounterCSVError.fileTooLarge }
        let content = try decode(data)
        let rows = try records(from: content)
        guard !rows.isEmpty else { throw CounterCSVError.noHeader }
        guard rows.count <= maximumRows else { throw CounterCSVError.fileTooLarge }

        let isCounterFormat = rows.first?.first.map { normalize($0) == "#countercsv" } ?? false
        var counterVersion: Int?
        if isCounterFormat {
            let versionText = rows.first?.dropFirst().first ?? ""
            guard let version = Int(versionText), (1...currentVersion).contains(version) else {
                throw CounterCSVError.unsupportedVersion(Int(rows.first?.dropFirst().first ?? "") ?? 0)
            }
            counterVersion = version
        }

        var headerAt: Int?
        var columns: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let normalized = Dictionary(row.enumerated().map { (normalize($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
            var candidate: [String: Int] = [:]
            for (field, names) in aliases {
                let normalizedNames = Set(names.map(normalize))
                if let hit = normalized.first(where: { normalizedNames.contains($0.key) }) {
                    candidate[field] = hit.value
                }
            }
            if candidate["amount"] != nil && candidate["date"] != nil {
                headerAt = index
                columns = candidate
                break
            }
        }
        guard let headerAt else { throw CounterCSVError.noHeader }
        if isCounterFormat {
            let required = ["record_id", "direction", "category_id", "currency", "source_id", "original_entry_id"]
            let versionTwoRequired = ["local_day", "time_zone"]
            guard required.allSatisfy({ columns[$0] != nil }),
                  (counterVersion == 1 || versionTwoRequired.allSatisfy({ columns[$0] != nil })) else {
                throw CounterCSVError.noHeader
            }
        }

        let fileDigest = CaptureService.digest(data)
        var stagedCategories: [String: BookCategory] = [:]
        var output: [BookEntry] = []
        var errors: [String] = []
        var duplicates = 0
        var conflicts = 0
        var seenIDs: [String: BookEntry] = [:]
        var seenSources: [String: BookEntry] = [:]
        let categoryIndex = Dictionary(existingCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (rowIndex, row) in rows.enumerated() where rowIndex > headerAt {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            func cell(_ name: String) -> String {
                guard let index = columns[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func reject(_ reason: String) {
                errors.append("第 \(rowIndex + 1) 行：\(reason)，已跳过")
            }

            let status = cell("status")
            if !status.isEmpty {
                let normalizedStatus = normalize(status)
                let settled = ["成功", "完成", "已收款", "已支付", "交易成功", "支付成功", "refundsucceeded", "succeeded", "completed"]
                if !settled.contains(where: normalizedStatus.contains) {
                    reject("交易状态“\(status)”未完成")
                    continue
                }
            }

            let currency = normalize(cell("currency"))
            if !currency.isEmpty && !["cny", "rmb", "人民币", "元", "¥", "￥"].contains(currency) {
                reject("币种“\(cell("currency"))”暂不支持，不能按人民币导入")
                continue
            }

            guard let cents = parseCents(cell("amount")), cents > 0 else {
                reject("金额格式无效（仅支持人民币及最多两位小数）")
                continue
            }
            guard let date = parseDate(cell("date")) else {
                reject("日期格式或日期值无效")
                continue
            }
            guard let kind = parseKind(cell("direction"), amount: cell("amount"), status: status) else {
                reject("无法判定收入、支出或退款")
                continue
            }

            let rawCategoryID = cell("category_id")
            let categoryName = isCounterFormat ? decodeFormulaSafe(cell("category")) : cell("category")
            let expectedKind = kind == .income ? "income" : "expense"
            let category: BookCategory
            if !rawCategoryID.isEmpty, let existing = categoryIndex[rawCategoryID] {
                guard existing.kind == expectedKind else {
                    reject("分类“\(existing.name)”与收支类型不匹配")
                    continue
                }
                category = existing
            } else if let mapped = mapCategory(categoryName, kind: kind,
                                               categories: existingCategories + Array(stagedCategories.values)) {
                category = mapped
            } else {
                let safeName = categoryName.isEmpty ? (kind == .income ? "其他收入" : "待分类") : String(categoryName.prefix(30))
                let categoryID: String
                if isCounterFormat, !rawCategoryID.isEmpty, rawCategoryID.count <= 80 {
                    categoryID = rawCategoryID
                } else {
                    categoryID = "import-\(CaptureService.digest(Data("\(expectedKind)|\(safeName)".utf8)).prefix(20))"
                }
                if let collision = categoryIndex[categoryID], collision.kind != expectedKind {
                    reject("分类编号与现有分类冲突")
                    continue
                }
                if let staged = stagedCategories[categoryID] {
                    category = staged
                } else {
                    let created = BookCategory(id: categoryID, name: safeName, kind: expectedKind,
                                               symbol: "custom_category", sortOrder: 999, isActive: true)
                    stagedCategories[categoryID] = created
                    category = created
                }
            }

            let rawSourceID = cell("source_id")
            let transactionID = cell("source_transaction")
            let provider = cell("source_provider")
            let sourceID = !rawSourceID.isEmpty ? rawSourceID :
                (transactionID.isEmpty ? nil : canonicalSourceID(provider: provider, transaction: transactionID, kind: kind))
            let note = isCounterFormat ? decodeFormulaSafe(cell("note")) : cell("note")
            let requestedID = cell("record_id")
            let recordID = requestedID.isEmpty ? "import-\(fileDigest.prefix(24))-\(rowIndex + 1)" : requestedID
            guard recordID.count <= 128 else {
                reject("记录编号长度超出限制")
                continue
            }
            let originalID = cell("original_entry_id")
            let accountID = cell("account_id")
            if !accountID.isEmpty, !existingAccounts.contains(where: { $0.id == accountID }) {
                reject("账户编号“\(accountID)”不存在，请先添加账户或使用完整备份导入")
                continue
            }
            if !accountID.isEmpty, kind == .income,
               existingAccounts.first(where: { $0.id == accountID })?.type.isLiability == true {
                reject("收入不能关联到负债账户")
                continue
            }
            let entry = BookEntry(id: recordID, cents: cents, kind: kind, occurredAt: date,
                                  categoryID: category.id, iconChoice: category.symbol, note: note,
                                  sourceID: sourceID, originalEntryID: originalID.isEmpty ? nil : originalID,
                                  createdAt: Date(), updatedAt: Date(),
                                  localDayKey: normalizedLocalDay(cell("local_day"), for: date),
                                  accountingTimeZone: isCounterFormat ? cell("time_zone") : nil,
                                  currencyCode: currency.isEmpty ? "CNY" : cell("currency"),
                                  accountID: accountID.isEmpty ? nil : accountID)

            if let prior = seenIDs[recordID] {
                if equivalent(prior, entry) { duplicates += 1 }
                else { conflicts += 1; reject("记录编号重复但内容不同") }
                continue
            }
            if let sourceID, let prior = seenSources[sourceID] {
                if equivalent(prior, entry) { duplicates += 1 }
                else { conflicts += 1; reject("来源交易号重复但内容不同") }
                continue
            }
            seenIDs[recordID] = entry
            if let sourceID { seenSources[sourceID] = entry }
            output.append(entry)
        }

        return CSVPreview(records: output, categories: Array(stagedCategories.values).sorted { $0.id < $1.id },
                          rejectedRows: errors, duplicateCount: duplicates, conflictCount: conflicts,
                          sourceDigest: fileDigest,
                          inputRowCount: rows.dropFirst(headerAt + 1).filter { row in
                              !row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                          }.count)
    }

    static func encode(_ entries: [BookEntry], categories: [BookCategory]) -> Data {
        let index = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = [
            ["#counter-csv", String(currentVersion)],
            ["record_id", "kind", "category_id", "category", "amount", "currency", "occurred_at",
             "local_day", "accounting_time_zone", "note", "source_id", "original_entry_id", "account_id"]
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for entry in entries {
            let amount = NSDecimalNumber(decimal: Decimal(entry.cents) / 100).stringValue
            rows.append([entry.id, entry.kind.rawValue, entry.categoryID,
                         index[entry.categoryID]?.name ?? entry.historicalCategory?.name ?? "已停用分类", amount, "CNY",
                         formatter.string(from: entry.occurredAt), entry.stableLocalDayKey,
                         entry.accountingTimeZone ?? "legacy-unknown", entry.note,
                         entry.sourceID ?? "", entry.originalEntryID ?? "", entry.accountID ?? ""])
        }
        let csv = rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(("\u{FEFF}" + csv).utf8)
    }

    static func encodeBackup(_ backup: CounterBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func equivalent(_ lhs: BookEntry, _ rhs: BookEntry) -> Bool {
        lhs.cents == rhs.cents && lhs.kind == rhs.kind && lhs.occurredAt == rhs.occurredAt &&
        lhs.categoryID == rhs.categoryID && lhs.note == rhs.note && lhs.sourceID == rhs.sourceID &&
        lhs.originalEntryID == rhs.originalEntryID && lhs.accountID == rhs.accountID
    }

    private static func canonicalSourceID(provider: String, transaction: String, kind: EntryKind) -> String {
        let parts = [provider.isEmpty ? "unknown" : normalize(provider), transaction.trimmingCharacters(in: .whitespacesAndNewlines), kind.rawValue]
        return "statement:v1:" + parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func normalizedLocalDay(_ value: String, for date: Date) -> String {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let parsed = CounterFormat.date(fromLocalDayKey: value),
              CounterFormat.localDayKey(parsed) == value else { return CounterFormat.localDayKey(date) }
        return value
    }

    private static func parseKind(_ raw: String, amount: String, status: String) -> EntryKind? {
        let value = normalize(raw)
        if let kind = EntryKind(rawValue: value) { return kind }
        if value.contains("退款") || value.contains("退回") || normalize(status).contains("退款") { return .refund }
        if value.contains("支出") || value == "out" || value == "expense" { return .expense }
        if value.contains("收入") || value == "in" || value == "income" { return .income }
        if Decimal(string: amount.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")).map({ $0 < 0 }) == true { return .expense }
        return nil
    }

    private static func parseCents(_ input: String) -> Int64? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("¥") || value.hasPrefix("￥") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              amountPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range == NSRange(value.startIndex..., in: value) else { return nil }
        if value.hasPrefix("+") || value.hasPrefix("-") { value.removeFirst() }
        return CounterMoney.cents(from: value)
    }

    private static func decode(_ data: Data) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8.replacingOccurrences(of: "\u{FEFF}", with: "") }
        for charset in ["GB18030", "GBK", "Big5"] {
            let name = charset as CFString
            let encodingID = CFStringConvertIANACharSetNameToEncoding(name)
            guard encodingID != kCFStringEncodingInvalidId else { continue }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encodingID))
            if let result = String(data: data, encoding: encoding) { return result }
        }
        throw CounterCSVError.unreadable
    }

    private static func records(from text: String) throws -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        let delimiter = detectDelimiter(scalars)
        var result: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var index = 0
        func finishField() {
            row.append(String(field).trimmingCharacters(in: .whitespaces))
            field = String.UnicodeScalarView()
        }
        func finishRow() {
            finishField()
            if !row.allSatisfy({ $0.isEmpty }) { result.append(row) }
            row = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                if quoted, index + 1 < scalars.count, scalars[index + 1] == "\"" {
                    field.append(scalar)
                    index += 1
                } else if quoted {
                    quoted = false
                } else if field.isEmpty {
                    quoted = true
                } else {
                    throw CounterCSVError.malformedCSV
                }
            } else if !quoted, scalar == delimiter {
                finishField()
            } else if !quoted, scalar == "\r" || scalar == "\n" {
                finishRow()
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            } else {
                field.append(scalar)
            }
            index += 1
        }
        guard !quoted else { throw CounterCSVError.malformedCSV }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return result
    }

    private static func detectDelimiter(_ scalars: [UnicodeScalar]) -> UnicodeScalar {
        var counts: [UnicodeScalar: Int] = [",": 0, "\t": 0, ";": 0]
        var quoted = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                if quoted, index + 1 < scalars.count, scalars[index + 1] == "\"" { index += 1 }
                else { quoted.toggle() }
            } else if !quoted, scalar == "\r" || scalar == "\n" {
                break
            } else if !quoted, counts[scalar] != nil {
                counts[scalar, default: 0] += 1
            }
            index += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? ","
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func mapCategory(_ source: String, kind: EntryKind, categories: [BookCategory]) -> BookCategory? {
        guard !source.isEmpty else { return nil }
        let categoryKind = kind == .income ? "income" : "expense"
        let exact = categories.first { $0.kind == categoryKind && $0.name == source }
        if let exact { return exact }
        guard kind != .income else { return nil }
        let expenseAliases: [String: [String]] = [
            "dining": ["餐饮", "美食", "用餐", "餐厅", "外卖", "咖啡", "奶茶"],
            "shopping": ["购物", "服饰", "衣服", "淘宝", "京东"],
            "transport": ["交通", "出行", "地铁", "公交", "打车", "高铁"],
            "daily": ["日用", "生活用品", "日常"], "vegetables": ["蔬菜"],
            "fruit": ["水果"], "snacks": ["零食"], "sports": ["运动"],
            "gifts": ["礼物", "人情", "红包"], "phone": ["通讯", "话费"], "beauty": ["美容"]
        ]
        for (id, aliases) in expenseAliases where aliases.contains(where: source.contains) {
            if let category = categories.first(where: { $0.id == id && $0.kind == categoryKind }) { return category }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let patterns = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm",
                        "yyyy-MM-dd", "yyyy/MM/dd", "yyyy年M月d日 HH:mm:ss", "yyyy年M月d日"]
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.isLenient = false
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func decodeFormulaSafe(_ value: String) -> String {
        guard value.hasPrefix("'"), let next = value.dropFirst().first,
              ["=", "+", "-", "@", "\t", "\r"].contains(next) else { return value }
        let remainder = String(value.dropFirst())
        return Decimal(string: remainder) == nil ? remainder : value
    }

    private static func escape(_ value: String) -> String {
        var safe = value
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["=", "+", "-", "@", "\t", "\r"].contains(where: trimmed.hasPrefix),
           Decimal(string: trimmed) == nil { safe = "'" + value }
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

extension UTType {
    static let counterBackup = UTType(exportedAs: "com.counter.backup")
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.counterBackup, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
