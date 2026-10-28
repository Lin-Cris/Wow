import AppIntents
import Foundation
import UniformTypeIdentifiers

public struct CounterQuickEntryIntent: AppIntent {
    public static var title: LocalizedStringResource = "记一笔"
    public static var description = IntentDescription("打开 Counter 新建一笔账单")
    public static var openAppWhenRun = true

    @Parameter(title: "金额（元）") public var amount: String?
    @Parameter(title: "类型（支出/收入）") public var entryType: String?
    @Parameter(title: "日期") public var occurredAt: Date?
    @Parameter(title: "备注") public var note: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let defaults = UserDefaults(suiteName: CaptureService.appGroup) else {
            throw StoreError.database("Counter 快捷指令暂时无法保存请求")
        }
        let kind: EntryKind? = switch entryType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "income", "收入": .income
        case "expense", "支出": .expense
        case "refund", "退款": .refund
        default: nil
        }
        let request = CounterPendingIntent(amount: amount, kind: kind,
                                           occurredAt: occurredAt, note: note)
        do { try CounterIntentQueue.enqueue(request, in: defaults) }
        catch { throw error }
        return .result()
    }
}

public struct CounterImageDraftIntent: AppIntent {
    public static var title: LocalizedStringResource = "从图片生成待记账"
    public static var description = IntentDescription("在本机识别一张账单截图并交给你核对")
    public static var openAppWhenRun = true

    @Parameter(title: "收据或付款截图") public var screenshot: IntentFile

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard screenshot.type?.conforms(to: .image) ?? false else {
            throw StoreError.database("请提供图片格式的账单截图")
        }
        try CaptureService.enqueueImage(screenshot.data, fileExtension: screenshot.type?.preferredFilenameExtension ?? "img")
        return .result()
    }
}

#if !COUNTER_TOOL_MODULE
struct CounterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CounterQuickEntryIntent(),
                    phrases: ["在 \(.applicationName) 记一笔", "用 \(.applicationName) 记账"],
                    shortTitle: "记一笔", systemImageName: "plus.circle.fill")
        AppShortcut(intent: CounterImageDraftIntent(),
                    phrases: ["用 \(.applicationName) 核对这张账单截图"],
                    shortTitle: "截图待记账", systemImageName: "photo.badge.plus")
    }
}
#endif

public struct CounterToolAppIntentsPackage: AppIntentsPackage {}
