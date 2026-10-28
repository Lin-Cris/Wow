import Foundation
import SwiftUI
import Observation

enum EntryEditorRoute: Identifiable {
    case create(EntryKind)
    case prefill(CounterPendingIntent)
    case refund(BookEntry, remainingCents: Int64)
    case edit(BookEntry)
    var id: String {
        switch self {
        case .create(let kind): "new-\(kind.rawValue)"
        case .prefill(let request): "prefill-\(request.id)"
        case .refund(let entry, _): "refund-\(entry.id)"
        case .edit(let entry): "edit-\(entry.id)"
        }
    }
}

enum CounterRoute: Hashable {
    case monthBill(Date)
    case category(Date, String)
    case categorySettings
    case settings
    case accounts
    case drafts
    case draft(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var entries: [BookEntry] = []
    private(set) var categories: [BookCategory] = []
    private(set) var drafts: [ReviewDraft] = []
    private(set) var importBatches: [ImportBatch] = []
    private(set) var importProgress: [String: ImportBatch] = [:]
    private(set) var recoveryPoints: [BackupRecoveryPoint] = []
    private(set) var accounts: [BookAccount] = []
    private(set) var accountBalances: [String: Int64] = [:]
    private(set) var accountTransfers: [AccountTransfer] = []
    private(set) var monthSnapshots: [String: LedgerSnapshot] = [:]
    private(set) var monthErrors: [String: String] = [:]
    private(set) var loadingMonths: Set<String> = []
    private(set) var selectedMonth: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var showingStaleSnapshot = false
    var editorRoute: EntryEditorRoute?
    var path: [CounterRoute] = []
    var toast: String?
    var recentlyDeleted: BookEntry?
    private var isReviewingInbox = false
    private var inboxRecoveryTask: Task<Void, Never>?
    private var homeRefreshID = UUID()
    private var monthRefreshIDs: [String: UUID] = [:]
    private var recoveredPendingImports = false

    private let store: LocalStore?
    private let synchronizesSystemActivity: Bool

    init(store injectedStore: LocalStore? = nil, synchronizesSystemActivity: Bool = true) {
        self.synchronizesSystemActivity = synchronizesSystemActivity
        if let injectedStore {
            store = injectedStore
        } else {
            do { store = try LocalStore() }
            catch { store = nil; loadError = error.localizedDescription }
        }
    }

    var summary: MonthSummary { LedgerMath.summary(entries) }
    var spending: [CategorySpend] { LedgerMath.categorySpending(entries, categories: categories) }
    var selectedMonthKey: String { CounterFormat.monthKey(selectedMonth) }
    var expenseCategories: [BookCategory] { categories.filter { $0.kind == "expense" && $0.isActive }.sorted { $0.sortOrder < $1.sortOrder } }
    var incomeCategories: [BookCategory] { categories.filter { $0.kind == "income" && $0.isActive }.sorted { $0.sortOrder < $1.sortOrder } }
    var activeAccounts: [BookAccount] { accounts.filter(\.isActive).sorted { $0.sortOrder == $1.sortOrder ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.sortOrder < $1.sortOrder } }
    var dueSoonAccount: BookAccount? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let limit = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        return activeAccounts.filter { account in
            account.type.isLiability && (account.dueAmountCents ?? 0) > 0 &&
            account.upcomingRepaymentDate.map { calendar.startOfDay(for: $0) <= limit } == true
        }.sorted { ($0.upcomingRepaymentDate ?? .distantFuture) < ($1.upcomingRepaymentDate ?? .distantFuture) }.first
    }

    func entries(in month: Date) -> [BookEntry] { monthSnapshots[CounterFormat.monthKey(month)]?.entries ?? [] }
    func categories(in month: Date) -> [BookCategory] { monthSnapshots[CounterFormat.monthKey(month)]?.categories ?? categories }
    func summary(in month: Date) -> MonthSummary { monthSnapshots[CounterFormat.monthKey(month)]?.summary ?? MonthSummary() }
    func spending(in month: Date) -> [CategorySpend] { monthSnapshots[CounterFormat.monthKey(month)]?.spending ?? [] }
    func loadError(in month: Date) -> String? { monthErrors[CounterFormat.monthKey(month)] }

