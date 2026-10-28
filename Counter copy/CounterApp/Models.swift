import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CategoryIconArtwork {
    enum ImportError: LocalizedError {
        case invalidPNG
        var errorDescription: String? { "请选择有效的 PNG 图片（最大 25 MB）。" }
    }
    static let maximumBytes = 96 * 1_024
    static let maximumInputBytes = 25 * 1_024 * 1_024

    static func isValidPNGBase64(_ value: String) -> Bool {
        guard value.utf8.count <= ((maximumBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: value), data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...256).contains(width), (1...256).contains(height) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func preparePNG(at url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumInputBytes else { throw ImportError.invalidPNG }
        return try preparePNG(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func preparePNG(_ data: Data) throws -> String {
        guard data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 60_000_000 / height else { throw ImportError.invalidPNG }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 128,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImportError.invalidPNG }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ImportError.invalidPNG }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw ImportError.invalidPNG }
        return (output as Data).base64EncodedString()
    }
}

enum CounterMoney {
    static let maximumCents: Int64 = 9_000_000_000_000_000
    private static let amountPattern = try! NSRegularExpression(pattern: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#)

    static func cents(from rawValue: String, allowZero: Bool = false) -> Int64? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("¥") || value.hasPrefix("￥") { value.removeFirst() }
        guard amountPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range == NSRange(value.startIndex..., in: value) else { return nil }
        value = value.replacingOccurrences(of: ",", with: "")
        guard !value.isEmpty,
              amountPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range == NSRange(value.startIndex..., in: value),
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let scaled = decimal * 100
        guard scaled <= Decimal(maximumCents) else { return nil }
        var rounded = Decimal()
        var candidate = scaled
        NSDecimalRound(&rounded, &candidate, 0, .plain)
        guard rounded == scaled else { return nil }
        let result = NSDecimalNumber(decimal: rounded).int64Value
        return allowZero ? (result >= 0 ? result : nil) : (result > 0 ? result : nil)
    }
}

enum EntryKind: String, CaseIterable, Codable, Identifiable {
    case expense, income, refund
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .refund: "退款"
        }
    }
    /// Multiplier used by the account balance: refunds restore money to the account.
    var cashFlowMultiplier: Int64 { self == .expense ? -1 : 1 }

    /// Multiplier used by category spending: refunds reduce the original spending.
    var spendingMultiplier: Int64 {
        switch self {
        case .expense: 1
        case .income: 0
        case .refund: -1
        }
    }
}

struct BookCategory: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var kind: String
    var symbol: String
    var sortOrder: Int
    var isActive: Bool
    var iconPNGBase64: String? = nil

    // The existing editor has always generated these IDs. Older custom categories
    // therefore remain deletable without guessing from names or icon choices.
    var isUserCreated: Bool { id.hasPrefix("category-") && !Self.defaults.contains { $0.id == id } }

    static let incomeOption = BookCategory(id: "counter-income", name: "收入", kind: "income",
                                           symbol: "other_income", sortOrder: 3, isActive: true)

    static let defaults: [BookCategory] = [
        .init(id: "dining", name: "餐饮", kind: "expense", symbol: "dining", sortOrder: 0, isActive: true),
        .init(id: "shopping", name: "购物", kind: "expense", symbol: "shopping", sortOrder: 1, isActive: true),
        .init(id: "daily", name: "日用", kind: "expense", symbol: "daily", sortOrder: 2, isActive: true),
        .init(id: "transport", name: "交通", kind: "expense", symbol: "transport", sortOrder: 3, isActive: true),
        .init(id: "vegetables", name: "蔬菜", kind: "expense", symbol: "vegetables", sortOrder: 4, isActive: true),
        .init(id: "fruit", name: "水果", kind: "expense", symbol: "fruit", sortOrder: 5, isActive: true),
        .init(id: "snacks", name: "零食", kind: "expense", symbol: "snacks", sortOrder: 6, isActive: true),
        .init(id: "sports", name: "运动", kind: "expense", symbol: "sports", sortOrder: 7, isActive: true),
        .init(id: "gifts", name: "礼物", kind: "expense", symbol: "gifts", sortOrder: 8, isActive: true),
        .init(id: "phone", name: "通讯", kind: "expense", symbol: "phone", sortOrder: 9, isActive: true),
        .init(id: "clothing", name: "服饰", kind: "expense", symbol: "clothing", sortOrder: 10, isActive: true),
        .init(id: "beauty", name: "美容", kind: "expense", symbol: "beauty", sortOrder: 11, isActive: true),
        .init(id: "salary", name: "工资", kind: "income", symbol: "salary", sortOrder: 0, isActive: true),
        .init(id: "bonus", name: "奖金", kind: "income", symbol: "bonus", sortOrder: 1, isActive: true),
        .init(id: "other_income", name: "其他", kind: "income", symbol: "other_income", sortOrder: 2, isActive: true),
        incomeOption
    ]
}

