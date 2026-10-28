import Foundation
import CryptoKit
import Vision

enum CaptureService {
    static let appGroup = "group.com.counter.app"

    static var sharedInbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("CounterInbox", isDirectory: true)
    }

    static var reviewImages: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counter/ReviewImages", isDirectory: true)
    }

    static func enqueueImage(_ data: Data, fileExtension _: String) throws {
        guard let inbox = sharedInbox else { throw StoreError.database("无法保存截图输入") }
        let id = UUID().uuidString.lowercased()
        try SharedInboxItem.persist(data, id: id, kind: "image", in: inbox)
    }

    static func makeDraft(from url: URL, store: LocalStore) async throws -> ReviewDraft {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        let identity = digest(bytes)
        let sourceID = "image:\(identity)"
        var pending = try await store.draft(sourceID: sourceID)
        if let pending {
            switch pending.state {
            case .needsReview, .failed, .confirmed, .dismissed:
                return pending
            case .recognizing where (pending.claimExpiresAt ?? .distantPast) > Date():
                return pending
            case .queued, .recognizing:
                break
            }
        }

        try FileManager.default.createDirectory(at: reviewImages, withIntermediateDirectories: true)
        let id = pending?.id ?? UUID().uuidString.lowercased()
        let imageURL: URL
        if let path = pending?.imagePath, FileManager.default.fileExists(atPath: path) {
            imageURL = URL(fileURLWithPath: path)
        } else {
            let detectedExtension = SharedInboxItem.imageExtension(for: bytes)
            let extensionValue = (detectedExtension == "img" ? url.pathExtension : detectedExtension)
                .lowercased().filter(\.isASCII).filter { $0.isLetter || $0.isNumber }
            imageURL = reviewImages.appendingPathComponent("\(id).\(extensionValue.isEmpty ? "img" : extensionValue)")
            try bytes.write(to: imageURL, options: .atomic)
        }
        if pending == nil {
            pending = try await store.save(ReviewDraft(id: id, state: .queued, cents: nil, kind: nil,
                                                       occurredAt: Date(), categoryID: nil, note: "",
                                                       imagePath: imageURL.path, recognizedText: "",
                                                       sourceID: sourceID, errorText: nil, createdAt: Date(),
                                                       inputDigest: identity))
        } else if pending?.imagePath != imageURL.path {
            var repaired = pending!
            repaired.imagePath = imageURL.path
            repaired.inputDigest = identity
            pending = try await store.save(repaired)
        }
        guard let pending else { throw StoreError.missingDraft }
        return try await recognize(pending, store: store)
    }

    static func makeDraft(fromText text: String, identity: String, store: LocalStore) async throws -> ReviewDraft {
        let sourceID = "text:\(identity)"
        if let prior = try await store.draft(sourceID: sourceID) { return prior }
        var draft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .needsReview,
                                cents: nil, kind: nil, occurredAt: Date(), categoryID: nil,
                                note: "", imagePath: nil, recognizedText: text,
                                sourceID: sourceID, errorText: nil, createdAt: Date())
        let categories = (try? await store.allCategories()) ?? BookCategory.defaults
        apply(suggest(from: text, categories: categories), to: &draft)
        draft = try await store.save(draft)
        return draft
    }

    static func retry(_ input: URL) async throws -> String { try await recognize(input) }

    static func recognize(_ draft: ReviewDraft, store: LocalStore) async throws -> ReviewDraft {
        guard let claimed = try await store.claimRecognition(id: draft.id) else {
            return try await store.draft(id: draft.id) ?? draft
        }
        guard let token = claimed.claimToken, let path = claimed.imagePath else { throw StoreError.missingDraft }
        await CounterActivityController.show(claimed, category: nil)
        do {
            let text = try await recognize(URL(fileURLWithPath: path))
            let categories = (try? await store.allCategories()) ?? BookCategory.defaults
            let suggestion = suggest(from: text, categories: categories)
            guard var latest = try await store.draft(id: draft.id), latest.claimToken == token else {
                return try await store.draft(id: draft.id) ?? claimed
            }
            latest.recognizedText = text
            apply(suggestion, to: &latest)
            latest.state = .needsReview
            latest.errorText = nil
            latest.claimToken = nil
            latest.claimExpiresAt = nil
            return try await store.save(latest)
        } catch {
            guard var latest = try await store.draft(id: draft.id), latest.claimToken == token else {
                return try await store.draft(id: draft.id) ?? claimed
            }
            latest.state = .failed
            latest.errorText = error.localizedDescription
            latest.claimToken = nil
            latest.claimExpiresAt = nil
            return try await store.save(latest)
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func recognize(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    struct Suggestion {
        var cents: Int64?
        var kind: EntryKind?
        var date: Date?
        var categoryID: String?
        var merchant: String
        var confidence: [String: Double]
    }

    static func suggest(from text: String, categories: [BookCategory] = BookCategory.defaults) -> Suggestion {
        let pattern = #"(实付金额|实付款|实付|支付金额|付款金额|消费金额|交易金额|收款金额|订单金额|(?<!优惠)(?<!折扣)(?<!退款)金额|合计)\s*[:：]?\s*[¥￥]?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"#
        let candidates: [(cents: Int64, score: Double)] = (try? NSRegularExpression(pattern: pattern))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let labelRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text),
                      let cents = CounterMoney.cents(from: String(text[valueRange])) else { return nil }
                let label = String(text[labelRange])
                let score: Double = ["实付金额", "实付款", "实付"].contains(label) ? 1.0
                    : ["支付金额", "付款金额", "消费金额", "交易金额", "收款金额"].contains(label) ? 0.78
                    : label == "订单金额" ? 0.35 : 0.52
                return (cents, score)
            } ?? []
        let bestScore = candidates.map(\.score).max()
        let leadingCandidates = candidates.filter { $0.score == bestScore }
        let leadingValues = Set(leadingCandidates.map(\.cents))
        let cents = leadingValues.count == 1 ? leadingValues.first : nil

        let kind: EntryKind? = {
            if text.contains("退款") || text.contains("退回") { return .refund }
            if text.contains("收入") || text.contains("收款成功") || text.contains("已收款") { return .income }
            if text.contains("支出") || text.contains("付款成功") || text.contains("支付成功") || text.contains("已支付") { return .expense }
            return nil
        }()
        let date = parsedDate(in: text)
        let expectedKind = kind == .income ? "income" : "expense"
        let category = categories.filter { $0.isActive && $0.kind == expectedKind }
            .first { category in
                ([category.name] + categoryKeywords[category.id, default: []])
                    .contains(where: { text.localizedCaseInsensitiveContains($0) })
            }
        let excludedMerchantLabels = ["金额", "时间", "付款成功", "支付成功", "交易成功", "收款成功"]
        let dateLine = try? NSRegularExpression(pattern: #"^\s*20\d{2}[-年/.]\d{1,2}[-月/.]\d{1,2}"#)
        let merchant = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { line in
                !line.isEmpty && line.count < 48 && !excludedMerchantLabels.contains(where: { label in line.contains(label) })
                    && dateLine?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
            }) ?? ""
        var confidence: [String: Double] = [:]
        if let bestScore { confidence["amount"] = leadingValues.count == 1 ? bestScore : 0.15 }
        if kind != nil { confidence["kind"] = 0.85 }
        if date != nil { confidence["occurredAt"] = 0.82 }
        if category != nil { confidence["categoryID"] = 0.62 }
        if !merchant.isEmpty { confidence["note"] = 0.5 }
        return Suggestion(cents: cents, kind: kind, date: date, categoryID: category?.id,
                          merchant: merchant, confidence: confidence)
    }

    private static let categoryKeywords: [String: [String]] = [
        "dining": ["餐饮", "外卖", "咖啡", "奶茶", "餐厅", "美团", "饿了么"],
        "shopping": ["购物", "淘宝", "天猫", "京东", "拼多多"],
        "daily": ["日用", "超市", "便利店", "生活用品"],
        "transport": ["交通", "地铁", "公交", "打车", "滴滴", "加油"],
        "vegetables": ["蔬菜", "菜场", "菜市场"], "fruit": ["水果"],
        "snacks": ["零食", "小吃"], "sports": ["运动", "健身"],
        "gifts": ["礼物", "礼品"], "phone": ["通讯", "话费", "流量"],
        "clothing": ["服饰", "衣服", "鞋"], "beauty": ["美容", "护肤", "美妆"],
        "salary": ["工资", "薪资"], "bonus": ["奖金"]
    ]

    private static func parsedDate(in text: String) -> Date? {
        let pattern = #"(20\d{2})[-年/.](\d{1,2})[-月/.](\d{1,2})(?:日)?(?:[ T]*(\d{1,2}):(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let yearRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let year = Int(text[yearRange]), let month = Int(text[monthRange]), let day = Int(text[dayRange]) else { return nil }
        let hour = match.range(at: 4).location == NSNotFound ? 12 : Range(match.range(at: 4), in: text).flatMap { Int(text[$0]) }
        let minute = match.range(at: 5).location == NSNotFound ? 0 : Range(match.range(at: 5), in: text).flatMap { Int(text[$0]) }
        guard let hour, let minute, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute else { return nil }
        return date
    }

    static func apply(_ suggestion: Suggestion, to draft: inout ReviewDraft) {
        let confirmed = draft.userConfirmedFields ?? []
        if !confirmed.contains("amount"), let cents = suggestion.cents { draft.cents = cents }
        if !confirmed.contains("kind"), let kind = suggestion.kind { draft.kind = kind }
        if !confirmed.contains("occurredAt"), let date = suggestion.date { draft.occurredAt = date }
        if !confirmed.contains("categoryID"), let categoryID = suggestion.categoryID { draft.categoryID = categoryID }
        if !confirmed.contains("note"), !suggestion.merchant.isEmpty { draft.note = suggestion.merchant }
        draft.candidateConfidence = suggestion.confidence
    }
}