    func refresh() async {
        let month = selectedMonth
        let key = CounterFormat.monthKey(month)
        let requestID = UUID()
        homeRefreshID = requestID
        isLoading = true
        if let cached = monthSnapshots[key] {
            applyHomeSnapshot(cached)
            showingStaleSnapshot = true
        }
        guard let store else {
            isLoading = false
            return
        }
        if !recoveredPendingImports {
            recoveredPendingImports = true
            await resumeRecoverableImports()
        }
        do {
            let snapshot = try await store.snapshot(in: month)
            let loadedAccounts = try await store.allAccounts()
            guard homeRefreshID == requestID, selectedMonthKey == key else { return }
            accounts = loadedAccounts
            if synchronizesSystemActivity { await ReminderNotifications.synchronizeRepayments(loadedAccounts) }
            monthSnapshots[key] = snapshot
            monthErrors[key] = nil
            applyHomeSnapshot(snapshot)
            loadError = nil
            showingStaleSnapshot = false
            isLoading = false
            if synchronizesSystemActivity { await synchronizeActivity() }
        } catch {
            guard homeRefreshID == requestID, selectedMonthKey == key else { return }
            loadError = error.localizedDescription
            monthErrors[key] = error.localizedDescription
            showingStaleSnapshot = monthSnapshots[key] != nil
            isLoading = false
        }
    }

    func selectMonth(_ date: Date) async {
        selectedMonth = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
        if let cached = monthSnapshots[CounterFormat.monthKey(selectedMonth)] {
            applyHomeSnapshot(cached)
            showingStaleSnapshot = true
        } else {
            entries = []
            isLoading = true
            showingStaleSnapshot = false
        }
        await refresh()
    }

    func loadMonth(_ date: Date) async {
        guard let store else { monthErrors[CounterFormat.monthKey(date)] = StoreError.unavailable.localizedDescription; return }
        let key = CounterFormat.monthKey(date)
        let requestID = UUID()
        monthRefreshIDs[key] = requestID
        if monthSnapshots[key] == nil { loadingMonths.insert(key) }
        do {
            let snapshot = try await store.snapshot(in: date)
            guard monthRefreshIDs[key] == requestID else { return }
            monthSnapshots[key] = snapshot
            monthErrors[key] = nil
            loadingMonths.remove(key)
        } catch {
            guard monthRefreshIDs[key] == requestID else { return }
            monthErrors[key] = error.localizedDescription
            loadingMonths.remove(key)
        }
    }

    func shiftMonth(_ amount: Int) async {
        let next = Calendar.current.date(byAdding: .month, value: amount, to: selectedMonth) ?? selectedMonth
        await selectMonth(next)
    }

    func openEditor(_ route: EntryEditorRoute) { editorRoute = route }
    func openRefundEditor(for entry: BookEntry) async {
        guard let store else { toast = StoreError.unavailable.localizedDescription; return }
        do {
            let remaining = try await store.remainingRefundCents(for: entry.id)
            guard remaining > 0 else { toast = "这笔支出已没有剩余可退金额"; return }
            editorRoute = .refund(entry, remainingCents: remaining)
        } catch { toast = error.localizedDescription }
    }
    func monthBill() { path.append(.monthBill(selectedMonth)) }

    private func applyHomeSnapshot(_ snapshot: LedgerSnapshot) {
        entries = snapshot.entries
        categories = snapshot.categories
        drafts = snapshot.drafts
    }

    func saveEntry(_ entry: BookEntry) async throws {
        do {
            guard entry.cents > 0 else { throw AppError.invalidAmount }
            guard entry.resolvedCategory(in: categories) != nil else { throw AppError.missingCategory }
            guard let store else { throw StoreError.unavailable }
            let visibleMonth = visibleLedgerMonth()
            let destinationMonth = Calendar.current.dateInterval(of: .month, for: entry.occurredAt)?.start ?? entry.occurredAt
            try await store.save(entry)
            if let accountID = entry.accountID { rememberAccount(accountID, for: entry.kind) }
            editorRoute = nil
            await refreshLedgerViews(additionalMonth: destinationMonth)
            if CounterFormat.monthKey(destinationMonth) != CounterFormat.monthKey(visibleMonth) {
                toast = "已保存到\(CounterFormat.monthTitle(destinationMonth))，当前仍显示\(CounterFormat.monthTitle(visibleMonth))"
            } else {
                toast = "已保存"
            }
        } catch {
            throw error
        }
    }