enum AccountType: String, CaseIterable, Codable, Identifiable {
    case cash, debitCard, eWallet, investment, otherAsset, creditCard, loan, otherDebt

    var id: String { rawValue }
    var accountDisplayName: String {
        switch self {
        case .debitCard: "借记卡"
        case .creditCard: "信用卡"
        default: title
        }
    }
    var title: String {
        switch self {
        case .cash: "现金"
        case .debitCard: "借记卡"
        case .eWallet: "电子钱包"
        case .investment: "投资账户"
        case .otherAsset: "其他账户"
        case .creditCard: "信用卡"
        case .loan: "贷款"
        case .otherDebt: "其他负债"
        }
    }
    var symbol: String {
        switch self {
        case .cash: "banknote"
        case .debitCard: "creditcard"
        case .eWallet: "wallet.pass"
        case .investment: "chart.line.uptrend.xyaxis"
        case .otherAsset: "square.grid.2x2"
        case .creditCard: "creditcard.fill"
        case .loan: "building.columns"
        case .otherDebt: "ellipsis.circle"
        }
    }
    var isLiability: Bool { self == .creditCard || self == .loan || self == .otherDebt }
    static var assets: [AccountType] { [.cash, .debitCard, .eWallet, .investment, .otherAsset] }
    static var liabilities: [AccountType] { [.creditCard, .loan, .otherDebt] }
}

enum AccountBrand: String, CaseIterable, Identifiable {
    case alipay, wechat, unionpay, jdFinance, huabei
    case cmb, boc, abc, icbc, ccb, bocom

    var id: String { rawValue }
    var assetName: String {
        switch self {
        case .jdFinance: "brand_jd_finance"
        default: "brand_\(rawValue)"
        }
    }
    var canonicalName: String {
        switch self {
        case .alipay: "支付宝"
        case .wechat: "微信"
        case .unionpay: "云闪付"
        case .jdFinance: "京东金融"
        case .huabei: "花呗"
        case .cmb: "招商银行"
        case .boc: "中国银行"
        case .abc: "中国农业银行"
        case .icbc: "中国工商银行"
        case .ccb: "中国建设银行"
        case .bocom: "交通银行"
        }
    }

    var isWallet: Bool { [.alipay, .wechat, .unionpay, .jdFinance].contains(self) }
    var presentsAsPaymentBrand: Bool { isWallet || self == .huabei }

    private var aliases: [String] {
        switch self {
        case .alipay: ["支付宝", "alipay"]
        case .wechat: ["微信支付", "微信零钱", "微信", "wechat", "weixin"]
        case .unionpay: ["云闪付", "银联", "unionpay", "chinaunionpay"]
        case .jdFinance: ["京东金融", "京东", "jdfinance", "jd.com"]
        case .huabei: ["花呗", "huabei", "ant credit pay"]
        case .cmb: ["招商银行", "招行", "chinamerchantsbank", "cmb"]
        case .boc: ["中国银行", "bankofchina", "boc"]
        case .abc: ["中国农业银行", "农业银行", "农行", "agriculturalbankofchina", "abc"]
        case .icbc: ["中国工商银行", "工商银行", "工行", "industrialandcommercialbankofchina", "icbc"]
        case .ccb: ["中国建设银行", "建设银行", "建行", "china construction bank", "ccb"]
        case .bocom: ["交通银行", "交行", "bankofcommunications", "bocom"]
        }
    }

