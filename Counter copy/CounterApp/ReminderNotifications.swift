import Foundation
import UserNotifications
import Combine

/// One native scheduler for the host and embedded Counter. Each owner reconciles only its namespace.
@MainActor
protocol ReminderNotificationClient: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func deliveredIdentifiers() async -> [String]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class NativeReminderNotificationClient: NSObject, ReminderNotificationClient, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    override init() {
        super.init()
        center.delegate = self
    }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
public final class ReminderNotifications: ObservableObject {
    public static let shared = ReminderNotifications()
    @Published public private(set) var notificationsAllowed = false
    @Published public private(set) var message = ""
    private let client: ReminderNotificationClient
    private var queued: Task<Bool, Never>?

    public convenience init() { self.init(client: NativeReminderNotificationClient()) }
    init(client: ReminderNotificationClient) { self.client = client }

    /// Only a deliberate enable/save action may prompt; foreground reconciliation never prompts.
    public func checkPermission(requestIfNeeded: Bool = false) async -> Bool {
        var status = await client.authorizationStatus()
        if status == .notDetermined && requestIfNeeded {
            do { _ = try await client.requestAuthorization(); status = await client.authorizationStatus() }
            catch { message = "无法开启通知：\(error.localizedDescription)"; notificationsAllowed = false; return false }
        }
        notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(status)
        message = notificationsAllowed ? "" : "系统通知未开启，请在设置 → Wow → 通知中允许通知。"
        return notificationsAllowed
    }

    /// Serialize native mutations across both domains so rapid edits cannot resurrect an old request.
    @discardableResult
    public func replace(prefix: String, requests: [UNNotificationRequest]) async -> Bool {
        let previous = queued
        let task = Task { @MainActor in
            _ = await previous?.value
            let allowed = await self.checkPermission()
            let pending = await self.client.pendingRequests()
            let owned = pending.filter { $0.identifier.hasPrefix(prefix) }
            let desired = allowed ? requests : []
            let ids = Set(desired.map(\.identifier))
            let delivered = await self.client.deliveredIdentifiers()
            let obsolete = Array(Set(owned.filter { !ids.contains($0.identifier) }.map(\.identifier) +
                delivered.filter { $0.hasPrefix(prefix) && !ids.contains($0) }))
            self.client.removePending(obsolete)
            self.client.removeDelivered(obsolete)
            guard allowed || requests.isEmpty else { return false }
            guard pending.filter({ !$0.identifier.hasPrefix(prefix) }).count + desired.count <= 64 else {
                self.client.removePending(owned.map(\.identifier))
                self.message = "系统提醒容量不足，请减少提醒后重试；此次提醒未启用。"
                return false
            }
            do {
                for request in desired {
                    if let old = owned.first(where: { $0.identifier == request.identifier }), Self.matches(old, request) { continue }
                    // Cancel before adding a replacement; also clear an already delivered old reminder.
                    self.client.removePending([request.identifier])
                    self.client.removeDelivered([request.identifier])
                    try await self.client.add(request)
                }
                return true
            } catch {
                self.client.removePending(Array(Set(owned.map(\.identifier) + desired.map(\.identifier))))
                self.message = "提醒未启用：\(error.localizedDescription)"
                return false
            }
        }
        queued = task
        return await task.value
    }

    private static func matches(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        guard let left = lhs.trigger as? UNCalendarNotificationTrigger,
              let right = rhs.trigger as? UNCalendarNotificationTrigger else { return false }
        return lhs.content.title == rhs.content.title && lhs.content.body == rhs.content.body &&
            left.repeats == right.repeats && left.dateComponents == right.dateComponents
    }

    public static func planRequest(id: String, title: String, date: Date, now: Date = Date()) -> UNNotificationRequest? {
        guard date > now else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "计划提醒"
        content.body = title
        content.sound = .default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: "plan-reminder-\(id)", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    /// Days 1–28 repeat monthly forever. For month-end days, non-February months repeat annually;
    /// February is precomputed for four years (including leap years), replenished on every activation.
    /// This avoids a finite rolling queue for the other eleven months and never schedules February 31.
    static func repaymentRequests(accounts: [BookAccount], now: Date = Date()) -> [UNNotificationRequest] {
        accounts.flatMap { account -> [UNNotificationRequest] in
            guard account.isActive, account.type.isLiability, account.repaymentReminderIsEnabled,
                  let day = account.effectiveRepaymentDay else { return [] }
            let content = UNMutableNotificationContent()
            content.title = "还款提醒"
            let provider = account.providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = provider.isEmpty || account.displayName.contains(provider) ? account.displayName : provider + account.displayName
            // A manually entered due amount has no billing-period freshness guarantee.
            content.body = "\(name)今天是还款日"
            content.sound = .default
            let base = "repayment-reminder-\(account.id)"
            if day <= 28 {
                return [UNNotificationRequest(identifier: base, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(day: day, hour: 9, minute: 0), repeats: true))]
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            var requests = (1...12).filter { $0 != 2 }.map { month in
                let days = [4, 6, 9, 11].contains(month) ? 30 : 31
                return UNNotificationRequest(identifier: "\(base)-month-\(month)", content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(month: month, day: min(day, days), hour: 9, minute: 0), repeats: true))
            }
            let februaryDates = Self.februaryDates(day: day, now: now)
            requests += februaryDates.map { date in
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                return UNNotificationRequest(identifier: "\(base)-february-\(components.year!)", content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            }
            return requests
        }
    }

    private static func februaryDates(day: Int, now: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: now)
        return Array((year...year + 4).compactMap { year -> Date? in
            guard let start = calendar.date(from: DateComponents(year: year, month: 2, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: start),
                  let date = calendar.date(from: DateComponents(year: year, month: 2, day: min(day, days.count), hour: 9)), date > now else { return nil }
            return date
        }.prefix(4))
    }

    static func repaymentNote(day: Int, now: Date = Date()) -> String {
        let base = "每月 09:00 提醒；短月份按最后一天提醒。"
        guard day > 28, let end = februaryDates(day: day, now: now).last else { return base }
        let year = Calendar(identifier: .gregorian).component(.year, from: end)
        return base + " 二月提醒已安排至\(year)年，打开应用时自动续期。"
    }

    @discardableResult
    static func synchronizeRepayments(_ accounts: [BookAccount], scheduler: ReminderNotifications? = nil) async -> Bool {
        await (scheduler ?? .shared).replace(prefix: "repayment-reminder-", requests: repaymentRequests(accounts: accounts))
    }

    /// Called by Wow even when the Counter screen has never been opened.
    public func refreshStoredRepayments() async {
        do {
            let store = try LocalStore()
            let accounts = try await store.allAccounts()
            await Self.synchronizeRepayments(accounts, scheduler: self)
        } catch { message = "无法读取还款提醒：\(error.localizedDescription)" }
    }
}