    @discardableResult
    func refreshAccountOverview() async -> Bool {
        guard let store else { return false }
        do {
            let overview = try await store.accountOverview()
            accounts = overview.accounts
            accountBalances = overview.balances
            accountTransfers = overview.transfers
            if synchronizesSystemActivity { return await ReminderNotifications.synchronizeRepayments(overview.accounts) }
            return true
        } catch { toast = error.localizedDescription; return false }
    }

    func recentEntries(forAccountID accountID: String, limit: Int = 30) async throws -> [BookEntry] {
        guard let store else { throw StoreError.unavailable }
        return try await store.recentEntries(accountID: accountID, limit: limit)
    }

    func saveAccount(_ account: BookAccount, reconcileBalance: Bool = true) async throws {
        guard let store else { throw StoreError.unavailable }
        var saved = account
        if let old = accounts.first(where: { $0.id == account.id }) {
            // Subcategories share the same ledger sign; changing asset/debt nature would reinterpret history.
            guard old.type.isLiability == account.type.isLiability else { throw StoreError.invalidAccount }
            let oldBaseline = LedgerMath.add(old.openingBalanceCents, old.balanceAdjustmentCents ?? 0)
            let current = accountBalances[old.id] ?? oldBaseline
            let activity = LedgerMath.subtract(current, oldBaseline)
            let baseline = LedgerMath.subtract(account.openingBalanceCents, activity)
            saved.openingBalanceCents = reconcileBalance ? max(0, baseline) : old.openingBalanceCents
            saved.balanceAdjustmentCents = reconcileBalance ? min(0, baseline) : old.balanceAdjustmentCents
            saved.createdAt = old.createdAt
        }
        if synchronizesSystemActivity, saved.isActive, saved.type.isLiability, saved.repaymentReminderIsEnabled {
            if !(await ReminderNotifications.shared.checkPermission(requestIfNeeded: true)) {
                saved.repaymentReminderEnabled = false
                toast = ReminderNotifications.shared.message
            }
        }
        saved.updatedAt = Date()
        try await store.save(saved)
        let remindersSynced = await refreshAccountOverview()
        if synchronizesSystemActivity, saved.repaymentReminderIsEnabled, !remindersSynced {
            saved.repaymentReminderEnabled = false
            try await store.save(saved)
            let failure = ReminderNotifications.shared.message
            await refreshAccountOverview()
            toast = failure
        }
    }

    func archiveAccount(_ account: BookAccount) async throws {
        var archived = account
        archived.isActive = false
        try await saveAccount(archived, reconcileBalance: false)
    }

    func saveBorrowingAccount(_ account: BookAccount, cents: Int64, toAccountID: String) async throws -> BookAccount {
        guard let store else { throw StoreError.unavailable }
        let saved = try await store.saveBorrowing(account, cents: cents, toAccountID: toAccountID)
        await refreshAccountOverview()
        return saved
    }

    func moveAccountToTop(_ account: BookAccount) async throws {
        guard let store else { throw StoreError.unavailable }
        let ordered = activeAccounts.sorted { $0.sortOrder < $1.sortOrder }
        guard ordered.contains(where: { $0.id == account.id }) else { throw StoreError.invalidAccount }
        let ids = [account.id] + ordered.filter { $0.id != account.id }.map(\.id)
        try await store.reorderActiveAccounts(ids)
        await refreshAccountOverview()
    }

    func saveTransfer(_ transfer: AccountTransfer) async throws {
        guard let store else { throw StoreError.unavailable }
        try await store.save(transfer)
        await refreshAccountOverview()
    }

    func deleteTransfer(_ transfer: AccountTransfer) async throws {
        guard let store else { throw StoreError.unavailable }
        try await store.deleteTransfer(transfer)
        await refreshAccountOverview()
    }