    static func resolve(providerName: String?, accountName: String?) -> AccountBrand? {
        // Check the institution field first so user-defined card nicknames never decide the brand.
        for value in [providerName, accountName].compactMap({ $0 }) {
            let normalized = normalize(value)
            guard !normalized.isEmpty else { continue }
            for brand in [AccountBrand.bocom, .icbc, .abc, .ccb, .cmb, .boc, .huabei, .alipay, .wechat, .unionpay, .jdFinance] {
                if brand.aliases.contains(where: { alias in
                    let key = normalize(alias)
                    guard !key.isEmpty else { return false }
                    if key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.").contains($0) }) {
                        return normalized == key || normalized.hasPrefix(key)
                    }
                    return normalized.contains(key)
                }) { return brand }
            }
        }
        return nil
    }

    func isLegacyDefaultAccountName(_ name: String, type: AccountType) -> Bool {
        let value = Self.normalize(name)
        guard !value.isEmpty else { return false }
        if isWallet {
            let accepted: [String] = switch self {
            case .alipay: ["支付宝", "支付宝余额"]
            case .wechat: ["微信", "微信支付", "微信零钱"]
            case .unionpay: ["云闪付", "云闪付余额", "银联云闪付"]
            case .jdFinance: ["京东金融", "京东金融余额"]
            default: []
            }
            return accepted.contains { Self.normalize($0) == value }
        }

        let cardDefaults = ["", "卡", "银行卡", "借记卡", "储蓄卡", "信用卡"]
        if cardDefaults.contains(value) { return true }
        for alias in aliases where !alias.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let key = Self.normalize(alias)
            if value.hasPrefix(key), cardDefaults.contains(String(value.dropFirst(key.count))) { return true }
        }
        // Also normalize the short historical names created by the account presets.
        let presetDefaults: [String]
        switch self {
        case .cmb: presetDefaults = ["招商银行卡", "招行卡"]
        case .boc: presetDefaults = ["中国银行卡", "中行卡"]
        case .abc: presetDefaults = ["农业银行卡", "农行卡"]
        case .icbc: presetDefaults = ["工商银行卡", "工行卡"]
        case .ccb: presetDefaults = ["建设银行卡", "建行卡"]
        case .bocom: presetDefaults = ["交通银行卡", "交行卡"]
        default: presetDefaults = []
        }
        return presetDefaults.contains { Self.normalize($0) == value }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }
}

enum AccountCardIcon: String, CaseIterable, Codable, Identifiable {
    case card, bank, wallet, cash, fund, investment, savings, home, car, travel, shopping, work, gift, star, leaf, phone, chart
    case alipay, wechat, unionpay, jdFinance, huabei, cmb, boc, abc, icbc, ccb, bocom

    var id: String { rawValue }
    var assetName: String? { AccountBrand(rawValue: rawValue)?.assetName }
    static var genericIcons: [AccountCardIcon] { allCases.filter { $0.assetName == nil } }
    static var brandIcons: [AccountCardIcon] { allCases.filter { $0.assetName != nil } }
    var title: String {
        if let brand = AccountBrand(rawValue: rawValue) { return brand.canonicalName }
        switch self {
        case .alipay, .wechat, .unionpay, .jdFinance, .huabei, .cmb, .boc, .abc, .icbc, .ccb, .bocom: return "账户"
        case .fund: return "基金"
        case .investment: return "投资"
        case .savings: return "余额宝 / 储蓄"
        case .card: return "卡片"
        case .bank: return "银行"
        case .wallet: return "钱包"
        case .cash: return "现金"
        case .home: return "住房"
        case .car: return "汽车"
        case .travel: return "旅行"
        case .shopping: return "购物"
        case .work: return "工作"
        case .gift: return "礼物"
        case .star: return "收藏"
        case .leaf: return "生活"
        case .phone: return "手机"
        case .chart: return "储蓄"
        }
    }
    var symbol: String {
        switch self {
        case .alipay, .wechat, .unionpay, .jdFinance, .huabei, .cmb, .boc, .abc, .icbc, .ccb, .bocom: return "creditcard.fill"
        case .fund: return "chart.pie.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .savings: return "leaf.circle.fill"
        case .card: return "creditcard.fill"
        case .bank: return "building.columns.fill"
        case .wallet: return "wallet.pass.fill"
        case .cash: return "banknote.fill"
        case .home: return "house.fill"
        case .car: return "car.fill"
        case .travel: return "airplane"
        case .shopping: return "bag.fill"
        case .work: return "briefcase.fill"
        case .gift: return "gift.fill"
        case .star: return "star.fill"
        case .leaf: return "leaf.fill"
        case .phone: return "iphone"
        case .chart: return "chart.bar.fill"
        }
    }

