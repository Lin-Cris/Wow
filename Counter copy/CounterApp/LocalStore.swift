import Foundation
import ImageIO
import SQLite3

private enum SQLValue {
    case text(String), integer(Int64), real(Double), null
}

private struct ImportBatchPayload: Codable {
    var entries: [BookEntry]
    var categories: [BookCategory]
    var inputRows: Int
    var preflightDuplicates: Int
    var preflightConflicts: Int
    var preflightInvalid: Int
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor LocalStore {
    private static let currentSchemaVersion: Int32 = 15
    private static let maximumCents: Int64 = 9_000_000_000_000_000
    private static let maximumBackupEntries = 200_000
    private static let maximumBackupDrafts = 20_000
    private static let maximumBackupCategories = 1_000
    private static let maximumBackupMediaBytes = 128 * 1_024 * 1_024
    private static let maximumBackupImagePixels = 60_000_000
    private var db: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        let url: URL
        if let databaseURL {
            url = databaseURL
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Counter", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("counter.sqlite")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = Self.error(handle, fallback: "无法打开本地账本")
            if let handle { sqlite3_close(handle) }
            throw error
        }
        guard let connection = handle else { throw StoreError.unavailable }
        let existingVersion: Int32
        do {
            existingVersion = try Self.schemaVersion(connection)
            guard existingVersion <= Self.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(existingVersion)
            }
        } catch {
            sqlite3_close(connection)
            throw error
        }
        sqlite3_busy_timeout(connection, 4_000)
        do {
            try Self.execute(connection, "PRAGMA journal_mode=WAL")
            // Rebuilding the referenced accounts table requires FK enforcement off before BEGIN.
            try Self.execute(connection, existingVersion < 15 ? "PRAGMA foreign_keys=OFF" : "PRAGMA foreign_keys=ON")
            try Self.execute(connection, "PRAGMA secure_delete=ON")
            try Self.execute(connection, "BEGIN IMMEDIATE")
            try Self.execute(connection, """
        CREATE TABLE IF NOT EXISTS categories(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
          symbol TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
          is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS entries(
          id TEXT PRIMARY KEY, cents INTEGER NOT NULL CHECK(cents > 0),
          kind TEXT NOT NULL CHECK(kind IN ('expense','income','refund')),
          occurred_at REAL NOT NULL, local_day TEXT NOT NULL,
          category_id TEXT NOT NULL REFERENCES categories(id), icon_choice TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '', source_id TEXT, original_entry_id TEXT,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          accounting_time_zone TEXT NOT NULL DEFAULT 'legacy-unknown',
          currency_code TEXT NOT NULL DEFAULT 'CNY', record_version INTEGER NOT NULL DEFAULT 1,
          import_batch_id TEXT, confirmed_draft_id TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS entries_source_id_unique
          ON entries(source_id) WHERE source_id IS NOT NULL AND source_id <> '';
        CREATE INDEX IF NOT EXISTS entries_day_sort ON entries(local_day, occurred_at DESC);
        CREATE INDEX IF NOT EXISTS entries_category_day ON entries(category_id, local_day);
        CREATE TABLE IF NOT EXISTS review_drafts(
          id TEXT PRIMARY KEY, state TEXT NOT NULL, cents INTEGER, kind TEXT,
          occurred_at REAL NOT NULL, category_id TEXT, note TEXT NOT NULL DEFAULT '',
          image_path TEXT, recognized_text TEXT NOT NULL DEFAULT '', source_id TEXT,
          error_text TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL DEFAULT 0,
          record_version INTEGER NOT NULL DEFAULT 1, confirmed_entry_id TEXT,
          input_digest TEXT, user_confirmed_fields TEXT NOT NULL DEFAULT '[]',
          claim_token TEXT, claim_expires_at REAL, candidate_confidence TEXT NOT NULL DEFAULT '{}', amount_text TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS review_source_id_unique
          ON review_drafts(source_id) WHERE source_id IS NOT NULL AND source_id <> '';
        CREATE TABLE IF NOT EXISTS import_batches(
          id TEXT PRIMARY KEY, source_digest TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
          updated_at REAL NOT NULL, input_rows INTEGER NOT NULL, inserted_count INTEGER NOT NULL DEFAULT 0,
          duplicate_count INTEGER NOT NULL DEFAULT 0, conflict_count INTEGER NOT NULL DEFAULT 0,
          invalid_count INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL, undo_conflicts INTEGER NOT NULL DEFAULT 0, payload_json TEXT
        );
        """)
            if existingVersion < 2 { try Self.migrateToV2(connection) }
            if existingVersion < 3 { try Self.migrateToV3(connection) }
            if existingVersion < 4 { try Self.migrateToV4(connection) }
            if existingVersion < 5 { try Self.migrateToV5(connection) }
            if existingVersion < 6 { try Self.migrateToV6(connection) }
            if existingVersion < 7 { try Self.migrateToV7(connection) }
            if existingVersion < 8 { try Self.migrateToV8(connection) }
            if existingVersion < 9 { try Self.migrateToV9(connection) }
            if existingVersion < 10 { try Self.migrateToV10(connection) }
            if existingVersion < 11 { try Self.migrateToV11(connection) }
            if existingVersion < 12 { try Self.migrateToV12(connection) }
            if existingVersion < 13 { try Self.migrateToV13(connection) }
            if existingVersion < 14 { try Self.migrateToV14(connection) }
            if existingVersion < 15 {
                try Self.migrateToV15(connection)
                try Self.verifyForeignKeys(connection)
            }
            try Self.execute(connection, """
            CREATE UNIQUE INDEX IF NOT EXISTS entries_confirmed_draft_unique
              ON entries(confirmed_draft_id) WHERE confirmed_draft_id IS NOT NULL AND confirmed_draft_id <> '';
            CREATE INDEX IF NOT EXISTS entries_month_day_sort ON entries(local_day, occurred_at DESC, id);
            PRAGMA user_version=15;
            """)
            try Self.execute(connection, "COMMIT")
            try Self.execute(connection, "PRAGMA foreign_keys=ON")
        } catch {
            try? Self.execute(connection, "ROLLBACK")
            sqlite3_close(connection)
            throw error
        }
        db = connection
    }

    deinit { if let db { sqlite3_close(db) } }

    func allCategories(includeInactive: Bool = true) throws -> [BookCategory] {
        let filter = includeInactive ? "" : "WHERE is_active=1"
        return try rows("SELECT * FROM categories \(filter) ORDER BY kind, sort_order, name")?.compactMap(Self.category) ?? []
    }

    func bootstrap() throws {
        if try allCategories().isEmpty {
            for category in BookCategory.defaults { try save(category) }
        }
        // Add only the new option to existing ledgers; keep every category and setting intact.
        let income = BookCategory.incomeOption
        try run("INSERT OR IGNORE INTO categories(id,name,kind,symbol,sort_order,is_active) VALUES(?,?,?,?,?,1)",
                [.text(income.id), .text(income.name), .text(income.kind), .text(income.symbol), .integer(Int64(income.sortOrder))])
    }

    func save(_ category: BookCategory) throws {
        guard category.iconPNGBase64.map(CategoryIconArtwork.isValidPNGBase64) ?? true else {
            throw StoreError.invalidCategoryIcon
        }
        try run("""
        INSERT INTO categories(id,name,kind,symbol,sort_order,is_active,icon_png) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind,
          symbol=excluded.symbol, sort_order=excluded.sort_order, is_active=excluded.is_active,icon_png=excluded.icon_png
        """, [.text(category.id), .text(category.name), .text(category.kind), .text(category.symbol),
               .integer(Int64(category.sortOrder)), .integer(category.isActive ? 1 : 0),
               category.iconPNGBase64.map(SQLValue.text) ?? .null])
    }

    func deleteCategory(id: String) throws {
        try transaction {
            guard var category = try allCategories().first(where: { $0.id == id }) else { return }
            guard category.isUserCreated else { throw StoreError.protectedCategory }
            // Snapshot first, then physically remove the category. No ledger record is deleted.
            category.isActive = false
            let snapshot = String(decoding: try JSONEncoder().encode(category), as: UTF8.self)
            try run("UPDATE entries SET category_snapshot=? WHERE category_id=?", [.text(snapshot), .text(id)])
            try run("UPDATE review_drafts SET category_id=NULL,record_version=record_version+1 WHERE category_id=?", [.text(id)])
            try run("DELETE FROM categories WHERE id=?", [.text(id)])
        }
    }

    func toggleCategory(id: String) throws {
        // UPDATE cannot recreate a category removed by a concurrent swipe.
        try run("UPDATE categories SET is_active=CASE is_active WHEN 1 THEN 0 ELSE 1 END WHERE id=?", [.text(id)])
    }

    func save(_ account: BookAccount) throws {
        let customLabel = account.cardLabelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardIconPNG = account.cardIconPNGBase64?.isEmpty == false ? account.cardIconPNGBase64 : nil
        let providerName = account.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.id.isEmpty, account.id.count <= 128,
              !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              account.name.count <= 40, account.openingBalanceCents >= 0,
              account.openingBalanceCents <= Self.maximumCents,
              (customLabel?.count ?? 0) <= 24,
              (providerName?.count ?? 0) <= 40,
              (cardIconPNG.map(AccountCardArtwork.isValidPNGBase64) ?? true),
              account.balanceAdjustmentCents.map({ $0 >= -Self.maximumCents && $0 <= Self.maximumCents }) ?? true,
              account.creditLimitCents.map({ $0 >= 0 && $0 <= Self.maximumCents }) ?? true,
              account.dueAmountCents.map({ $0 >= 0 && $0 <= Self.maximumCents }) ?? true,
              account.repaymentDay.map({ (1...31).contains($0) }) ?? true,
              account.nextDueDate?.timeIntervalSince1970.isFinite ?? true else { throw StoreError.invalidAccount }
        try run("""
        INSERT INTO accounts(id,name,type,opening_balance_cents,balance_adjustment_cents,credit_limit_cents,due_amount_cents,next_due_at,repayment_day,repayment_reminder_enabled,card_label,card_icon,card_color,card_icon_png,provider_name,is_active,sort_order,created_at,updated_at,card_icon_override)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,type=excluded.type,
          opening_balance_cents=excluded.opening_balance_cents,balance_adjustment_cents=excluded.balance_adjustment_cents,
          credit_limit_cents=excluded.credit_limit_cents,
          due_amount_cents=excluded.due_amount_cents,next_due_at=excluded.next_due_at,
          repayment_day=excluded.repayment_day,repayment_reminder_enabled=excluded.repayment_reminder_enabled,
          card_label=excluded.card_label,card_icon=excluded.card_icon,card_color=excluded.card_color,
          card_icon_png=excluded.card_icon_png,card_icon_override=excluded.card_icon_override,
          provider_name=excluded.provider_name,
          is_active=excluded.is_active,sort_order=excluded.sort_order,updated_at=excluded.updated_at
        """, [.text(account.id), .text(account.name.trimmingCharacters(in: .whitespacesAndNewlines)), .text(account.type.rawValue),
               .integer(account.openingBalanceCents), .integer(account.balanceAdjustmentCents ?? 0),
               account.creditLimitCents.map(SQLValue.integer) ?? .null,
               account.dueAmountCents.map(SQLValue.integer) ?? .null,
               account.nextDueDate.map { .real($0.timeIntervalSince1970) } ?? .null,
               account.effectiveRepaymentDay.map { .integer(Int64($0)) } ?? .null,
               .integer(account.repaymentReminderIsEnabled ? 1 : 0),
               customLabel.map { $0.isEmpty ? SQLValue.null : .text($0) } ?? .null,
               account.cardIcon.map { .text($0.rawValue) } ?? .null,
               account.cardColor.map { .text($0.rawValue) } ?? .null,
               cardIconPNG.map(SQLValue.text) ?? .null,
               providerName.map { $0.isEmpty ? SQLValue.null : .text($0) } ?? .null,
               .integer(account.isActive ? 1 : 0), .integer(Int64(account.sortOrder)),
               .real(account.createdAt.timeIntervalSince1970), .real(account.updatedAt.timeIntervalSince1970),
               account.cardIconOverride.map { .text($0.rawValue) } ?? .null])
    }

    func allAccounts(includeInactive: Bool = true) throws -> [BookAccount] {
        let filter = includeInactive ? "" : "WHERE is_active=1"
        return try rows("SELECT * FROM accounts \(filter) ORDER BY is_active DESC,sort_order,name,id")?.compactMap(Self.account) ?? []
    }

    func reorderActiveAccounts(_ orderedIDs: [String]) throws {
        let activeIDs = Set(try allAccounts(includeInactive: false).map(\.id))
        guard orderedIDs.count == activeIDs.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == activeIDs else { throw StoreError.invalidAccount }
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            let timestamp = Date().timeIntervalSince1970
            for (order, id) in orderedIDs.enumerated() {
                try run("UPDATE accounts SET sort_order=?,updated_at=? WHERE id=? AND is_active=1",
                        [.integer(Int64(order)), .real(timestamp), .text(id)])
            }
            try Self.execute(db, "COMMIT")
        } catch {
            try? Self.execute(db, "ROLLBACK")
            throw error
        }
    }

    func account(id: String) throws -> BookAccount? {
        try rows("SELECT * FROM accounts WHERE id=? LIMIT 1", [.text(id)])?.first.flatMap(Self.account)
    }

    func allTransfers() throws -> [AccountTransfer] {
        try rows("SELECT * FROM account_transfers ORDER BY occurred_at DESC,id")?.compactMap(Self.transfer) ?? []
    }

    @discardableResult
    func saveBorrowing(_ liability: BookAccount, cents: Int64, toAccountID: String) throws -> BookAccount {
        guard liability.type == .otherDebt, liability.isActive,
              liability.openingBalanceCents == 0, (liability.balanceAdjustmentCents ?? 0) == 0,
              liability.createdAt.timeIntervalSince1970.isFinite, liability.updatedAt.timeIntervalSince1970.isFinite,
              cents > 0, cents <= Self.maximumCents else { throw StoreError.invalidAccount }
        return try transaction {
            let transferID = "borrow-\(liability.id)"
            if let existing = try account(id: liability.id) {
                // A repeated save of the same form is a no-op, even after a failed UI refresh.
                guard existing.type == .otherDebt, existing.name == liability.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      let transfer = try rows("SELECT * FROM account_transfers WHERE id=? LIMIT 1", [.text(transferID)])?.first.flatMap(Self.transfer),
                      transfer.fromAccountID == existing.id, transfer.toAccountID == toAccountID,
                      transfer.cents == cents else { throw StoreError.conflictingImport }
                return existing
            }
            guard let recipient = try account(id: toAccountID), recipient.isActive,
                  !recipient.type.isLiability else { throw StoreError.invalidAccount }
            let current = try accountOverview().balances[recipient.id] ?? recipient.openingBalanceCents
            let (received, overflow) = current.addingReportingOverflow(cents)
            guard !overflow, received <= Self.maximumCents else { throw AppError.invalidAmount }
            try save(liability)
            // Zero opening debt + one linked movement is the sole source of both balance changes.
            try run("""
            INSERT INTO account_transfers(id,cents,from_account_id,to_account_id,occurred_at,note,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.text(transferID), .integer(cents), .text(liability.id), .text(recipient.id),
                   .real(liability.createdAt.timeIntervalSince1970), .text("借入"),
                   .real(liability.createdAt.timeIntervalSince1970), .real(liability.updatedAt.timeIntervalSince1970)])
            return liability
        }
    }

    func accountOverview() throws -> AccountOverview {
        let accounts = try allAccounts()
        let entries = try rows("""
        SELECT * FROM entries WHERE account_id IS NOT NULL
          AND (import_batch_id IS NULL OR EXISTS (
            SELECT 1 FROM import_batches b WHERE b.id=entries.import_batch_id AND b.state IN ('completed','completedWithConflicts')
          ))
        ORDER BY occurred_at,id
        """)?.compactMap(Self.entry) ?? []
        let transfers = try allTransfers()
        return AccountOverview(accounts: accounts,
                               balances: AccountLedgerMath.balances(accounts: accounts, entries: entries, transfers: transfers),
                               transfers: transfers)
    }

    func save(_ transfer: AccountTransfer) throws {
        guard transfer.cents > 0, transfer.cents <= Self.maximumCents,
              transfer.occurredAt.timeIntervalSince1970.isFinite,
              !transfer.fromAccountID.isEmpty, !transfer.toAccountID.isEmpty,
              transfer.fromAccountID != transfer.toAccountID else { throw StoreError.invalidTransfer }
        try transaction {
            guard let source = try account(id: transfer.fromAccountID),
                  let target = try account(id: transfer.toAccountID),
                  !source.type.isLiability, source.isActive, target.isActive else { throw StoreError.invalidTransfer }
            if target.type.isLiability {
                let current = try accountOverview().balances[target.id] ?? target.openingBalanceCents
                guard current >= transfer.cents else { throw StoreError.invalidTransfer }
            }
            let dueReduction = target.type.isLiability
                ? min(target.dueAmountCents ?? 0, transfer.cents) : 0
            try run("""
            INSERT INTO account_transfers(id,cents,from_account_id,to_account_id,occurred_at,note,due_amount_reduction_cents,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(transfer.id), .integer(transfer.cents), .text(transfer.fromAccountID), .text(transfer.toAccountID),
                   .real(transfer.occurredAt.timeIntervalSince1970), .text(transfer.note), .integer(dueReduction),
                   .real(transfer.createdAt.timeIntervalSince1970), .real(transfer.updatedAt.timeIntervalSince1970)])
            if target.type.isLiability {
                try run("UPDATE accounts SET due_amount_cents=MAX(0,due_amount_cents-?),updated_at=? WHERE id=? AND due_amount_cents IS NOT NULL",
                        [.integer(dueReduction), .real(Date().timeIntervalSince1970), .text(target.id)])
            }
        }
    }

    func deleteTransfer(_ transfer: AccountTransfer) throws {
        try transaction {
            guard let current = try rows("SELECT * FROM account_transfers WHERE id=? LIMIT 1", [.text(transfer.id)])?.first.flatMap(Self.transfer),
                  current == transfer else { throw StoreError.invalidTransfer }
            try run("DELETE FROM account_transfers WHERE id=?", [.text(transfer.id)])
            if let account = try self.account(id: current.toAccountID), account.type.isLiability,
               current.dueAmountReductionCents > 0 {
                try run("UPDATE accounts SET due_amount_cents=MIN(?,due_amount_cents+?),updated_at=? WHERE id=? AND due_amount_cents IS NOT NULL",
                        [.integer(Self.maximumCents), .integer(current.dueAmountReductionCents), .real(Date().timeIntervalSince1970), .text(account.id)])
            }
        }
    }

    func save(_ entry: BookEntry) throws {
        var entry = entry
        guard entry.cents > 0, entry.cents <= Self.maximumCents else { throw AppError.invalidAmount }
        guard (entry.currencyCode ?? "CNY") == "CNY" else { throw StoreError.unsupportedCurrency(entry.currencyCode ?? "") }
        try transaction {
            if let category = try allCategories().first(where: { $0.id == entry.categoryID }) {
                guard category.kind == (entry.kind == .income ? "income" : "expense") else { throw StoreError.invalidEntry }
                entry.categorySnapshot = nil
            } else {
                // Only editing an existing record, undoing a deletion, or a linked refund
                // may keep a removed category. New unrelated entries must choose a live one.
                let prior = try self.entry(id: entry.id)
                let original = try entry.originalEntryID.flatMap { try self.entry(id: $0) }
                let snapshot = prior?.historicalCategory ?? (entry.kind == .refund ? original?.historicalCategory : nil)
                    ?? (entry.recordVersion != nil ? entry.historicalCategory : nil)
                guard let snapshot, snapshot.id == entry.categoryID,
                      snapshot.kind == (entry.kind == .income ? "income" : "expense") else { throw StoreError.invalidEntry }
                entry.categorySnapshot = snapshot
            }
            if let accountID = entry.accountID {
                guard let account = try self.account(id: accountID),
                      !(account.type.isLiability && entry.kind == .income) else { throw StoreError.invalidAccount }
            }
            guard let db else { throw StoreError.unavailable }
            if let version = entry.recordVersion {
                try run("""
                UPDATE entries SET cents=?,kind=?,occurred_at=?,local_day=?,category_id=?,icon_choice=?,note=?,account_id=?,
                  source_id=?,original_entry_id=?,updated_at=?,accounting_time_zone=COALESCE(?,accounting_time_zone),
                  currency_code=?,record_version=record_version+1,import_batch_id=?,confirmed_draft_id=?,category_snapshot=?
                WHERE id=? AND record_version=?
                """, [.integer(entry.cents), .text(entry.kind.rawValue), .real(entry.occurredAt.timeIntervalSince1970),
                       .text(entry.stableLocalDayKey), .text(entry.categoryID), .text(entry.iconChoice), .text(entry.note),
                       entry.accountID.map(SQLValue.text) ?? .null,
                       entry.sourceID.map(SQLValue.text) ?? .null, entry.originalEntryID.map(SQLValue.text) ?? .null,
                       .real(entry.updatedAt.timeIntervalSince1970), entry.accountingTimeZone.map(SQLValue.text) ?? .null,
                       .text(entry.currencyCode ?? "CNY"), entry.importBatchID.map(SQLValue.text) ?? .null,
                       entry.confirmedDraftID.map(SQLValue.text) ?? .null, try Self.snapshotValue(entry.categorySnapshot), .text(entry.id), .integer(version)])
                if sqlite3_changes(db) != 1 {
                    if try self.entry(id: entry.id) != nil { throw StoreError.staleEntry }
                    try insertEntry(entry)
                }
            } else {
                guard try self.entry(id: entry.id) == nil else { throw StoreError.staleEntry }
                try insertEntry(entry)
            }
            try validateRefundRelations()
        }
    }

    @discardableResult
    func save(_ draft: ReviewDraft) throws -> ReviewDraft {
        var saved = draft
        let now = Date()
        saved.updatedAt = now
        if let current = try self.draft(id: draft.id) {
            guard let expectedVersion = draft.recordVersion,
                  current.recordVersion == expectedVersion else { throw StoreError.staleDraft }
            try run("""
            UPDATE review_drafts SET state=?,cents=?,kind=?,occurred_at=?,category_id=?,note=?,image_path=?,
              recognized_text=?,source_id=?,error_text=?,updated_at=?,record_version=record_version+1,
              confirmed_entry_id=?,input_digest=?,user_confirmed_fields=?,claim_token=?,claim_expires_at=?,candidate_confidence=?,amount_text=?
            WHERE id=? AND record_version=?
            """, [.text(draft.state.rawValue), draft.cents.map(SQLValue.integer) ?? .null,
                   draft.kind.map { .text($0.rawValue) } ?? .null, .real(draft.occurredAt.timeIntervalSince1970),
                   draft.categoryID.map(SQLValue.text) ?? .null, .text(draft.note), draft.imagePath.map(SQLValue.text) ?? .null,
                   .text(draft.recognizedText), draft.sourceID.map(SQLValue.text) ?? .null,
                   draft.errorText.map(SQLValue.text) ?? .null, .real(now.timeIntervalSince1970),
                   draft.confirmedEntryID.map(SQLValue.text) ?? .null, draft.inputDigest.map(SQLValue.text) ?? .null,
                   .text(Self.encodeConfirmedFields(draft.userConfirmedFields)), draft.claimToken.map(SQLValue.text) ?? .null,
                   draft.claimExpiresAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                   .text(Self.encodeConfidence(draft.candidateConfidence)),
                   draft.amountText.map(SQLValue.text) ?? .null,
                   .text(draft.id), .integer(expectedVersion)])
            saved.recordVersion = expectedVersion + 1
        } else {
            try run("""
            INSERT INTO review_drafts(id,state,cents,kind,occurred_at,category_id,note,image_path,
              recognized_text,source_id,error_text,created_at,updated_at,record_version,confirmed_entry_id,
              input_digest,user_confirmed_fields,claim_token,claim_expires_at,candidate_confidence,amount_text) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(draft.id), .text(draft.state.rawValue), draft.cents.map(SQLValue.integer) ?? .null,
                   draft.kind.map { .text($0.rawValue) } ?? .null, .real(draft.occurredAt.timeIntervalSince1970),
                   draft.categoryID.map(SQLValue.text) ?? .null, .text(draft.note), draft.imagePath.map(SQLValue.text) ?? .null,
                   .text(draft.recognizedText), draft.sourceID.map(SQLValue.text) ?? .null,
                   draft.errorText.map(SQLValue.text) ?? .null, .real(draft.createdAt.timeIntervalSince1970),
                   .real(now.timeIntervalSince1970), .integer(draft.recordVersion ?? 1),
                   draft.confirmedEntryID.map(SQLValue.text) ?? .null, draft.inputDigest.map(SQLValue.text) ?? .null,
                   .text(Self.encodeConfirmedFields(draft.userConfirmedFields)), draft.claimToken.map(SQLValue.text) ?? .null,
                   draft.claimExpiresAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                   .text(Self.encodeConfidence(draft.candidateConfidence)), draft.amountText.map(SQLValue.text) ?? .null])
            saved.recordVersion = draft.recordVersion ?? 1
        }
        return saved
    }

    func entries(inMonth month: Date) throws -> [BookEntry] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let lower = CounterFormat.localDayKey(start)
        let upper = CounterFormat.localDayKey(end)
        return try rows("SELECT * FROM entries WHERE local_day>=? AND local_day<? AND (import_batch_id IS NULL OR EXISTS (SELECT 1 FROM import_batches b WHERE b.id=entries.import_batch_id AND b.state IN ('completed','completedWithConflicts'))) ORDER BY local_day DESC,occurred_at DESC,id",
                        [.text(lower), .text(upper)])?.compactMap(Self.entry) ?? []
    }

    func snapshot(in month: Date) throws -> LedgerSnapshot {
        try run("BEGIN DEFERRED")
        do {
            try bootstrap()
            let categories = try allCategories()
            let entries = try entries(inMonth: month)
            let drafts = try activeDrafts()
            let snapshot = LedgerSnapshot(monthKey: CounterFormat.monthKey(month), entries: entries,
                                          categories: categories, drafts: drafts)
            try run("COMMIT")
            return snapshot
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func allEntries() throws -> [BookEntry] {
        try rows("SELECT * FROM entries ORDER BY occurred_at,id")?.compactMap(Self.entry) ?? []
    }

    func recentEntries(accountID: String, limit: Int = 30) throws -> [BookEntry] {
        let boundedLimit = max(1, min(limit, 100))
        return try rows(
            "SELECT * FROM entries WHERE account_id=? AND (import_batch_id IS NULL OR EXISTS (SELECT 1 FROM import_batches b WHERE b.id=entries.import_batch_id AND b.state IN ('completed','completedWithConflicts'))) ORDER BY local_day DESC,occurred_at DESC,id DESC LIMIT ?",
            [.text(accountID), .integer(Int64(boundedLimit))]
        )?.compactMap(Self.entry) ?? []
    }

    func entry(id: String) throws -> BookEntry? {
        try rows("SELECT * FROM entries WHERE id=? LIMIT 1", [.text(id)])?.first.flatMap(Self.entry)
    }

    func entry(sourceID: String) throws -> BookEntry? {
        try rows("SELECT * FROM entries WHERE source_id=? LIMIT 1", [.text(sourceID)])?.first.flatMap(Self.entry)
    }

    func activeDrafts() throws -> [ReviewDraft] {
        try rows("SELECT * FROM review_drafts WHERE state IN ('queued','recognizing','needsReview','failed') ORDER BY created_at DESC,id")?.compactMap(Self.draft) ?? []
    }

    func allDrafts() throws -> [ReviewDraft] {
        try rows("SELECT * FROM review_drafts ORDER BY created_at,id")?.compactMap(Self.draft) ?? []
    }

    func draft(sourceID: String) throws -> ReviewDraft? {
        try rows("SELECT * FROM review_drafts WHERE source_id=? LIMIT 1", [.text(sourceID)])?.first.flatMap(Self.draft)
    }

    func draft(id: String) throws -> ReviewDraft? {
        try rows("SELECT * FROM review_drafts WHERE id=? LIMIT 1", [.text(id)])?.first.flatMap(Self.draft)
    }

    func claimRecognition(id: String, lease: TimeInterval = 120) throws -> ReviewDraft? {
        try transaction {
            guard var current = try draft(id: id) else { return nil }
            let now = Date()
            let available: Bool
            switch current.state {
            case .queued: available = true
            case .recognizing: available = current.claimExpiresAt.map { $0 <= now } ?? true
            case .failed: available = true
            case .needsReview, .confirmed, .dismissed: available = false
            }
            guard available else { return nil }
            current.state = .recognizing
            current.errorText = nil
            current.claimToken = UUID().uuidString.lowercased()
            current.claimExpiresAt = now.addingTimeInterval(lease)
            return try save(current)
        }
    }

    nonisolated func summary(in entries: [BookEntry]) -> MonthSummary {
        LedgerMath.summary(entries)
    }

    nonisolated func categorySpending(in entries: [BookEntry], categories: [BookCategory]) -> [CategorySpend] {
        LedgerMath.categorySpending(entries, categories: categories)
    }

    func delete(_ entry: BookEntry) throws {
        try transaction {
            guard let current = try self.entry(id: entry.id),
                  let expectedVersion = entry.recordVersion,
                  current.recordVersion == expectedVersion else { throw StoreError.staleEntry }
            let linked = try rows("SELECT id FROM entries WHERE original_entry_id=? AND kind='refund' LIMIT 1", [.text(entry.id)])?.isEmpty == false
            guard !linked else { throw StoreError.entryHasRefunds }
            try run("DELETE FROM entries WHERE id=? AND record_version=?", [.text(entry.id), .integer(expectedVersion)])
            guard let db, sqlite3_changes(db) == 1 else { throw StoreError.staleEntry }
        }
    }

    func remainingRefundCents(for originalID: String) throws -> Int64 {
        guard let original = try entry(id: originalID), original.kind == .expense else { throw StoreError.invalidRefundTarget }
        let total = try rows("SELECT COALESCE(SUM(cents),0) AS cents FROM entries WHERE kind='refund' AND original_entry_id=?", [.text(originalID)])?.first?["cents"] as? Int64 ?? 0
        return max(0, original.cents - total)
    }

    func commitDraft(_ draft: ReviewDraft, entry: BookEntry) throws -> BookEntry {
        try transaction {
            guard let current = try self.draft(id: draft.id) else { throw StoreError.missingDraft }
            if current.state == .confirmed {
                guard let prior = try self.entry(id: entry.id) else { throw StoreError.inconsistentDraft }
                return prior
            }
            guard current.state != .dismissed else { throw StoreError.draftAlreadyClosed }
            guard draft.recordVersion == current.recordVersion else { throw StoreError.staleDraft }
            guard draft.id == current.id, entry.id == "entry-\(current.id)",
                  entry.confirmedDraftID == current.id,
                  entry.cents > 0, entry.cents <= Self.maximumCents,
                  draft.cents == entry.cents, draft.kind == entry.kind,
                  draft.occurredAt == entry.occurredAt, draft.categoryID == entry.categoryID,
                  draft.note == entry.note, draft.sourceID == entry.sourceID,
                  entry.categoryID == draft.categoryID else { throw StoreError.invalidEntry }
            if let existing = try self.entry(id: entry.id) {
                if CounterCSV.equivalent(existing, entry),
                   existing.confirmedDraftID == nil || existing.confirmedDraftID == current.id {
                    var linkedEntry = existing
                    linkedEntry.confirmedDraftID = current.id
                    if existing.confirmedDraftID == nil { try save(linkedEntry) }
                    var updated = draft
                    updated.state = .confirmed
                    updated.errorText = nil
                    updated.recordVersion = current.recordVersion
                    updated.confirmedEntryID = existing.id
                    _ = try save(updated)
                    return linkedEntry
                }
                throw StoreError.conflictingImport
            }
            try insertEntry(entry)
            var updated = draft
            updated.state = .confirmed
            updated.errorText = nil
            updated.recordVersion = current.recordVersion
            updated.confirmedEntryID = entry.id
            _ = try save(updated)
            return entry
        }
    }

    func dismissDraft(_ draft: ReviewDraft) throws {
        try transaction {
            guard let current = try self.draft(id: draft.id) else { throw StoreError.missingDraft }
            if current.state == .dismissed { return }
            guard current.state != .confirmed else { throw StoreError.draftAlreadyClosed }
            var updated = current
            updated.state = .dismissed
            updated.errorText = nil
            try save(updated)
        }
    }

    func saveImported(_ entries: [BookEntry], categories: [BookCategory] = []) throws -> ImportCommitResult {
        var batch = try prepareImportBatch(entries, categories: categories, inputRows: entries.count, sourceDigest: "")
        while !batch.isComplete { batch = try processImportBatch(id: batch.id) }
        return ImportCommitResult(batchID: batch.id, inserted: batch.inserted, exactDuplicates: batch.duplicates,
                                  conflicts: batch.conflicts, invalid: batch.invalid)
    }

    func prepareImportBatch(_ entries: [BookEntry], categories: [BookCategory], inputRows: Int,
                            sourceDigest: String, preflightDuplicates: Int = 0,
                            preflightConflicts: Int = 0, preflightInvalid: Int = 0) throws -> ImportBatch {
        guard inputRows >= entries.count, preflightDuplicates >= 0, preflightConflicts >= 0,
              preflightInvalid >= 0,
              entries.count + preflightDuplicates + preflightConflicts + preflightInvalid == inputRows else {
            throw StoreError.invalidImportBatch
        }
        let id = UUID().uuidString.lowercased()
        let now = Date()
        let payload = ImportBatchPayload(entries: entries, categories: categories, inputRows: inputRows,
                                          preflightDuplicates: preflightDuplicates,
                                          preflightConflicts: preflightConflicts, preflightInvalid: preflightInvalid)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else { throw StoreError.invalidImportBatch }
        try transaction {
            try run("""
            INSERT INTO import_batches(id,source_digest,created_at,updated_at,input_rows,duplicate_count,conflict_count,invalid_count,state,payload_json)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [.text(id), .text(sourceDigest), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
                    .integer(Int64(inputRows)), .integer(Int64(preflightDuplicates)), .integer(Int64(preflightConflicts)),
                    .integer(Int64(preflightInvalid)), .text("prepared"), .text(payloadJSON)])
        }
        return ImportBatch(id: id, sourceDigest: sourceDigest, createdAt: now, updatedAt: now,
                           inputRows: inputRows, inserted: 0, duplicates: preflightDuplicates,
                           conflicts: preflightConflicts, invalid: preflightInvalid,
                           cursor: 0, state: "prepared", undoConflicts: 0)
    }

    func processImportBatch(id: String, chunkSize: Int = 250) throws -> ImportBatch {
        guard (1...5_000).contains(chunkSize) else { throw StoreError.invalidImportBatch }
        return try transaction {
            guard var batch = try importBatch(id: id),
                  let json = try rows("SELECT payload_json FROM import_batches WHERE id=?", [.text(id)])?.first?["payload_json"] as? String,
                  let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(ImportBatchPayload.self, from: data) else {
                throw StoreError.invalidImportBatch
            }
            guard batch.state == "prepared" || batch.state == "running" else {
                if batch.state == "completed" { return batch }
                throw StoreError.invalidImportBatch
            }
            if batch.cursor == 0 {
                for category in payload.categories {
                    guard !category.id.isEmpty, !category.name.isEmpty,
                          ["expense", "income"].contains(category.kind) else { throw StoreError.invalidEntry }
                    try save(category)
                }
            }
            let knownCategories = Dictionary(uniqueKeysWithValues: try allCategories().map { ($0.id, $0) })
            let upper = min(payload.entries.count, batch.cursor + chunkSize)
            if batch.cursor < upper {
                for source in payload.entries[batch.cursor..<upper] {
                    guard source.cents > 0, source.cents <= Self.maximumCents,
                          (source.currencyCode ?? "CNY") == "CNY",
                          !source.id.isEmpty, source.id.count <= 128,
                          source.occurredAt.timeIntervalSince1970.isFinite,
                          let category = knownCategories[source.categoryID],
                          category.kind == (source.kind == .income ? "income" : "expense") else {
                        batch.invalid += 1
                        continue
                    }
                    if let accountID = source.accountID {
                        guard let account = try self.account(id: accountID),
                              !(account.type.isLiability && source.kind == .income) else {
                            batch.invalid += 1
                            continue
                        }
                    }
                    if let prior = try entry(id: source.id) {
                        if CounterCSV.equivalent(prior, source) { batch.duplicates += 1 }
                        else { batch.conflicts += 1 }
                        continue
                    }
                    if let sourceID = source.sourceID, let prior = try entry(sourceID: sourceID) {
                        if CounterCSV.equivalent(prior, source) { batch.duplicates += 1 }
                        else { batch.conflicts += 1 }
                        continue
                    }
                    var imported = source
                    imported.importBatchID = id
                    imported.recordVersion = 1
                    try insertEntry(imported)
                    batch.inserted += 1
                }
            }
            batch.cursor = upper
            batch.updatedAt = Date()
            batch.state = upper >= payload.entries.count ? "completed" : "running"
            if batch.state == "completed" {
                guard batch.inserted + batch.duplicates + batch.conflicts + batch.invalid == batch.inputRows else {
                    throw StoreError.invalidImportBatch
                }
                try validateRefundRelations()
            }
            let payloadValue: SQLValue = batch.state == "completed" ? .null : .text(json)
            try run("""
            UPDATE import_batches SET updated_at=?,inserted_count=?,duplicate_count=?,conflict_count=?,invalid_count=?,cursor=?,state=?,payload_json=? WHERE id=?
            """, [.real(batch.updatedAt.timeIntervalSince1970), .integer(Int64(batch.inserted)), .integer(Int64(batch.duplicates)),
                    .integer(Int64(batch.conflicts)), .integer(Int64(batch.invalid)), .integer(Int64(batch.cursor)),
                    .text(batch.state), payloadValue, .text(id)])
            return batch
        }
    }

    func importBatches(limit: Int = 50) throws -> [ImportBatch] {
        try rows("SELECT * FROM import_batches ORDER BY created_at DESC,id DESC LIMIT ?", [.integer(Int64(max(1, limit)))])?
            .compactMap(Self.decodeImportBatch) ?? []
    }

    func pendingImportBatches() throws -> [ImportBatch] {
        try rows("SELECT * FROM import_batches WHERE state IN ('prepared','running') ORDER BY created_at,id")?
            .compactMap(Self.decodeImportBatch) ?? []
    }

    func importBatch(id: String) throws -> ImportBatch? {
        try rows("SELECT * FROM import_batches WHERE id=? LIMIT 1", [.text(id)])?.first.flatMap(Self.decodeImportBatch)
    }

    func retryImportBatch(id: String) throws {
        try transaction {
            guard let batch = try importBatch(id: id), batch.state == "failed",
                  let json = try rows("SELECT payload_json FROM import_batches WHERE id=?", [.text(id)])?.first?["payload_json"] as? String,
                  let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(ImportBatchPayload.self, from: data) else {
                throw StoreError.invalidImportBatch
            }
            try run("UPDATE import_batches SET updated_at=?,inserted_count=0,duplicate_count=?,conflict_count=?,invalid_count=?,cursor=0,state='prepared' WHERE id=?",
                    [.real(Date().timeIntervalSince1970), .integer(Int64(payload.preflightDuplicates)),
                     .integer(Int64(payload.preflightConflicts)), .integer(Int64(payload.preflightInvalid)), .text(id)])
        }
    }

    func abortImportBatch(id: String) throws {
        try transaction {
            guard let batch = try importBatch(id: id), batch.state == "prepared" || batch.state == "running",
                  let json = try rows("SELECT payload_json FROM import_batches WHERE id=?", [.text(id)])?.first?["payload_json"] as? String,
                  let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(ImportBatchPayload.self, from: data) else {
                throw StoreError.invalidImportBatch
            }
            let imported = try rows("SELECT * FROM entries WHERE import_batch_id=? ORDER BY CASE WHEN kind='refund' THEN 0 ELSE 1 END, id", [.text(id)])?.compactMap(Self.entry) ?? []
            for entry in imported {
                guard let version = entry.recordVersion, version == 1 else { continue }
                try run("DELETE FROM entries WHERE id=? AND import_batch_id=? AND record_version=1", [.text(entry.id), .text(id)])
            }
            let preflightDuplicates = payload.preflightDuplicates
            let preflightConflicts = payload.preflightConflicts
            let preflightInvalid = payload.preflightInvalid
            try run("UPDATE import_batches SET updated_at=?,inserted_count=0,duplicate_count=?,conflict_count=?,invalid_count=?,cursor=0,state='failed' WHERE id=?",
                    [.real(Date().timeIntervalSince1970), .integer(Int64(preflightDuplicates)), .integer(Int64(preflightConflicts)),
                     .integer(Int64(preflightInvalid)), .text(id)])
        }
    }

    func undoImportBatch(id: String) throws -> ImportUndoResult {
        try transaction {
            guard var batch = try importBatch(id: id), batch.state == "completed" || batch.state == "completedWithConflicts" else {
                throw StoreError.invalidImportBatch
            }
            let imported = try rows("SELECT * FROM entries WHERE import_batch_id=? ORDER BY CASE WHEN kind='refund' THEN 0 ELSE 1 END, id", [.text(id)])?.compactMap(Self.entry) ?? []
            var deleted = 0
            var conflicts = 0
            for entry in imported {
                guard entry.recordVersion == 1 else { conflicts += 1; continue }
                if entry.kind != .refund {
                    let linked = try rows("SELECT id FROM entries WHERE original_entry_id=? LIMIT 1", [.text(entry.id)])?.isEmpty == false
                    guard !linked else { conflicts += 1; continue }
                }
                try run("DELETE FROM entries WHERE id=? AND import_batch_id=? AND record_version=1", [.text(entry.id), .text(id)])
                if let db, sqlite3_changes(db) == 1 { deleted += 1 } else { conflicts += 1 }
            }
            batch.updatedAt = Date()
            batch.undoConflicts = conflicts
            let remaining = try rows("SELECT count(*) AS count FROM entries WHERE import_batch_id=?", [.text(id)])?.first?["count"] as? Int64 ?? 0
            batch.state = remaining == 0 ? "undone" : "completedWithConflicts"
            try run("UPDATE import_batches SET updated_at=?,state=?,undo_conflicts=? WHERE id=?",
                    [.real(batch.updatedAt.timeIntervalSince1970), .text(batch.state), .integer(Int64(conflicts)), .text(id)])
            try validateRefundRelations()
            return ImportUndoResult(deleted: deleted, conflicts: conflicts)
        }
    }

    func backup() throws -> CounterBackup {
        try run("BEGIN")
        do {
            let rowCounts = try rows("SELECT (SELECT count(*) FROM entries) AS entries,(SELECT count(*) FROM review_drafts) AS drafts,(SELECT count(*) FROM categories) AS categories,(SELECT count(*) FROM accounts) AS accounts,(SELECT count(*) FROM account_transfers) AS transfers")?.first
            guard Int((rowCounts?["entries"] as? Int64) ?? 0) <= Self.maximumBackupEntries,
                  Int((rowCounts?["drafts"] as? Int64) ?? 0) <= Self.maximumBackupDrafts,
                  Int((rowCounts?["categories"] as? Int64) ?? 0) <= Self.maximumBackupCategories,
                  Int((rowCounts?["accounts"] as? Int64) ?? 0) <= 1_000,
                  Int((rowCounts?["transfers"] as? Int64) ?? 0) <= Self.maximumBackupEntries else {
                throw StoreError.backupResourceLimit
            }
            let categories = try allCategories()
            let entries = try allEntries()
            let drafts = try allDrafts()
            let accounts = try allAccounts()
            let transfers = try allTransfers()
            let batches = try rows("SELECT * FROM import_batches ORDER BY created_at,id")?.compactMap(Self.decodeImportBatch) ?? []
            guard !batches.contains(where: { $0.state == "prepared" || $0.state == "running" }) else {
                throw StoreError.pendingImportBatch
            }
            var media: [String: Data] = [:]
            var mediaDigests: [String: String] = [:]
            var mediaBytes = 0
            for draft in drafts {
                guard let path = draft.imagePath else { continue }
                let imageURL = URL(fileURLWithPath: path)
                let fileSize = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                guard let fileSize, fileSize > 0, fileSize <= SharedInboxItem.maximumImageBytes else {
                    throw StoreError.missingBackupMedia(draft.id)
                }
                let data = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
                let (total, overflow) = mediaBytes.addingReportingOverflow(data.count)
                guard !overflow, total <= Self.maximumBackupMediaBytes, Self.validBackupImage(data) else {
                    throw StoreError.backupResourceLimit
                }
                mediaBytes = total
                media[draft.id] = data
                mediaDigests[draft.id] = CaptureService.digest(data)
            }
            try run("COMMIT")
            let backup = CounterBackup(categories: categories, entries: entries, drafts: drafts, media: media,
                                       importBatches: batches, mediaDigests: mediaDigests,
                                       accounts: accounts, transfers: transfers)
            try Self.validate(backup)
            return backup
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func validateBackup(_ backup: CounterBackup) throws { try Self.validate(backup) }

    func previewRestore(_ backup: CounterBackup) throws -> CounterRestorePreview {
        try Self.validate(backup)
        let currentCategories = Dictionary(try allCategories().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentEntries = try allEntries()
        let entriesByID = Dictionary(currentEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entriesBySource = Dictionary(currentEntries.compactMap { entry in entry.sourceID.map { ($0, entry) } },
                                         uniquingKeysWith: { first, _ in first })
        let currentDrafts = try allDrafts()
        let draftsByID = Dictionary(currentDrafts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let draftsBySource = Dictionary(currentDrafts.compactMap { draft in draft.sourceID.map { ($0, draft) } },
                                        uniquingKeysWith: { first, _ in first })
        let currentBatches = Dictionary((try rows("SELECT * FROM import_batches") ?? []).compactMap(Self.decodeImportBatch).map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let currentAccounts = Dictionary(try allAccounts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentTransfers = Dictionary(try allTransfers().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = CounterRestorePreview(newEntries: 0, exactEntries: 0, conflictingEntries: 0,
                                           newDrafts: 0, exactDrafts: 0, conflictingDrafts: 0,
                                           newCategories: 0, conflictingCategories: 0, conflictingBatches: 0,
                                           imageCount: backup.media.count,
                                           imageBytes: backup.media.values.reduce(0) { $0 + $1.count }, conflicts: [])
        func recordConflict(_ value: String) {
            if result.conflicts.count < 500 { result.conflicts.append(value) }
        }
        for category in backup.categories {
            if let current = currentCategories[category.id] {
                if current == category { continue }
                result.conflictingCategories += 1
                recordConflict("分类编号 \(category.id)：当前与备份内容不同")
            } else { result.newCategories += 1 }
        }
        for account in backup.accounts ?? [] {
            if let current = currentAccounts[account.id] {
                if current == account { continue }
                result.conflictingAccounts += 1
                recordConflict("账户编号 \(account.id)：当前与备份内容不同")
            } else { result.newAccounts += 1 }
        }
        for entry in backup.entries {
            let byID = entriesByID[entry.id]
            let bySource = entry.sourceID.flatMap { entriesBySource[$0] }
            if let byID {
                if CounterCSV.equivalent(byID, entry), bySource == nil || bySource?.id == byID.id {
                    result.exactEntries += 1
                } else {
                    result.conflictingEntries += 1
                    recordConflict("账单编号 \(entry.id)：当前与备份明细或来源编号冲突")
                }
            } else if let bySource {
                if CounterCSV.equivalent(bySource, entry) { result.exactEntries += 1 }
                else {
                    result.conflictingEntries += 1
                    recordConflict("账单来源 \(entry.sourceID ?? "")：当前与备份内容不同")
                }
            } else { result.newEntries += 1 }
        }
        for draft in backup.drafts {
            let byID = draftsByID[draft.id]
            let bySource = draft.sourceID.flatMap { draftsBySource[$0] }
            if let byID {
                var current = byID
                var incoming = draft
                current.imagePath = nil
                incoming.imagePath = nil
                if current == incoming, bySource == nil || bySource?.id == byID.id { result.exactDrafts += 1 }
                else {
                    result.conflictingDrafts += 1
                    recordConflict("待记账编号 \(draft.id)：当前与备份内容不同")
                }
            } else if let bySource {
                var incoming = draft
                var current = bySource
                incoming.imagePath = nil
                current.imagePath = nil
                if current == incoming { result.exactDrafts += 1 }
                else {
                    result.conflictingDrafts += 1
                    recordConflict("待记账来源 \(draft.sourceID ?? "")：当前与备份内容不同")
                }
            } else { result.newDrafts += 1 }
        }
        for batch in backup.importBatches ?? [] {
            if let current = currentBatches[batch.id], current != batch {
                result.conflictingBatches += 1
                recordConflict("导入批次编号 \(batch.id)：当前与备份结果不同")
            }
        }
        for transfer in backup.transfers ?? [] {
            if let current = currentTransfers[transfer.id] {
                if current == transfer { continue }
                result.conflictingTransfers += 1
                recordConflict("转账编号 \(transfer.id)：当前与备份内容不同")
            } else { result.newTransfers += 1 }
        }
        return result
    }

    func restore(_ backup: CounterBackup, replace: Bool) throws {
        try Self.validate(backup)
        if !replace, !(try previewRestore(backup)).canMerge { throw StoreError.conflictingImport }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counter/ReviewImages", isDirectory: true)
        let restoreID = UUID().uuidString.lowercased()
        let staging = root.appendingPathComponent(".restore-\(restoreID)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var installed: [URL] = []
        do {
            var mediaPaths: [String: String] = [:]
            for (draftID, data) in backup.media.sorted(by: { $0.key < $1.key }) {
                let fileExtension = SharedInboxItem.imageExtension(for: data)
                let name = "\(restoreID)-\(draftID).\(fileExtension)"
                let stagedURL = staging.appendingPathComponent(name)
                let finalURL = root.appendingPathComponent(name)
                try data.write(to: stagedURL, options: .atomic)
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
                installed.append(finalURL)
                mediaPaths[draftID] = finalURL.path
            }
            try transaction {
                if replace {
                    try run("DELETE FROM account_transfers")
                    try run("DELETE FROM entries")
                    try run("DELETE FROM accounts")
                    try run("DELETE FROM review_drafts")
                    try run("DELETE FROM import_batches")
                    try run("DELETE FROM categories")
                }
                for category in backup.categories { try save(category) }
                for account in backup.accounts ?? [] {
                    if let existing = try self.account(id: account.id) {
                        guard existing == account else { throw StoreError.conflictingImport }
                    } else { try save(account) }
                }
                for source in backup.entries {
                    var restoredEntry = source
                    if let batchID = restoredEntry.importBatchID,
                       !(backup.importBatches ?? []).contains(where: { $0.id == batchID }) {
                        restoredEntry.importBatchID = nil
                    }
                    let priorByID = try entry(id: source.id)
                    let priorBySource = try source.sourceID.flatMap { try entry(sourceID: $0) }
                    if let priorByID {
                        guard CounterCSV.equivalent(priorByID, source), priorBySource == nil || priorBySource?.id == priorByID.id else {
                            throw StoreError.conflictingImport
                        }
                        continue
                    }
                    if let priorBySource {
                        guard CounterCSV.equivalent(priorBySource, source) else { throw StoreError.conflictingImport }
                        continue
                    }
                    try insertEntry(restoredEntry)
                }
                for batch in backup.importBatches ?? [] {
                    let row = try rows("SELECT * FROM import_batches WHERE id=?", [.text(batch.id)])?.first
                    if let row {
                        guard Self.decodeImportBatch(row) == batch else { throw StoreError.conflictingImport }
                        continue
                    }
                    try run("""
                    INSERT INTO import_batches(id,source_digest,created_at,updated_at,input_rows,inserted_count,duplicate_count,conflict_count,invalid_count,cursor,state,undo_conflicts,payload_json)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                    """, [.text(batch.id), .text(batch.sourceDigest), .real(batch.createdAt.timeIntervalSince1970),
                            .real(batch.updatedAt.timeIntervalSince1970), .integer(Int64(batch.inputRows)),
                            .integer(Int64(batch.inserted)), .integer(Int64(batch.duplicates)), .integer(Int64(batch.conflicts)),
                            .integer(Int64(batch.invalid)), .integer(Int64(batch.cursor)), .text(batch.state),
                            .integer(Int64(batch.undoConflicts))])
                }
                for transfer in backup.transfers ?? [] {
                    if let existing = try rows("SELECT * FROM account_transfers WHERE id=? LIMIT 1", [.text(transfer.id)])?.first.flatMap(Self.transfer) {
                        guard existing == transfer else { throw StoreError.conflictingImport }
                    } else {
                        try run("""
                        INSERT INTO account_transfers(id,cents,from_account_id,to_account_id,occurred_at,note,due_amount_reduction_cents,created_at,updated_at)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        """, [.text(transfer.id), .integer(transfer.cents), .text(transfer.fromAccountID), .text(transfer.toAccountID),
                               .real(transfer.occurredAt.timeIntervalSince1970), .text(transfer.note),
                               .integer(transfer.dueAmountReductionCents),
                               .real(transfer.createdAt.timeIntervalSince1970), .real(transfer.updatedAt.timeIntervalSince1970)])
                    }
                }
                for source in backup.drafts {
                    if let prior = try draft(id: source.id) {
                        guard prior == source else { throw StoreError.conflictingImport }
                        continue
                    }
                    if let sourceID = source.sourceID, let prior = try draft(sourceID: sourceID) {
                        guard prior == source else { throw StoreError.conflictingImport }
                        continue
                    }
                    var restored = source
                    restored.imagePath = mediaPaths[source.id]
                    try save(restored)
                }
                try validateRefundRelations()
            }
            try? FileManager.default.removeItem(at: staging)
        } catch {
            for url in installed { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func validate(_ backup: CounterBackup) throws {
        guard backup.format == "counter-backup", backup.version == 1 else { throw StoreError.invalidBackup }
        guard backup.entries.count <= maximumBackupEntries, backup.drafts.count <= maximumBackupDrafts,
              backup.categories.count <= maximumBackupCategories else { throw StoreError.backupResourceLimit }
        let categories = Dictionary(grouping: backup.categories, by: \.id)
        guard categories.values.allSatisfy({ $0.count == 1 }),
              backup.categories.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && ["expense", "income"].contains($0.kind) && ($0.iconPNGBase64.map(CategoryIconArtwork.isValidPNGBase64) ?? true) }) else {
            throw StoreError.invalidBackup
        }
        let categoryIndex = Dictionary(uniqueKeysWithValues: backup.categories.map { ($0.id, $0) })
        let accounts = backup.accounts ?? []
        let accountIDs = accounts.map(\.id)
        guard accounts.count <= 1_000, Set(accountIDs).count == accountIDs.count,
              accounts.allSatisfy({ account in
                  !account.id.isEmpty && account.id.count <= 128 &&
                  !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && account.name.count <= 40 &&
                  (account.cardLabelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) <= 24 &&
                  (account.cardIconPNGBase64.map(AccountCardArtwork.isValidPNGBase64) ?? true) &&
                  account.openingBalanceCents >= 0 && account.openingBalanceCents <= maximumCents &&
                  (account.balanceAdjustmentCents.map { $0 >= -maximumCents && $0 <= maximumCents } ?? true) &&
                  (account.creditLimitCents.map { $0 >= 0 && $0 <= maximumCents } ?? true) &&
                  (account.dueAmountCents.map { $0 >= 0 && $0 <= maximumCents } ?? true) &&
                  (account.repaymentDay.map({ (1...31).contains($0) }) ?? true) &&
                  (account.nextDueDate?.timeIntervalSince1970.isFinite ?? true)
              }) else { throw StoreError.invalidBackup }
        let accountIndex = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let transfers = backup.transfers ?? []
        guard transfers.count <= maximumBackupEntries,
              Set(transfers.map(\.id)).count == transfers.count,
              transfers.allSatisfy({ transfer in
                  transfer.cents > 0 && transfer.cents <= maximumCents && !transfer.id.isEmpty &&
                  transfer.occurredAt.timeIntervalSince1970.isFinite &&
                  transfer.dueAmountReductionCents >= 0 && transfer.dueAmountReductionCents <= transfer.cents &&
                  transfer.fromAccountID != transfer.toAccountID &&
                  accountIndex[transfer.fromAccountID].map { source in
                      !source.type.isLiability || (source.type.isLiability && transfer.id == "borrow-\(source.id)" &&
                          accountIndex[transfer.toAccountID].map { !$0.type.isLiability } == true)
                  } == true &&
                  accountIndex[transfer.toAccountID].map {
                      $0.type.isLiability || transfer.dueAmountReductionCents == 0
                  } == true
              }) else { throw StoreError.invalidBackup }
        let batches = backup.importBatches ?? []
        let batchIDs = batches.map(\.id)
        guard Set(batchIDs).count == batchIDs.count,
              batches.allSatisfy({ batch in
                  let (first, overflowA) = batch.inserted.addingReportingOverflow(batch.duplicates)
                  let (second, overflowB) = first.addingReportingOverflow(batch.conflicts)
                  let (total, overflowC) = second.addingReportingOverflow(batch.invalid)
                  return !batch.id.isEmpty && batch.inputRows >= 0 && batch.inserted >= 0 && batch.duplicates >= 0 &&
                      batch.conflicts >= 0 && batch.invalid >= 0 && batch.cursor >= 0 && batch.undoConflicts >= 0 &&
                      !overflowA && !overflowB && !overflowC &&
                      ["completed", "completedWithConflicts", "undone", "failed"].contains(batch.state) &&
                      (batch.state != "completed" || total == batch.inputRows)
              }) else { throw StoreError.invalidBackup }
        var entryIDs = Set<String>()
        var sourceIDs = Set<String>()
        let backupEntries = Dictionary(backup.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var refundTotals: [String: Int64] = [:]
        for entry in backup.entries {
            guard !entry.id.isEmpty, entry.id.count <= 128, entryIDs.insert(entry.id).inserted,
                  entry.cents > 0, entry.cents <= maximumCents, entry.occurredAt.timeIntervalSince1970.isFinite,
                  (entry.currencyCode ?? "CNY") == "CNY",
                  let category = categoryIndex[entry.categoryID] ?? entry.historicalCategory,
                  entry.accountID.map({ accountIndex[$0].map { !($0.type.isLiability && entry.kind == .income) } ?? false }) ?? true,
                  entry.importBatchID == nil || batchIDs.contains(entry.importBatchID!),
                  category.kind == (entry.kind == .income ? "income" : "expense"),
                  (entry.categorySnapshot?.iconPNGBase64.map(CategoryIconArtwork.isValidPNGBase64) ?? true) else { throw StoreError.invalidBackup }
            if let sourceID = entry.sourceID, !sourceID.isEmpty, !sourceIDs.insert(sourceID).inserted {
                throw StoreError.invalidBackup
            }
            if let originalID = entry.originalEntryID {
                guard entry.kind == .refund, let original = backupEntries[originalID], original.kind == .expense,
                      original.categoryID == entry.categoryID,
                      (original.currencyCode ?? "CNY") == (entry.currencyCode ?? "CNY") else { throw StoreError.invalidBackup }
                let (sum, overflow) = refundTotals[originalID, default: 0].addingReportingOverflow(entry.cents)
                guard !overflow else { throw StoreError.invalidBackup }
                refundTotals[originalID] = sum
            }
        }
        for (originalID, refunded) in refundTotals {
            guard let original = backupEntries[originalID], refunded <= original.cents else { throw StoreError.invalidBackup }
        }
        let draftIDs = backup.drafts.map(\.id)
        let draftsByID = Dictionary(backup.drafts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var draftSources = Set<String>()
        guard Set(draftIDs).count == draftIDs.count,
              backup.drafts.allSatisfy({
                  UUID(uuidString: $0.id) != nil && $0.occurredAt.timeIntervalSince1970.isFinite &&
                  ($0.cents == nil || ($0.cents! > 0 && $0.cents! <= maximumCents)) &&
                  ($0.categoryID == nil || categoryIndex[$0.categoryID!] != nil) &&
                  ($0.imagePath == nil || backup.media[$0.id] != nil) &&
                  ($0.state != .confirmed || $0.confirmedEntryID != nil)
              }),
              Set(backup.media.keys).isSubset(of: Set(draftIDs)),
              (backup.mediaDigests == nil || Set(backup.mediaDigests!.keys) == Set(backup.media.keys)) else {
            throw StoreError.invalidBackup
        }
        for draft in backup.drafts {
            if let sourceID = draft.sourceID, !sourceID.isEmpty, !draftSources.insert(sourceID).inserted {
                throw StoreError.invalidBackup
            }
            if draft.state == .confirmed {
                guard let entryID = draft.confirmedEntryID, let linked = backupEntries[entryID],
                      linked.confirmedDraftID == draft.id else { throw StoreError.invalidBackup }
            }
        }
        var mediaBytes = 0
        for draft in backup.drafts where draft.imagePath != nil {
            guard let data = backup.media[draft.id], Self.validBackupImage(data) else { throw StoreError.invalidBackup }
        }
        for (draftID, data) in backup.media {
            guard draftsByID[draftID]?.imagePath != nil else { throw StoreError.invalidBackup }
            let (total, overflow) = mediaBytes.addingReportingOverflow(data.count)
            guard !overflow, total <= maximumBackupMediaBytes else { throw StoreError.backupResourceLimit }
            mediaBytes = total
            if let digests = backup.mediaDigests,
               digests[draftID] != CaptureService.digest(data) { throw StoreError.invalidBackup }
        }
    }

    private static func validBackupImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= SharedInboxItem.maximumImageBytes,
              SharedInboxItem.imageExtension(for: data) != "img",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 30_000, height <= 30_000,
              width <= maximumBackupImagePixels / height else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2_048,
                                        kCGImageSourceShouldCacheImmediately: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    func activeDraftCount() throws -> Int {
        Int((try rows("SELECT count(*) AS count FROM review_drafts WHERE state IN ('queued','recognizing','needsReview','failed')")?.first?["count"] as? Int64) ?? 0)
    }

    private func insertEntry(_ entry: BookEntry) throws {
        let day = entry.stableLocalDayKey
        try run("""
        INSERT INTO entries(id,cents,kind,occurred_at,local_day,category_id,icon_choice,note,account_id,
          source_id,original_entry_id,created_at,updated_at,accounting_time_zone,currency_code,
          record_version,import_batch_id,confirmed_draft_id,category_snapshot) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(entry.id), .integer(entry.cents), .text(entry.kind.rawValue), .real(entry.occurredAt.timeIntervalSince1970),
               .text(day), .text(entry.categoryID), .text(entry.iconChoice), .text(entry.note),
               entry.accountID.map(SQLValue.text) ?? .null,
               entry.sourceID.map(SQLValue.text) ?? .null, entry.originalEntryID.map(SQLValue.text) ?? .null,
               .real(entry.createdAt.timeIntervalSince1970), .real(entry.updatedAt.timeIntervalSince1970),
               .text(entry.accountingTimeZone ?? TimeZone.current.identifier), .text(entry.currencyCode ?? "CNY"),
               .integer(entry.recordVersion ?? 1), entry.importBatchID.map(SQLValue.text) ?? .null,
               entry.confirmedDraftID.map(SQLValue.text) ?? .null, try Self.snapshotValue(entry.categorySnapshot)])
    }

    private func validateRefundRelations() throws {
        let all = try allEntries()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var refundedByEntry: [String: Int64] = [:]
        for refund in all {
            guard let originalID = refund.originalEntryID else { continue }
            guard refund.kind == .refund, let original = byID[originalID], original.kind == .expense,
                  original.categoryID == refund.categoryID,
                  (original.currencyCode ?? "CNY") == (refund.currencyCode ?? "CNY") else {
                throw StoreError.invalidRefundTarget
            }
            let (sum, overflow) = refundedByEntry[originalID, default: 0].addingReportingOverflow(refund.cents)
            guard !overflow else { throw StoreError.refundLimitExceeded }
            refundedByEntry[originalID] = sum
        }
        for (originalID, refunded) in refundedByEntry {
            guard let original = byID[originalID], refunded <= original.cents else { throw StoreError.refundLimitExceeded }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ values: [SQLValue] = []) throws {
        guard let db else { throw StoreError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.error(db, fallback: "本地账本操作失败")
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE || sqlite3_column_count(statement) > 0 else {
            throw Self.error(db, fallback: "本地账本写入失败")
        }
    }

    private static func schemaVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw error(db, fallback: "无法读取账本版本") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(db, fallback: "无法读取账本版本") }
        return sqlite3_column_int(statement, 0)
    }

    private static func migrateToV2(_ db: OpaquePointer) throws {
        try addColumn("entries", "accounting_time_zone", definition: "TEXT NOT NULL DEFAULT 'legacy-unknown'", db: db)
        try addColumn("entries", "currency_code", definition: "TEXT NOT NULL DEFAULT 'CNY'", db: db)
        try addColumn("entries", "record_version", definition: "INTEGER NOT NULL DEFAULT 1", db: db)
        try addColumn("entries", "import_batch_id", definition: "TEXT", db: db)
        try addColumn("entries", "confirmed_draft_id", definition: "TEXT", db: db)
        try addColumn("review_drafts", "updated_at", definition: "REAL NOT NULL DEFAULT 0", db: db)
        try addColumn("review_drafts", "record_version", definition: "INTEGER NOT NULL DEFAULT 1", db: db)
        try addColumn("review_drafts", "confirmed_entry_id", definition: "TEXT", db: db)
        try addColumn("review_drafts", "input_digest", definition: "TEXT", db: db)
        try addColumn("review_drafts", "user_confirmed_fields", definition: "TEXT NOT NULL DEFAULT '[]'", db: db)
        try addColumn("review_drafts", "claim_token", definition: "TEXT", db: db)
        try addColumn("review_drafts", "claim_expires_at", definition: "REAL", db: db)
        try Self.execute(db, """
        UPDATE review_drafts SET updated_at=created_at WHERE updated_at=0;
        UPDATE entries
          SET confirmed_draft_id=substr(id,7)
          WHERE confirmed_draft_id IS NULL AND id LIKE 'entry-%'
            AND EXISTS (
              SELECT 1 FROM review_drafts d
              WHERE d.id=substr(entries.id,7) AND d.state='confirmed'
            );
        UPDATE review_drafts
          SET confirmed_entry_id='entry-' || id
          WHERE state='confirmed' AND confirmed_entry_id IS NULL
            AND EXISTS (SELECT 1 FROM entries e WHERE e.id='entry-' || review_drafts.id);
        """)
    }

    private static func migrateToV3(_ db: OpaquePointer) throws {
        try addColumn("review_drafts", "candidate_confidence", definition: "TEXT NOT NULL DEFAULT '{}'", db: db)
    }

    private static func migrateToV4(_ db: OpaquePointer) throws {
        try addColumn("review_drafts", "amount_text", definition: "TEXT", db: db)
    }

    private static func migrateToV5(_ db: OpaquePointer) throws {
        try Self.execute(db, """
        CREATE TABLE IF NOT EXISTS import_batches(
          id TEXT PRIMARY KEY, source_digest TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
          updated_at REAL NOT NULL, input_rows INTEGER NOT NULL, inserted_count INTEGER NOT NULL DEFAULT 0,
          duplicate_count INTEGER NOT NULL DEFAULT 0, conflict_count INTEGER NOT NULL DEFAULT 0,
          invalid_count INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL, undo_conflicts INTEGER NOT NULL DEFAULT 0, payload_json TEXT
        );
        CREATE INDEX IF NOT EXISTS import_batches_created ON import_batches(created_at DESC,id);
        """)
    }

    private static func migrateToV6(_ db: OpaquePointer) throws {
        try Self.execute(db, """
        CREATE TABLE IF NOT EXISTS accounts(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN ('cash','debitCard','eWallet','creditCard','loan','otherDebt')),
          opening_balance_cents INTEGER NOT NULL DEFAULT 0 CHECK(opening_balance_cents>=0),
          credit_limit_cents INTEGER CHECK(credit_limit_cents>=0), due_amount_cents INTEGER CHECK(due_amount_cents>=0),
          next_due_at REAL, is_active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS account_transfers(
          id TEXT PRIMARY KEY, cents INTEGER NOT NULL CHECK(cents>0),
          from_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
          to_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
          occurred_at REAL NOT NULL, note TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL, updated_at REAL NOT NULL,
          CHECK(from_account_id<>to_account_id)
        );
        CREATE INDEX IF NOT EXISTS account_transfers_date ON account_transfers(occurred_at DESC,id);
        """)
        try addColumn("entries", "account_id", definition: "TEXT REFERENCES accounts(id) ON DELETE RESTRICT", db: db)
        try Self.execute(db, "CREATE INDEX IF NOT EXISTS entries_account_day ON entries(account_id,local_day)")
    }

    private static func migrateToV7(_ db: OpaquePointer) throws {
        try addColumn("account_transfers", "due_amount_reduction_cents", definition: "INTEGER NOT NULL DEFAULT 0 CHECK(due_amount_reduction_cents>=0)", db: db)
    }

    private static func migrateToV8(_ db: OpaquePointer) throws {
        try addColumn("accounts", "balance_adjustment_cents", definition: "INTEGER NOT NULL DEFAULT 0", db: db)
    }

    private static func migrateToV9(_ db: OpaquePointer) throws {
        try addColumn("accounts", "card_label", definition: "TEXT", db: db)
        try addColumn("accounts", "card_icon", definition: "TEXT", db: db)
        try addColumn("accounts", "card_color", definition: "TEXT", db: db)
    }

    private static func migrateToV10(_ db: OpaquePointer) throws {
        try addColumn("accounts", "card_icon_png", definition: "TEXT", db: db)
    }

    private static func migrateToV11(_ db: OpaquePointer) throws {
        try addColumn("accounts", "provider_name", definition: "TEXT", db: db)
    }

    private static func migrateToV12(_ db: OpaquePointer) throws {
        try Self.execute(db, """
        UPDATE accounts SET name = CASE name
          WHEN '支付宝余额' THEN '支付宝'
          WHEN '微信支付' THEN '微信'
          WHEN '微信零钱' THEN '微信'
          WHEN '云闪付余额' THEN '云闪付'
          WHEN '京东金融余额' THEN '京东金融'
          ELSE name END
        WHERE name IN ('支付宝余额','微信支付','微信零钱','云闪付余额','京东金融余额');

        UPDATE accounts SET name = CASE type
          WHEN 'creditCard' THEN '信用卡'
          ELSE '借记卡' END
        WHERE type IN ('debitCard','creditCard') AND (name IN (
          '招商银行卡','招行卡','招商银行借记卡','招商银行储蓄卡','招商银行信用卡',
          '中国银行卡','中行卡','中国银行借记卡','中国银行储蓄卡','中国银行信用卡',
          '农业银行卡','农行卡','中国农业银行借记卡','中国农业银行储蓄卡','中国农业银行信用卡',
          '工商银行卡','工行卡','中国工商银行借记卡','中国工商银行储蓄卡','中国工商银行信用卡',
          '建设银行卡','建行卡','中国建设银行借记卡','中国建设银行储蓄卡','中国建设银行信用卡',
          '交通银行卡','交行卡','交通银行借记卡','交通银行储蓄卡','交通银行信用卡'
        ) OR (
          provider_name IN ('招商银行','招行','中国银行','中行','中国农业银行','农业银行','农行',
                            '中国工商银行','工商银行','工行','中国建设银行','建设银行','建行','交通银行','交行')
          AND name IN ('借记卡','储蓄卡','信用卡','银行卡','银行卡账户','账户','')
        ));

        UPDATE accounts SET card_label = NULL
        WHERE (type='debitCard' AND card_label IN ('储蓄卡','借记卡'))
           OR (type='creditCard' AND card_label='信用卡')
           OR (type='eWallet' AND card_label='电子钱包');
        """)
    }

    private static func migrateToV15(_ db: OpaquePointer) throws {
        // Copy every v14 field verbatim. IDs and references from bills/transfers do not change.
        try Self.execute(db, """
        CREATE TABLE accounts_v15(
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          type TEXT NOT NULL CHECK(type IN ('cash','debitCard','eWallet','investment','otherAsset','creditCard','loan','otherDebt')),
          opening_balance_cents INTEGER NOT NULL DEFAULT 0 CHECK(opening_balance_cents>=0),
          credit_limit_cents INTEGER CHECK(credit_limit_cents>=0), due_amount_cents INTEGER CHECK(due_amount_cents>=0),
          next_due_at REAL, is_active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          balance_adjustment_cents INTEGER NOT NULL DEFAULT 0, card_label TEXT, card_icon TEXT, card_color TEXT,
          card_icon_png TEXT, provider_name TEXT, repayment_day INTEGER CHECK(repayment_day BETWEEN 1 AND 31),
          repayment_reminder_enabled INTEGER NOT NULL DEFAULT 0, card_icon_override TEXT
        );
        INSERT INTO accounts_v15(id,name,type,opening_balance_cents,credit_limit_cents,due_amount_cents,
          next_due_at,is_active,sort_order,created_at,updated_at,balance_adjustment_cents,
          card_label,card_icon,card_color,card_icon_png,provider_name,repayment_day,repayment_reminder_enabled)
        SELECT id,name,type,opening_balance_cents,credit_limit_cents,due_amount_cents,
          next_due_at,is_active,sort_order,created_at,updated_at,balance_adjustment_cents,
          card_label,card_icon,card_color,card_icon_png,provider_name,repayment_day,repayment_reminder_enabled FROM accounts;
        DROP TABLE accounts;
        ALTER TABLE accounts_v15 RENAME TO accounts;
        """)
    }

    private static func verifyForeignKeys(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Self.error(db, fallback: "无法检查账户关联") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.database("账户关联数据不完整，账本升级已取消。")
        }
    }

    private static func migrateToV14(_ db: OpaquePointer) throws {
        try addColumn("accounts", "repayment_day", definition: "INTEGER CHECK(repayment_day BETWEEN 1 AND 31)", db: db)
        try addColumn("accounts", "repayment_reminder_enabled", definition: "INTEGER NOT NULL DEFAULT 0", db: db)
        // Old DatePicker stored an absolute instant; recover the selected day in the device's local zone.
        // Keep next_due_at and every other account column intact.
        try Self.execute(db, """
        UPDATE accounts SET repayment_day=CAST(strftime('%d',next_due_at,'unixepoch','localtime') AS INTEGER),
          repayment_reminder_enabled=CASE WHEN type IN ('creditCard','loan','otherDebt') THEN 1 ELSE 0 END
          WHERE next_due_at IS NOT NULL;
        """)
    }

    private static func migrateToV13(_ db: OpaquePointer) throws {
        try addColumn("categories", "icon_png", definition: "TEXT", db: db)
        // Keep every column and account constraint. Category identity now lives in a
        // historical snapshot after deletion instead of an undeletable foreign key.
        try Self.execute(db, """
        CREATE TABLE entries_v13(
          id TEXT PRIMARY KEY, cents INTEGER NOT NULL CHECK(cents > 0),
          kind TEXT NOT NULL CHECK(kind IN ('expense','income','refund')),
          occurred_at REAL NOT NULL, local_day TEXT NOT NULL,
          category_id TEXT NOT NULL, icon_choice TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '', source_id TEXT, original_entry_id TEXT,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          accounting_time_zone TEXT NOT NULL DEFAULT 'legacy-unknown',
          currency_code TEXT NOT NULL DEFAULT 'CNY', record_version INTEGER NOT NULL DEFAULT 1,
          import_batch_id TEXT, confirmed_draft_id TEXT,
          account_id TEXT REFERENCES accounts(id) ON DELETE RESTRICT, category_snapshot TEXT
        );
        INSERT INTO entries_v13(id,cents,kind,occurred_at,local_day,category_id,icon_choice,note,
          source_id,original_entry_id,created_at,updated_at,accounting_time_zone,currency_code,
          record_version,import_batch_id,confirmed_draft_id,account_id)
        SELECT id,cents,kind,occurred_at,local_day,category_id,icon_choice,note,
          source_id,original_entry_id,created_at,updated_at,accounting_time_zone,currency_code,
          record_version,import_batch_id,confirmed_draft_id,account_id FROM entries;
        DROP TABLE entries;
        ALTER TABLE entries_v13 RENAME TO entries;
        CREATE UNIQUE INDEX entries_source_id_unique ON entries(source_id) WHERE source_id IS NOT NULL AND source_id <> '';
        CREATE INDEX entries_day_sort ON entries(local_day,occurred_at DESC);
        CREATE INDEX entries_category_day ON entries(category_id,local_day);
        CREATE INDEX entries_account_day ON entries(account_id,local_day);
        """)
    }

    private static func snapshotValue(_ category: BookCategory?) throws -> SQLValue {
        guard let category else { return .null }
        return .text(String(decoding: try JSONEncoder().encode(category), as: UTF8.self))
    }

    private static func addColumn(_ table: String, _ name: String, definition: String, db: OpaquePointer) throws {
        guard !(try tableColumns(table, db: db)).contains(name) else { return }
        try Self.execute(db, "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private static func tableColumns(_ table: String, db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw error(db, fallback: "无法读取账本结构") }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let name = sqlite3_column_text(statement, 1) else {
                throw error(db, fallback: "无法读取账本结构")
            }
            columns.insert(String(cString: name))
        }
        return columns
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard let db else { throw StoreError.unavailable }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
            sqlite3_free(message)
            throw StoreError.database(detail ?? "本地账本初始化失败")
        }
    }

    private func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: Any]]? {
        guard let db else { throw StoreError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.error(db, fallback: "无法读取本地账本")
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Self.error(db, fallback: "读取本地账本失败") }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let cName = sqlite3_column_name(statement, column) else { continue }
                let name = String(cString: cName)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    if let value = sqlite3_column_text(statement, column) { row[name] = String(cString: value) }
                case SQLITE_NULL: row[name] = NSNull()
                default: break
                }
            }
            result.append(row)
        }
        return result
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let code: Int32
            switch value {
            case .text(let text): code = text.withCString { sqlite3_bind_text(statement, slot, $0, -1, sqliteTransient) }
            case .integer(let n): code = sqlite3_bind_int64(statement, slot, n)
            case .real(let n): code = sqlite3_bind_double(statement, slot, n)
            case .null: code = sqlite3_bind_null(statement, slot)
            }
            guard code == SQLITE_OK else { throw Self.error(db, fallback: "本地账本参数写入失败") }
        }
    }

    private static func category(_ row: [String: Any]) -> BookCategory? {
        guard let id = row["id"] as? String, let name = row["name"] as? String,
              let kind = row["kind"] as? String, let symbol = row["symbol"] as? String else { return nil }
        return BookCategory(id: id, name: name, kind: kind, symbol: symbol,
                            sortOrder: Int((row["sort_order"] as? Int64) ?? 0),
                            isActive: ((row["is_active"] as? Int64) ?? 1) != 0,
                            iconPNGBase64: row["icon_png"] as? String)
    }

    private static func account(_ row: [String: Any]) -> BookAccount? {
        guard let id = row["id"] as? String, let name = row["name"] as? String,
              let typeValue = row["type"] as? String, let type = AccountType(rawValue: typeValue),
              let opening = row["opening_balance_cents"] as? Int64 else { return nil }
        return BookAccount(id: id, name: name, type: type, openingBalanceCents: opening,
                           balanceAdjustmentCents: row["balance_adjustment_cents"] as? Int64 ?? 0,
                           cardLabelOverride: row["card_label"] as? String,
                           cardIcon: (row["card_icon"] as? String).flatMap(AccountCardIcon.init(rawValue:)),
                           cardIconOverride: (row["card_icon_override"] as? String).flatMap(AccountCardIcon.init(rawValue:)),
                           cardColor: (row["card_color"] as? String).flatMap(AccountCardColor.init(rawValue:)),
                           cardIconPNGBase64: row["card_icon_png"] as? String,
                           providerName: row["provider_name"] as? String,
                           creditLimitCents: row["credit_limit_cents"] as? Int64,
                           dueAmountCents: row["due_amount_cents"] as? Int64,
                           nextDueDate: (row["next_due_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                           repaymentDay: (row["repayment_day"] as? Int64).map(Int.init),
                           repaymentReminderEnabled: (row["repayment_reminder_enabled"] as? Int64).map { $0 != 0 },
                           isActive: (row["is_active"] as? Int64 ?? 1) != 0,
                           sortOrder: Int(row["sort_order"] as? Int64 ?? 0),
                           createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0),
                           updatedAt: Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0))
    }

    private static func transfer(_ row: [String: Any]) -> AccountTransfer? {
        guard let id = row["id"] as? String, let cents = row["cents"] as? Int64,
              let from = row["from_account_id"] as? String, let to = row["to_account_id"] as? String,
              let occurredAt = row["occurred_at"] as? Double else { return nil }
        return AccountTransfer(id: id, cents: cents, fromAccountID: from, toAccountID: to,
                               occurredAt: Date(timeIntervalSince1970: occurredAt), note: row["note"] as? String ?? "",
                               dueAmountReductionCents: row["due_amount_reduction_cents"] as? Int64 ?? 0,
                               createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? occurredAt),
                               updatedAt: Date(timeIntervalSince1970: row["updated_at"] as? Double ?? occurredAt))
    }

    private static func entry(_ row: [String: Any]) -> BookEntry? {
        guard let id = row["id"] as? String, let cents = row["cents"] as? Int64,
              let kindValue = row["kind"] as? String, let kind = EntryKind(rawValue: kindValue),
              let instant = row["occurred_at"] as? Double, let categoryID = row["category_id"] as? String else { return nil }
        let storedTimeZone = row["accounting_time_zone"] as? String
        return BookEntry(id: id, cents: cents, kind: kind, occurredAt: Date(timeIntervalSince1970: instant),
                         categoryID: categoryID, iconChoice: row["icon_choice"] as? String ?? "",
                         note: row["note"] as? String ?? "", sourceID: row["source_id"] as? String,
                         originalEntryID: row["original_entry_id"] as? String,
                         createdAt: Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? instant),
                         updatedAt: Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? instant),
                         localDayKey: row["local_day"] as? String,
                         accountingTimeZone: storedTimeZone == "legacy-unknown" ? nil : storedTimeZone,
                         currencyCode: row["currency_code"] as? String ?? "CNY",
                         recordVersion: row["record_version"] as? Int64 ?? 1,
                         importBatchID: row["import_batch_id"] as? String,
                         confirmedDraftID: row["confirmed_draft_id"] as? String,
                         accountID: row["account_id"] as? String,
                         categorySnapshot: (row["category_snapshot"] as? String).flatMap {
                             try? JSONDecoder().decode(BookCategory.self, from: Data($0.utf8))
                         })
    }

    private static func decodeImportBatch(_ row: [String: Any]) -> ImportBatch? {
        guard let id = row["id"] as? String,
              let digest = row["source_digest"] as? String,
              let created = row["created_at"] as? Double,
              let updated = row["updated_at"] as? Double,
              let input = row["input_rows"] as? Int64,
              let state = row["state"] as? String else { return nil }
        return ImportBatch(id: id, sourceDigest: digest,
                           createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated),
                           inputRows: Int(input), inserted: Int((row["inserted_count"] as? Int64) ?? 0),
                           duplicates: Int((row["duplicate_count"] as? Int64) ?? 0),
                           conflicts: Int((row["conflict_count"] as? Int64) ?? 0),
                           invalid: Int((row["invalid_count"] as? Int64) ?? 0),
                           cursor: Int((row["cursor"] as? Int64) ?? 0), state: state,
                           undoConflicts: Int((row["undo_conflicts"] as? Int64) ?? 0))
    }

    private static func draft(_ row: [String: Any]) -> ReviewDraft? {
        guard let id = row["id"] as? String, let stateValue = row["state"] as? String,
              let state = ReviewState(rawValue: stateValue), let instant = row["occurred_at"] as? Double else { return nil }
        return ReviewDraft(id: id, state: state, cents: row["cents"] as? Int64,
                           kind: (row["kind"] as? String).flatMap(EntryKind.init(rawValue:)),
                           occurredAt: Date(timeIntervalSince1970: instant), categoryID: row["category_id"] as? String,
                           note: row["note"] as? String ?? "", imagePath: row["image_path"] as? String,
                           recognizedText: row["recognized_text"] as? String ?? "", sourceID: row["source_id"] as? String,
                           errorText: row["error_text"] as? String,
                           createdAt: Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? instant),
                           updatedAt: Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? instant),
                           recordVersion: row["record_version"] as? Int64 ?? 1,
                           confirmedEntryID: row["confirmed_entry_id"] as? String,
                           userConfirmedFields: decodeConfirmedFields(row["user_confirmed_fields"] as? String),
                           claimToken: row["claim_token"] as? String,
                           claimExpiresAt: (row["claim_expires_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                           inputDigest: row["input_digest"] as? String,
                           candidateConfidence: decodeConfidence(row["candidate_confidence"] as? String),
                           amountText: row["amount_text"] as? String)
    }

    private static func encodeConfirmedFields(_ fields: Set<String>?) -> String {
        guard let fields, let data = try? JSONEncoder().encode(fields),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func decodeConfirmedFields(_ value: String?) -> Set<String>? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Set<String>.self, from: data)
    }

    private static func encodeConfidence(_ confidence: [String: Double]?) -> String {
        guard let confidence, let data = try? JSONEncoder().encode(confidence),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func decodeConfidence(_ value: String?) -> [String: Double]? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : value
    }

    private static func error(_ db: OpaquePointer?, fallback: String) -> StoreError {
        if let db, let message = sqlite3_errmsg(db) { return .database(String(cString: message)) }
        return .database(fallback)
    }
}

enum StoreError: LocalizedError {
    case unavailable, invalidBackup, invalidEntry, conflictingImport, invalidImportBatch, pendingImportBatch, backupResourceLimit
    case missingDraft, inconsistentDraft, draftAlreadyClosed, missingBackupMedia(String)
    case staleEntry, staleDraft, protectedCategory, invalidCategoryIcon
    case invalidRefundTarget, refundLimitExceeded, entryHasRefunds, invalidAccount, invalidTransfer
    case unsupportedCurrency(String)
    case unsupportedSchema(Int32)
    case database(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "本地账本暂不可用"
        case .invalidBackup: "备份格式或版本不受支持"
        case .invalidEntry: "账单内容不完整或与分类不匹配"
        case .conflictingImport: "导入内容与现有记录冲突，账本没有更改"
        case .invalidImportBatch: "导入批次数据无效或状态已改变"
        case .pendingImportBatch: "导入批次仍在处理中，请完成或取消后再备份"
        case .backupResourceLimit: "备份记录或图片超过本机安全处理上限，请减少项目后重试"
        case .missingDraft: "待记账任务已不存在，请刷新后重试"
        case .inconsistentDraft: "任务状态与账单记录不一致，需要从备份恢复"
        case .draftAlreadyClosed: "这笔待记账已经处理完成，不能再次确认或忽略"
        case .protectedCategory: "内置分类不能删除"
        case .invalidCategoryIcon: "请选择有效的 PNG 图标"
        case .staleEntry: "这笔账单已在其他操作中更新，请刷新后重试"
        case .staleDraft: "待记账内容已在其他操作中更新，请刷新后重试"
        case .invalidRefundTarget: "关联退款必须指向同分类、同币种的原支出"
        case .refundLimitExceeded: "退款金额超过原支出的剩余可退金额"
        case .entryHasRefunds: "这笔支出已有退款关联，请先处理关联退款后再删除或更改分类"
        case .invalidAccount: "账户资料无效，或这类记录不能记入该账户"
        case .invalidTransfer: "转账账户或金额无效；请从资产账户转出到另一个账户"
        case .unsupportedCurrency(let code): "当前仅支持人民币，不能将 \(code) 记作人民币"
        case .missingBackupMedia(let id): "待记账原图缺失，无法生成完整备份（\(id)）"
        case .unsupportedSchema(let version): "账本数据库版本 \(version) 高于当前版本；已停止写入以保护账本，请更新 Counter 后重试"
        case .database(let text): text
        }
    }
}