    func accountName(_ id: String?) -> String? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })?.displayName
    }

    func account(for id: String?) -> BookAccount? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    func preferredAccountID(for kind: EntryKind) -> String? {
        let key = "counter.account.last-used.\(kind.rawValue)"
        if let saved = UserDefaults.standard.string(forKey: key), activeAccounts.contains(where: { $0.id == saved }) {
            return saved
        }
        return activeAccounts.first(where: { !$0.type.isLiability })?.id
    }

    private func rememberAccount(_ id: String, for kind: EntryKind) {
        UserDefaults.standard.set(id, forKey: "counter.account.last-used.\(kind.rawValue)")
    }

    func removeEntry(_ entry: BookEntry) async {
        guard let store else { return }
        do {
            try await store.delete(entry)
            recentlyDeleted = entry
            toast = "已删除"
            await refreshLedgerViews()
        } catch { toast = error.localizedDescription }
    }

    func undo(_ entry: BookEntry) async {
        guard let store else { return }
        do { try await store.save(entry); recentlyDeleted = nil; await refreshLedgerViews(additionalMonth: entry.occurredAt) }
        catch { toast = error.localizedDescription }
    }

    func reviewImage(at url: URL) async throws -> ReviewDraft {
        guard let store else { throw StoreError.unavailable }
        do {
            let draft = try await CaptureService.makeDraft(from: url, store: store)
            await refresh()
            await navigateToDraft(id: draft.id)
            toast = draft.state == .failed ? "截图已保留，可稍后重试识别" : "已加入待记账，请核对后保存"
            return draft
        } catch {
            toast = error.localizedDescription
            throw error
        }
    }

    func reviewText(_ text: String, sourceID: String) async throws -> ReviewDraft {
        guard let store else { throw StoreError.unavailable }
        do {
            let draft = try await CaptureService.makeDraft(fromText: text, identity: sourceID, store: store)
            await refresh()
            return draft
        } catch {
            toast = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func update(_ draft: ReviewDraft) async -> ReviewDraft? {
        guard let store else { return nil }
        do {
            var edited = draft
            edited.state = .needsReview
            edited.errorText = nil
            let saved = try await store.save(edited)
            await refresh()
            return saved
        } catch { toast = error.localizedDescription; return nil }
    }

    func retry(_ draft: ReviewDraft) async {
        guard let store, draft.imagePath != nil else {
            toast = "此草稿没有可重试的原图"
            return
        }
        do {
            let updated = try await CaptureService.recognize(draft, store: store)
            toast = updated.state == .needsReview ? "识别完成，请核对" : updated.state.label
            await refresh()
        } catch {
            if var current = try? await store.draft(id: draft.id) {
                current.state = .failed
                current.errorText = error.localizedDescription
                current.claimToken = nil
                current.claimExpiresAt = nil
                _ = try? await store.save(current)
            }
            await refresh()
        }
    }

    func confirm(_ draft: ReviewDraft) async throws {
        do {
            guard let store else { throw StoreError.unavailable }
            guard let amount = draft.cents, amount > 0 else { throw AppError.missingAmount }
            guard let kind = draft.kind else { throw AppError.missingKind }
            guard let categoryID = draft.categoryID,
                  let category = categories.first(where: { $0.id == categoryID }) else { throw AppError.missingCategory }
            let now = Date()
            let record = BookEntry(id: "entry-\(draft.id)", cents: amount, kind: kind,
                                   occurredAt: draft.occurredAt, categoryID: categoryID,
                                   iconChoice: category.symbol, note: draft.note,
                                   sourceID: draft.sourceID, originalEntryID: nil,
                                   createdAt: now, updatedAt: now, confirmedDraftID: draft.id)
            let committed = try await store.commitDraft(draft, entry: record)
            await refreshLedgerViews(additionalMonth: committed.occurredAt)
            await CounterActivityController.stop(draftID: draft.id)
            toast = "已确认入账"
        } catch {
            throw error
        }
    }

    func dismiss(_ draft: ReviewDraft) async {
        guard let store else { return }
        do {
            try await store.dismissDraft(draft)
            await CounterActivityController.stop(draftID: draft.id)
            await refresh()
        } catch { toast = error.localizedDescription }
    }

    func reviewInbox() async {
        guard !isReviewingInbox, store != nil, let inbox = CaptureService.sharedInbox else { return }
        isReviewingInbox = true
        defer { isReviewingInbox = false }
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            var receivedDraftIDs: [String] = []
            for manifestURL in files where manifestURL.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: manifestURL)
                    let item = try JSONDecoder().decode(SharedInboxItem.self, from: data)
                    guard UUID(uuidString: item.id) != nil,
                          item.filename == URL(fileURLWithPath: item.filename).lastPathComponent,
                          item.filename.hasPrefix("\(item.id)."),
                          !item.filename.contains(".."), item.filename.count <= 96,
                          manifestURL.lastPathComponent == "\(item.id).json" else {
                        throw StoreError.invalidBackup
                    }
                    let sourceURL = inbox.appendingPathComponent(item.filename)
                    let bytes = try Data(contentsOf: sourceURL)
                    var deliveredDraft: ReviewDraft
                    if item.kind == "image" {
                        guard bytes.count <= 25 * 1_024 * 1_024,
                              SharedInboxItem.imageExtension(for: bytes) != "img",
                              sourceURL.pathExtension.lowercased() == SharedInboxItem.imageExtension(for: bytes) else {
                            throw StoreError.database("分享的图片格式无效或超过 25 MB")
                        }
                        guard let store else { throw StoreError.unavailable }
                        deliveredDraft = try await CaptureService.makeDraft(from: sourceURL, store: store)
                    } else if item.kind == "text", item.filename == "\(item.id).txt",
                              bytes.count <= SharedInboxItem.maximumTextBytes,
                              let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
                        guard text.count <= SharedInboxItem.maximumTextCharacters else { throw StoreError.database("分享文本超过 20,000 字") }
                        deliveredDraft = try await reviewText(text, sourceID: item.id)
                    } else {
                        throw StoreError.database("分享内容为空或格式不受支持")
                    }
                    receivedDraftIDs.append(deliveredDraft.id)
                    if deliveredDraft.state == .queued || deliveredDraft.state == .recognizing {
                        scheduleInboxRecovery(after: max(2, (deliveredDraft.claimExpiresAt ?? Date().addingTimeInterval(30)).timeIntervalSinceNow + 1))
                    } else {
                        try FileManager.default.removeItem(at: sourceURL)
                        try FileManager.default.removeItem(at: manifestURL)
                    }
                } catch {
                    toast = "输入仍保留在收件箱：\(error.localizedDescription)"
                }
            }
            if !receivedDraftIDs.isEmpty {
                await refresh()
                if receivedDraftIDs.count == 1 { await navigateToDraft(id: receivedDraftIDs[0]) }
                else { path.append(.drafts) }
                toast = "已加入待记账，请核对后保存"
            }
        } catch {
            toast = "无法读取待记账收件箱：\(error.localizedDescription)"
        }
    }

    func resumeRecoverableDrafts() async {
        guard let store, let active = try? await store.activeDrafts() else { return }
        var changed = false
        for draft in active where draft.state == .queued || draft.state == .recognizing {
            if draft.state == .recognizing, let expiry = draft.claimExpiresAt, expiry > Date() {
                scheduleInboxRecovery(after: expiry.timeIntervalSinceNow + 1)
                continue
            }
            do {
                let updated = try await CaptureService.recognize(draft, store: store)
                changed = true
                if updated.state == .recognizing {
                    scheduleInboxRecovery(after: max(2, (updated.claimExpiresAt ?? Date().addingTimeInterval(30)).timeIntervalSinceNow + 1))
                }
            } catch {
                toast = "待记账任务恢复失败：\(error.localizedDescription)"
            }
        }
        if changed { await refresh() }
    }

    func previewCSV(_ data: Data) async throws -> CSVPreview {
        guard let store else { throw StoreError.unavailable }
        guard data.count <= CounterCSV.maximumFileBytes else { throw CounterCSVError.fileTooLarge }
        let availableCategories = categories.isEmpty ? try await store.allCategories() : categories
        let availableAccounts = try await store.allAccounts()
        var preview = try await Task.detached(priority: .userInitiated) {
            try CounterCSV.parse(data, existingCategories: availableCategories, existingAccounts: availableAccounts)
        }.value
        let existing = try await store.allEntries()
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bySource = Dictionary(existing.compactMap { entry in entry.sourceID.map { ($0, entry) } },
                                  uniquingKeysWith: { first, _ in first })
        var importable: [BookEntry] = []
        for entry in preview.records {
            let prior = byID[entry.id] ?? entry.sourceID.flatMap { bySource[$0] }
            guard let prior else { importable.append(entry); continue }
            if CounterCSV.equivalent(prior, entry) { preview.duplicateCount += 1 }
            else {
                preview.conflictCount += 1
                preview.rejectedRows.append("记录 \(entry.id)：编号或来源与账本中不同内容冲突，已跳过")
            }
        }
        preview.records = importable
        return preview
    }

    func importCSV(_ preview: CSVPreview) async throws -> String {
        guard let store else { throw StoreError.unavailable }
        let invalid = max(0, preview.rejectedRows.count - preview.conflictCount)
        let batch = try await store.prepareImportBatch(preview.records, categories: preview.categories,
                                                       inputRows: preview.totalRows, sourceDigest: preview.sourceDigest,
                                                       preflightDuplicates: preview.duplicateCount,
                                                       preflightConflicts: preview.conflictCount,
                                                       preflightInvalid: invalid)
        let result: ImportBatch
        do { result = try await runImportBatch(batch.id) }
        catch {
            try? await store.abortImportBatch(id: batch.id)
            await refreshImportBatches()
            throw error
        }
        await refreshLedgerViews()
        await refreshImportBatches()
        return "导入完成：新增 \(result.inserted) 笔，重复 \(result.duplicates) 笔，冲突 \(result.conflicts) 笔，无效 \(result.invalid) 行。可在设置的导入记录中撤销未修改的导入明细。"
    }

    func refreshImportBatches() async {
        guard let store else { return }
        importBatches = (try? await store.importBatches()) ?? []
    }

    func resumeRecoverableImports() async {
        guard let store else { return }
        let pending = (try? await store.pendingImportBatches()) ?? []
        for batch in pending {
            do {
                _ = try await runImportBatch(batch.id)
                toast = "已恢复一笔中断的导入批次。"
            } catch {
                try? await store.abortImportBatch(id: batch.id)
                toast = "导入批次未能继续，未完成的明细已撤回：\(error.localizedDescription)"
            }
        }
        await refreshImportBatches()
    }

    func retryImportBatch(_ id: String) async throws {
        guard let store else { throw StoreError.unavailable }
        try await store.retryImportBatch(id: id)
        do { _ = try await runImportBatch(id) }
        catch { try? await store.abortImportBatch(id: id); await refreshImportBatches(); throw error }
        await refreshLedgerViews()
        await refreshImportBatches()
    }

    func undoImportBatch(_ id: String) async throws -> String {
        guard let store else { throw StoreError.unavailable }
        let result = try await store.undoImportBatch(id: id)
        await refreshLedgerViews()
        await refreshImportBatches()
        return result.conflicts == 0
            ? "已撤销导入批次，移除 \(result.deleted) 笔未修改的明细。"
            : "已撤销 \(result.deleted) 笔未修改明细，保留 \(result.conflicts) 笔已有后续修改或关联的记录。"
    }

    private func runImportBatch(_ id: String) async throws -> ImportBatch {
        guard let store else { throw StoreError.unavailable }
        guard var batch = try await store.importBatch(id: id) else { throw StoreError.invalidImportBatch }
        while !batch.isComplete {
            batch = try await store.processImportBatch(id: id)
            importProgress[id] = batch
            await Task.yield()
        }
        importProgress[id] = nil
        return batch
    }

    func csvDocument() async throws -> CSVDocument {
        guard let store else { throw StoreError.unavailable }
        return CSVDocument(data: CounterCSV.encode(try await store.allEntries(), categories: try await store.allCategories()))
    }

    func backupDocument() async throws -> BackupDocument {
        guard let store else { throw StoreError.unavailable }
        let data = try CounterCSV.encodeBackup(await store.backup())
        guard data.count <= 256 * 1_024 * 1_024 else { throw StoreError.backupResourceLimit }
        return BackupDocument(data: data)
    }

    func previewRestore(_ data: Data) async throws -> CounterRestorePreview {
        guard let store else { throw StoreError.unavailable }
        guard data.count <= 256 * 1_024 * 1_024 else { throw StoreError.invalidBackup }
        let backup = try JSONDecoder().decode(CounterBackup.self, from: data)
        guard backup.format == "counter-backup", backup.version == 1 else { throw StoreError.invalidBackup }
        return try await store.previewRestore(backup)
    }

    func refreshRecoveryPoints() {
        let directory = recoveryDirectoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            recoveryPoints = []
            return
        }
        recoveryPoints = urls.compactMap { url in
            guard Self.isRecoveryFilename(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            return BackupRecoveryPoint(filename: url.lastPathComponent, date: date, sizeBytes: Int64(size))
        }.sorted { $0.date > $1.date }
    }

    func createRecoveryPoint() async throws -> String {
        let document = try await backupDocument()
        let filename = "checkpoint-\(Self.recoveryTimestamp(Date()))-\(UUID().uuidString.prefix(8)).counterbackup"
        try FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
        try document.data.write(to: recoveryDirectoryURL.appendingPathComponent(filename), options: .atomic)
        refreshRecoveryPoints()
        return filename
    }

    func restoreRecoveryPoint(_ filename: String) async throws {
        guard Self.isRecoveryFilename(filename) else { throw StoreError.invalidBackup }
        let url = recoveryDirectoryURL.appendingPathComponent(filename)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= 256 * 1_024 * 1_024 else { throw StoreError.invalidBackup }
        try await restore(Data(contentsOf: url), replace: true)
        refreshRecoveryPoints()
    }

    func recoveryPointDocument(_ filename: String) async throws -> BackupDocument {
        guard Self.isRecoveryFilename(filename) else { throw StoreError.invalidBackup }
        let url = recoveryDirectoryURL.appendingPathComponent(filename)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= 256 * 1_024 * 1_024 else { throw StoreError.invalidBackup }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let store else { throw StoreError.unavailable }
        let backup = try JSONDecoder().decode(CounterBackup.self, from: data)
        try await store.validateBackup(backup)
        return BackupDocument(data: data)
    }

    func deleteRecoveryPoint(_ filename: String) throws {
        guard Self.isRecoveryFilename(filename) else { throw StoreError.invalidBackup }
        try FileManager.default.removeItem(at: recoveryDirectoryURL.appendingPathComponent(filename))
        refreshRecoveryPoints()
    }

    private var recoveryDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counter/Recovery", isDirectory: true)
    }

    private static func isRecoveryFilename(_ filename: String) -> Bool {
        let prefix = filename.hasPrefix("checkpoint-") || filename.hasPrefix("before-restore-")
        return prefix && filename == URL(fileURLWithPath: filename).lastPathComponent && filename.hasSuffix(".counterbackup")
    }

    private static func recoveryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    func restore(_ data: Data, replace: Bool) async throws {
        guard let store else { throw StoreError.unavailable }
        guard data.count <= 256 * 1_024 * 1_024 else { throw StoreError.invalidBackup }
        let backup = try JSONDecoder().decode(CounterBackup.self, from: data)
        guard backup.format == "counter-backup", backup.version == 1 else { throw StoreError.invalidBackup }
        try await store.validateBackup(backup)
        if replace {
            let current = try await store.backup()
            let recoveryData = try CounterCSV.encodeBackup(current)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Counter/Recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = "before-restore-\(Self.recoveryTimestamp(Date()))-\(UUID().uuidString.prefix(8)).counterbackup"
            try recoveryData.write(to: directory.appendingPathComponent(filename), options: .atomic)
        }
        try await store.restore(backup, replace: replace)
        monthSnapshots.removeAll()
        monthErrors.removeAll()
        await refreshLedgerViews()
        await refreshImportBatches()
        refreshRecoveryPoints()
        toast = replace ? "账本已恢复" : "备份已合并"
    }

    func toggleCategory(_ category: BookCategory) async {
        guard let store else { return }
        do { try await store.toggleCategory(id: category.id); await refreshLedgerViews() }
        catch { toast = error.localizedDescription }
    }

    func deleteCategory(_ category: BookCategory) async throws {
        guard let store else { throw StoreError.unavailable }
        try await store.deleteCategory(id: category.id)
        let loaded = try await store.allCategories()
        withAnimation(.easeInOut(duration: 0.25)) { categories = loaded }
        monthSnapshots.removeAll()
        await refreshLedgerViews()
    }

    func addCategory(_ rawName: String, kind: EntryKind, iconPNGBase64: String? = nil) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidCategoryName }
        let categoryKind = kind == .income ? "income" : "expense"
        guard !categories.contains(where: { $0.kind == categoryKind && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppError.duplicateCategory
        }
        guard let store else { throw StoreError.unavailable }
        let existing = categories.filter { $0.kind == categoryKind }
        let category = BookCategory(id: "category-\(UUID().uuidString.lowercased())", name: String(name.prefix(24)),
                                    kind: categoryKind, symbol: "custom_category",
                                    sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1, isActive: true,
                                    iconPNGBase64: iconPNGBase64)
        try await store.save(category)
        await refreshLedgerViews()
    }

    func handle(_ url: URL) {
        guard url.scheme == CounterURLScheme.value else { return }
        switch url.host {
        case "compose": editorRoute = .create(.expense)
        case "drafts":
            let id = url.pathComponents.dropFirst().first.flatMap { $0 == "/" ? nil : $0 }
            Task { await navigateToDraft(id: id) }
        default: break
        }
    }

    func consumeIntent() {
        let defaults = UserDefaults(suiteName: CaptureService.appGroup)
        if let defaults {
            while let request = CounterIntentQueue.takeNext(from: defaults) {
                let consumedKey = "counter.consumed.intent.\(request.id)"
                guard defaults.bool(forKey: consumedKey) != true else { continue }
                defaults.set(true, forKey: consumedKey)
                if request.action == "compose" { editorRoute = .prefill(request) }
                return
            }
            if defaults.string(forKey: "counter.pending.intent") == "compose" {
                defaults.removeObject(forKey: "counter.pending.intent")
                editorRoute = .create(.expense)
            }
        }
    }

    func navigateToDraft(id: String?) async {
        guard let id, !id.isEmpty else { path.append(.drafts); return }
        guard let store, let draft = try? await store.draft(id: id) else {
            toast = "找不到这笔待记账任务"
            path.append(.drafts)
            return
        }
        switch draft.state {
        case .confirmed:
            let entryID = draft.confirmedEntryID ?? "entry-\(draft.id)"
            if let entry = try? await store.entry(id: entryID) {
                path.append(.monthBill(entry.occurredAt))
                toast = "这笔账单已经入账"
            } else { toast = "这笔任务已完成，但账单记录无法读取" }
        case .dismissed:
            toast = "这笔待记账任务已忽略"
            path.append(.drafts)
        default:
            path.append(.draft(id))
        }
    }

    func refreshActivityPrivacy() async { await synchronizeActivity() }

    private func scheduleInboxRecovery(after delay: TimeInterval) {
        inboxRecoveryTask?.cancel()
        inboxRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled, let self else { return }
            await self.reviewInbox()
        }
    }

    func amountForDay(_ day: Date) -> Int64 {
        entries.filter { Calendar.current.isDate($0.localDay, inSameDayAs: day) }
            .reduce(0) { $0 + ($1.kind == .expense ? $1.cents : ($1.kind == .refund ? -$1.cents : 0)) }
    }

    private func synchronizeActivity() async {
        guard let pending = drafts.first else {
            await CounterActivityController.stop()
            return
        }
        let category = categories.first { $0.id == pending.categoryID }
        await CounterActivityController.show(pending, category: category)
    }

    private func visibleLedgerMonth() -> Date {
        for route in path.reversed() {
            switch route {
            case .monthBill(let month), .category(let month, _): return month
            case .categorySettings, .settings, .accounts, .drafts, .draft(_): continue
            }
        }
        return selectedMonth
    }

    private func refreshLedgerViews(additionalMonth: Date? = nil) async {
        await refresh()
        await refreshAccountOverview()
        let visibleMonth = visibleLedgerMonth()
        await loadMonth(visibleMonth)
        if let additionalMonth,
           CounterFormat.monthKey(additionalMonth) != CounterFormat.monthKey(visibleMonth),
           CounterFormat.monthKey(additionalMonth) != selectedMonthKey {
            await loadMonth(additionalMonth)
        }
    }
}

enum AppError: LocalizedError {
    case invalidAmount, missingAmount, missingKind, missingCategory, invalidCategoryName, duplicateCategory
    var errorDescription: String? {
        switch self {
        case .invalidAmount: "金额必须大于零，最多输入两位小数"
        case .missingAmount: "还没有可靠的金额，请核对后填写"
        case .missingKind: "请选择这笔账单的收入、支出或退款"
        case .missingCategory: "请为这笔账单选择分类"
        case .invalidCategoryName: "分类名称不能为空"
        case .duplicateCategory: "已存在同名分类"
        }
    }
}