    static func defaultIcon(for type: AccountType) -> AccountCardIcon {
        switch type {
        case .cash: .cash
        case .debitCard, .creditCard: .card
        case .eWallet: .wallet
        case .investment: .fund
        case .otherAsset: .star
        case .loan: .bank
        case .otherDebt: .home
        }
    }
}

enum AccountCardColor: String, CaseIterable, Codable, Identifiable {
    case midnight, ocean, plum, forest, ruby, copper, teal, graphite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .midnight: "深蓝"
        case .ocean: "海蓝"
        case .plum: "梅紫"
        case .forest: "森林"
        case .ruby: "莓红"
        case .copper: "暖棕"
        case .teal: "青绿"
        case .graphite: "石墨"
        }
    }
    var hex: String {
        switch self {
        case .midnight: "26334E"
        case .ocean: "176985"
        case .plum: "68477F"
        case .forest: "286A55"
        case .ruby: "984656"
        case .copper: "8A563C"
        case .teal: "236B70"
        case .graphite: "3D4652"
        }
    }

    static func defaultColor(for type: AccountType) -> AccountCardColor {
        switch type {
        case .cash: .forest
        case .debitCard: .ocean
        case .eWallet: .plum
        case .investment: .teal
        case .otherAsset: .graphite
        case .creditCard: .midnight
        case .loan: .graphite
        case .otherDebt: .copper
        }
    }
}

enum AccountCardArtwork {
    static let maximumBytes = 96 * 1_024
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func isValidPNGBase64(_ value: String) -> Bool {
        guard value.utf8.count <= ((maximumBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: value), data.count <= maximumBytes else { return false }
        return data.prefix(pngSignature.count).elementsEqual(pngSignature)
    }
}

struct BookAccount: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var type: AccountType
    /// Opening amount at the point this account was added. For liabilities, this is the amount owed.
    var openingBalanceCents: Int64
    /// Signed correction used when a manually reconciled balance is below historical net activity.
    var balanceAdjustmentCents: Int64? = nil
    var cardLabelOverride: String? = nil
    var cardIcon: AccountCardIcon? = nil
    /// Explicit choice independent of institution and accounting type. Nil retains legacy automatic branding.
    var cardIconOverride: AccountCardIcon? = nil
    var cardColor: AccountCardColor? = nil
    var cardIconPNGBase64: String? = nil
    var providerName: String? = nil
    var creditLimitCents: Int64? = nil
    var dueAmountCents: Int64? = nil
    /// Legacy full date retained for backup compatibility; new saves use repaymentDay.
    var nextDueDate: Date? = nil
    var repaymentDay: Int? = nil
    var repaymentReminderEnabled: Bool? = nil
    var isActive: Bool = true
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var effectiveRepaymentDay: Int? {
        let day = repaymentDay ?? nextDueDate.map { Calendar.current.component(.day, from: $0) }
        return day.flatMap { (1...31).contains($0) ? $0 : nil }
    }
    var repaymentReminderIsEnabled: Bool { repaymentReminderEnabled ?? (nextDueDate != nil) }
    var upcomingRepaymentDate: Date? {
        guard let day = effectiveRepaymentDay else { return nil }
        return MonthlyRepaymentDate.next(day: day)
    }

    var brand: AccountBrand? { AccountBrand.resolve(providerName: providerName, accountName: name) }
    var brandIcon: String? {
        if hasValidCardIconPNG { return nil }
        if let cardIconOverride { return cardIconOverride.assetName }
        return brand?.assetName
    }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Old custom creation put the user's name in the institution field.
        let provider = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed == "自定义账户" && !provider.isEmpty ? provider : trimmed
    }

    var displayTypeLabel: String {
        let custom = cardLabelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? type.title : custom
    }
    var displayProviderName: String {
        let provider = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provider.isEmpty ? type.title : provider
    }
    var displayCardIcon: AccountCardIcon { cardIconOverride ?? cardIcon ?? AccountCardIcon.defaultIcon(for: type) }
    var displayCardColor: AccountCardColor { cardColor ?? AccountCardColor.defaultColor(for: type) }
    var hasValidCardIconPNG: Bool { cardIconPNGBase64.map(AccountCardArtwork.isValidPNGBase64) ?? false }
}

enum MonthlyRepaymentDate {
    static func next(day: Int, after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard (1...31).contains(day), let start = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
        for offset in 0...1 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: start),
                  let days = calendar.range(of: .day, in: .month, for: month),
                  let date = calendar.date(byAdding: .day, value: min(day, days.count) - 1, to: month) else { continue }
            if date >= calendar.startOfDay(for: now) { return date }
        }
        return nil
    }
}

struct AccountTransfer: Identifiable, Codable, Hashable {
    var id: String
    var cents: Int64
    var fromAccountID: String
    var toAccountID: String
    var occurredAt: Date
    var note: String = ""
    var dueAmountReductionCents: Int64 = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: String, cents: Int64, fromAccountID: String, toAccountID: String,
         occurredAt: Date, note: String = "", dueAmountReductionCents: Int64 = 0,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.cents = cents
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.occurredAt = occurredAt
        self.note = note
        self.dueAmountReductionCents = dueAmountReductionCents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, cents, fromAccountID, toAccountID, occurredAt, note
        case dueAmountReductionCents, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        cents = try values.decode(Int64.self, forKey: .cents)
        fromAccountID = try values.decode(String.self, forKey: .fromAccountID)
        toAccountID = try values.decode(String.self, forKey: .toAccountID)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        dueAmountReductionCents = try values.decodeIfPresent(Int64.self, forKey: .dueAmountReductionCents) ?? 0
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? occurredAt
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(cents, forKey: .cents)
        try values.encode(fromAccountID, forKey: .fromAccountID)
        try values.encode(toAccountID, forKey: .toAccountID)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(note, forKey: .note)
        try values.encode(dueAmountReductionCents, forKey: .dueAmountReductionCents)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AccountOverview {
    var accounts: [BookAccount]
    var balances: [String: Int64]
    var transfers: [AccountTransfer]

    var assetsCents: Int64 {
        accounts.filter { !$0.type.isLiability && $0.isActive }
            .reduce(0) { LedgerMath.add($0, balances[$1.id] ?? LedgerMath.add($1.openingBalanceCents, $1.balanceAdjustmentCents ?? 0)) }
    }
    var liabilitiesCents: Int64 {
        accounts.filter { $0.type.isLiability && $0.isActive }
            .reduce(0) { LedgerMath.add($0, balances[$1.id] ?? LedgerMath.add($1.openingBalanceCents, $1.balanceAdjustmentCents ?? 0)) }
    }
    var netWorthCents: Int64 { LedgerMath.subtract(assetsCents, liabilitiesCents) }
}

enum AccountLedgerMath {
    /// Asset balances and outstanding debt are both represented as signed, user-facing amounts.
    static func balances(accounts: [BookAccount], entries: [BookEntry], transfers: [AccountTransfer]) -> [String: Int64] {
        var result = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, LedgerMath.add($0.openingBalanceCents, $0.balanceAdjustmentCents ?? 0))
        })
        for entry in entries {
            guard let accountID = entry.accountID, let account = accounts.first(where: { $0.id == accountID }) else { continue }
            let delta: Int64
            if account.type.isLiability {
                delta = entry.kind == .expense ? entry.cents : (entry.kind == .refund ? -entry.cents : 0)
            } else {
                delta = entry.signedCents
            }
            result[accountID] = LedgerMath.add(result[accountID, default: 0], delta)
        }
        for transfer in transfers {
            guard let source = accounts.first(where: { $0.id == transfer.fromAccountID }),
                  let destination = accounts.first(where: { $0.id == transfer.toAccountID }) else { continue }
            result[source.id] = source.type.isLiability
                ? LedgerMath.add(result[source.id, default: 0], transfer.cents)
                : LedgerMath.subtract(result[source.id, default: 0], transfer.cents)
            result[destination.id] = destination.type.isLiability
                ? LedgerMath.subtract(result[destination.id, default: 0], transfer.cents)
                : LedgerMath.add(result[destination.id, default: 0], transfer.cents)
        }
        return result
    }
}

struct BookEntry: Identifiable, Codable, Hashable {
    var id: String
    var cents: Int64
    var kind: EntryKind
    var occurredAt: Date
    var categoryID: String
    var iconChoice: String
    var note: String
    var sourceID: String?
    var originalEntryID: String?
    var createdAt: Date
    var updatedAt: Date
    var localDayKey: String? = nil
    var accountingTimeZone: String? = nil
    var currencyCode: String? = nil
    var recordVersion: Int64? = nil
    var importBatchID: String? = nil
    var confirmedDraftID: String? = nil
    var accountID: String? = nil
    var categorySnapshot: BookCategory? = nil

    func resolvedCategory(in categories: [BookCategory]) -> BookCategory? {
        categories.first { $0.id == categoryID } ?? historicalCategory
    }

    var historicalCategory: BookCategory? {
        guard let categorySnapshot, categorySnapshot.id == categoryID,
              categorySnapshot.kind == (kind == .income ? "income" : "expense"),
              !categorySnapshot.name.isEmpty else { return nil }
        return categorySnapshot
    }

    var stableLocalDayKey: String { localDayKey ?? CounterFormat.localDayKey(occurredAt) }
    var localDay: Date { CounterFormat.date(fromLocalDayKey: stableLocalDayKey) ?? Calendar.current.startOfDay(for: occurredAt) }
    var monthStart: Date {
        let parts = Calendar.current.dateComponents([.year, .month], from: localDay)
        return Calendar.current.date(from: parts) ?? occurredAt
    }
    var signedCents: Int64 { kind.cashFlowMultiplier * cents }
}

enum ReviewState: String, Codable, CaseIterable, Identifiable {
    case queued, recognizing, needsReview, failed, confirmed, dismissed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .queued: "待识别"
        case .recognizing: "识别中"
        case .needsReview: "待确认"
        case .failed: "识别失败，可重试"
        case .confirmed: "已入账"
        case .dismissed: "已忽略"
        }
    }
}

struct ReviewDraft: Identifiable, Codable, Hashable {
    var id: String
    var state: ReviewState
    var cents: Int64?
    var kind: EntryKind?
    var occurredAt: Date
    var categoryID: String?
    var note: String
    var imagePath: String?
    var recognizedText: String
    var sourceID: String?
    var errorText: String?
    var createdAt: Date
    var updatedAt: Date? = nil
    var recordVersion: Int64? = nil
    var confirmedEntryID: String? = nil
    var userConfirmedFields: Set<String>? = nil
    var claimToken: String? = nil
    var claimExpiresAt: Date? = nil
    var inputDigest: String? = nil
    var candidateConfidence: [String: Double]? = nil
    var amountText: String? = nil
}

struct CounterPendingIntent: Codable, Hashable, Identifiable {
    var id: String
    var action: String
    var amount: String?
    var kind: EntryKind?
    var occurredAt: Date?
    var note: String?
    var createdAt: Date

    init(id: String = UUID().uuidString.lowercased(), action: String = "compose",
         amount: String? = nil, kind: EntryKind? = nil, occurredAt: Date? = nil,
         note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.amount = amount
        self.kind = kind
        self.occurredAt = occurredAt
        self.note = note
        self.createdAt = createdAt
    }
}

enum CounterIntentQueue {
    private static let lock = NSLock()
    private static let key = "counter.pending.intent.requests"
    private static let capacity = 64

    static func enqueue(_ request: CounterPendingIntent, in defaults: UserDefaults) throws {
        lock.lock(); defer { lock.unlock() }
        var requests = decode(defaults.data(forKey: key)) ?? []
        guard !requests.contains(where: { $0.id == request.id }) else { return }
        guard requests.count < capacity else { throw CounterIntentQueueError.full }
        requests.append(request)
        defaults.set(try JSONEncoder().encode(requests), forKey: key)
    }

    static func takeNext(from defaults: UserDefaults) -> CounterPendingIntent? {
        lock.lock(); defer { lock.unlock() }
        guard var requests = decode(defaults.data(forKey: key)), !requests.isEmpty else { return nil }
        let request = requests.removeFirst()
        if requests.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: key) }
        return request
    }

    static func hasPending(in defaults: UserDefaults) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(decode(defaults.data(forKey: key)) ?? []).isEmpty
    }

    private static func decode(_ data: Data?) -> [CounterPendingIntent]? {
        guard let data else { return [] }
        return try? JSONDecoder().decode([CounterPendingIntent].self, from: data)
    }
}

enum CounterIntentQueueError: LocalizedError {
    case full
    var errorDescription: String? { "快捷记账请求已满，请先打开 Counter 处理已有请求" }
}

struct CategorySpend: Identifiable, Hashable {
    var category: BookCategory
    var cents: Int64
    var id: String { category.id }
}

struct LedgerSnapshot {
    var monthKey: String
    var entries: [BookEntry]
    var categories: [BookCategory]
    var drafts: [ReviewDraft]

    var summary: MonthSummary { LedgerMath.summary(entries) }
    var spending: [CategorySpend] { LedgerMath.categorySpending(entries, categories: categories) }
}

enum LedgerMath {
    static func summary(_ entries: [BookEntry]) -> MonthSummary {
        entries.reduce(into: MonthSummary()) { result, entry in
            switch entry.kind {
            case .expense: result.expenses = add(result.expenses, entry.cents)
            case .income: result.income = add(result.income, entry.cents)
            case .refund: result.refunds = add(result.refunds, entry.cents)
            }
        }
    }

    static func categorySpending(_ entries: [BookEntry], categories: [BookCategory]) -> [CategorySpend] {
        var amounts: [String: Int64] = [:]
        for entry in entries where entry.kind != .income {
            amounts[entry.categoryID] = add(amounts[entry.categoryID, default: 0], entry.cents * entry.kind.spendingMultiplier)
        }
        var index = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries where index[entry.categoryID] == nil {
            index[entry.categoryID] = entry.historicalCategory
        }
        return amounts.compactMap { id, amount in
            guard let category = index[id], category.kind == "expense" else { return nil }
            return CategorySpend(category: category, cents: amount)
        }.sorted { $0.cents == $1.cents ? $0.id < $1.id : $0.cents > $1.cents }
    }

    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? .max : .min) : value
    }

    static func subtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? .min : .max) : value
    }
}

struct MonthSummary {
    var income: Int64 = 0
    var expenses: Int64 = 0
    var refunds: Int64 = 0
    var netExpenses: Int64 {
        let (value, overflow) = expenses.subtractingReportingOverflow(refunds)
        return overflow ? .min : value
    }
    var netCents: Int64 {
        let (value, overflow) = income.subtractingReportingOverflow(netExpenses)
        return overflow ? (netExpenses < 0 ? .max : .min) : value
    }
}

enum CounterFormat {
    static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func amount(_ cents: Int64, currency: String = "¥") -> String {
        let number = Double(cents) / 100
        return currency + (money.string(from: NSNumber(value: number)) ?? "0.00")
    }

    static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM月dd日 EEEE"
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年 M月"
        return f.string(from: date)
    }

    static func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(fromLocalDayKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: key) else { return nil }
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        parts.hour = 12
        return Calendar.current.date(from: parts)
    }
}

enum CaptureInput: Codable {
    case image(path: String, identity: String)
    case text(value: String, identity: String)
}

struct CounterBackup: Codable {
    var format = "counter-backup"
    var version = 1
    var exportedAt = Date()
    var categories: [BookCategory]
    var entries: [BookEntry]
    var drafts: [ReviewDraft]
    var media: [String: Data] = [:]
    var importBatches: [ImportBatch]? = nil
    var mediaDigests: [String: String]? = nil
    var accounts: [BookAccount]? = nil
    var transfers: [AccountTransfer]? = nil
}

struct ImportBatch: Codable, Hashable, Identifiable {
    var id: String
    var sourceDigest: String
    var createdAt: Date
    var updatedAt: Date
    var inputRows: Int
    var inserted: Int
    var duplicates: Int
    var conflicts: Int
    var invalid: Int
    var cursor: Int
    var state: String
    var undoConflicts: Int

    var isComplete: Bool { state == "completed" || state == "completedWithConflicts" || state == "undone" }
}

struct ImportUndoResult {
    var deleted: Int
    var conflicts: Int
}

struct BackupRecoveryPoint: Identifiable, Hashable {
    var filename: String
    var date: Date
    var sizeBytes: Int64
    var id: String { filename }
}

struct CounterRestorePreview: Hashable {
    var newEntries: Int
    var exactEntries: Int
    var conflictingEntries: Int
    var newDrafts: Int
    var exactDrafts: Int
    var conflictingDrafts: Int
    var newCategories: Int
    var conflictingCategories: Int
    var conflictingBatches: Int
    var newAccounts: Int = 0
    var conflictingAccounts: Int = 0
    var newTransfers: Int = 0
    var conflictingTransfers: Int = 0
    var imageCount: Int
    var imageBytes: Int
    var conflicts: [String]

    var canMerge: Bool {
        conflictingEntries + conflictingDrafts + conflictingCategories + conflictingBatches + conflictingAccounts + conflictingTransfers == 0
    }
}
