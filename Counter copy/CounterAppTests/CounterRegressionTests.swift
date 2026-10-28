import XCTest
import UIKit
import ImageIO
import SQLite3
@testable import CounterApp

final class CounterRegressionTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CounterRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    func testCounterCSVExportRoundTripsIncomeExpenseAndRefund() throws {
        let categories = BookCategory.defaults
        let rows = [
            entry(id: "income", cents: 10_000, kind: .income, category: "salary"),
            entry(id: "expense", cents: 3_000, kind: .expense, category: "dining"),
            entry(id: "refund", cents: 500, kind: .refund, category: "dining")
        ]
        let csv = CounterCSV.encode(rows, categories: categories)
        let preview = try CounterCSV.parse(csv, existingCategories: categories)

        XCTAssertEqual(preview.records.map(\.id), rows.map(\.id))
        XCTAssertEqual(preview.records.map(\.kind), rows.map(\.kind))
        XCTAssertEqual(preview.records.map(\.cents), rows.map(\.cents))
        XCTAssertTrue(preview.rejectedRows.isEmpty)
    }

    func testCounterCSVPreservesAccountAssociationWhenAccountIsKnown() throws {
        let account = BookAccount(id: "wallet-main", name: "日常卡", type: .debitCard, openingBalanceCents: 25_000)
        var original = entry(id: "linked-export", cents: 1_250, kind: .expense, category: "dining")
        original.accountID = account.id

        let data = CounterCSV.encode([original], categories: BookCategory.defaults)
        let preview = try CounterCSV.parse(data, existingCategories: BookCategory.defaults, existingAccounts: [account])

        XCTAssertEqual(preview.records.first?.accountID, account.id)
        XCTAssertTrue(preview.rejectedRows.isEmpty)
    }

    func testLegacyBackupWithoutAccountFieldsStillDecodes() throws {
        let legacy = Data(#"{"format":"counter-backup","version":1,"exportedAt":0,"categories":[],"entries":[],"drafts":[],"media":{}}"#.utf8)
        let backup = try JSONDecoder().decode(CounterBackup.self, from: legacy)
        XCTAssertNil(backup.accounts)
        XCTAssertNil(backup.transfers)
    }

    func testAccountCardCustomizationSurvivesSaveAndBackupRestore() async throws {
        let store = try isolatedStore()
        let iconPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/uQAAAABJRU5ErkJggg=="
        let account = BookAccount(id: "travel-card", name: "日常银行卡", type: .debitCard,
                                  openingBalanceCents: 50_000, cardLabelOverride: "旅行备用",
                                  cardIcon: .travel, cardColor: .plum, cardIconPNGBase64: iconPNG,
                                  providerName: "招商银行")
        try await store.save(account)

        let saved = try await store.account(id: account.id)
        XCTAssertEqual(saved?.displayTypeLabel, "旅行备用")
        XCTAssertEqual(saved?.displayCardIcon, .travel)
        XCTAssertEqual(saved?.displayCardColor, .plum)
        XCTAssertEqual(saved?.displayProviderName, "招商银行")
        XCTAssertTrue(saved?.hasValidCardIconPNG == true)
        XCTAssertEqual(saved?.type, .debitCard, "卡片展示标签不能改变账户的记账类型")

        let encoded = try CounterCSV.encodeBackup(await store.backup())
        let restoredStore = try LocalStore(databaseURL: sandbox.appendingPathComponent("account-card-style.sqlite"))
        try await restoredStore.restore(JSONDecoder().decode(CounterBackup.self, from: encoded), replace: true)
        let restored = try await restoredStore.account(id: account.id)
        XCTAssertEqual(restored?.cardLabelOverride, "旅行备用")
        XCTAssertEqual(restored?.cardIcon, .travel)
        XCTAssertEqual(restored?.cardColor, .plum)
        XCTAssertEqual(restored?.cardIconPNGBase64, iconPNG)
        XCTAssertEqual(restored?.providerName, "招商银行")
    }

    func testAccountNamesAndExplicitIconsAreIndependentOfInstitutionAndType() throws {
        var account = BookAccount(id: "one", name: "余额宝", type: .eWallet, openingBalanceCents: 12_345,
                                  cardIcon: .wallet, cardIconOverride: .savings, providerName: "支付宝")
        XCTAssertEqual(account.displayName, "余额宝")
        XCTAssertNil(account.brandIcon, "Explicit generic icon must override the institution's logo")
        XCTAssertEqual(account.displayCardIcon, .savings)
        account.cardIconOverride = .wechat
        XCTAssertEqual(account.brandIcon, "brand_wechat")
        XCTAssertEqual(account.type, .eWallet)
        account.name = "支付宝余额"
        XCTAssertEqual(account.displayName, "支付宝余额", "A user's exact name must not be canonicalized")
        account.cardIconOverride = nil
        XCTAssertEqual(account.brandIcon, "brand_alipay", "Legacy automatic branding remains available")
        account.name = "自定义账户"
        account.providerName = "纸币现金"
        XCTAssertEqual(account.displayName, "纸币现金", "Recover the old custom editor's provider-as-name pattern")
        account.cardIconPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/uQAAAABJRU5ErkJggg=="
        XCTAssertNil(account.brandIcon, "Custom PNG must take precedence over a brand")
    }

    func testCustomWalletAccountsSurviveReopenAndBackupWithDistinctIcons() async throws {
        let url = sandbox.appendingPathComponent("wallet-custom.sqlite")
        let store = try LocalStore(databaseURL: url)
        let examples: [(String, AccountType, AccountCardIcon)] = [
            ("余额宝", .eWallet, .savings), ("基金", .investment, .fund), ("纸币现金", .cash, .cash),
            ("备用账户", .otherAsset, .wechat)
        ]
        for (index, example) in examples.enumerated() {
            try await store.save(BookAccount(id: "custom-\(index)", name: example.0, type: example.1,
                                            openingBalanceCents: Int64(index + 1) * 1_000,
                                            cardIconOverride: example.2, sortOrder: index))
        }
        let reopened = try LocalStore(databaseURL: url)
        let overview = try await reopened.accountOverview()
        XCTAssertEqual(overview.accounts.map(\.displayName), examples.map(\.0))
        XCTAssertEqual(overview.accounts.map(\.displayCardIcon), examples.map(\.2))
        XCTAssertEqual(Set(overview.accounts.map(\.id)).count, examples.count)
        XCTAssertEqual(overview.assetsCents, 10_000)
        let backup = try JSONDecoder().decode(CounterBackup.self, from: CounterCSV.encodeBackup(await reopened.backup()))
        let restored = try LocalStore(databaseURL: sandbox.appendingPathComponent("custom-restored.sqlite"))
        try await restored.restore(backup, replace: true)
        let restoredAccounts = try await restored.allAccounts()
        XCTAssertEqual(restoredAccounts, overview.accounts)
    }

    @MainActor
    func testMetadataEditAndArchiveDoNotReconcileBalanceAfterTransfers() async throws {
        let store = try isolatedStore()
        for category in BookCategory.defaults { try await store.save(category) }
        let cash = BookAccount(id: "metadata-cash", name: "现金", type: .cash, openingBalanceCents: 10_000)
        let investment = BookAccount(id: "metadata-fund", name: "基金", type: .investment, openingBalanceCents: 20_000)
        try await store.save(cash)
        try await store.save(investment)
        var expense = entry(id: "metadata-expense", cents: 1_000, kind: .expense, category: "dining")
        expense.accountID = cash.id
        try await store.save(expense)
        let transfer = AccountTransfer(id: "metadata-transfer", cents: 3_000, fromAccountID: cash.id,
                                       toAccountID: investment.id, occurredAt: Date())
        try await store.save(transfer)
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refreshAccountOverview()
        var edited = try XCTUnwrap(model.accounts.first { $0.id == cash.id })
        edited.name = "纸币现金"
        edited.cardIconOverride = .cash
        // Passing the original baseline used to silently reconcile the current balance.
        try await model.saveAccount(edited, reconcileBalance: false)
        XCTAssertEqual(model.accountBalances[cash.id], 6_000)
        XCTAssertEqual(model.accountBalances[investment.id], 23_000)
        try await model.archiveAccount(edited)
        XCTAssertEqual(model.accountBalances[cash.id], 6_000)
        let persisted = try await store.account(id: cash.id)
        XCTAssertEqual(persisted?.openingBalanceCents, 10_000)
        let savedEntry = try await store.entry(id: expense.id)
        XCTAssertEqual(savedEntry?.accountID, cash.id)
        XCTAssertEqual(model.accountTransfers.map(\.id), [transfer.id])
    }

    @MainActor
    func testAssetCategoryEditPreservesAmountsAndHistoricalAssociations() async throws {
        let store = try isolatedStore()
        for category in BookCategory.defaults { try await store.save(category) }
        let account = BookAccount(id: "category-bank", name: "备用金", type: .debitCard, openingBalanceCents: 20_000,
                                  cardIconOverride: .alipay, providerName: "支付宝")
        try await store.save(account)
        var bill = entry(id: "category-expense", cents: 1_250, kind: .expense, category: "dining")
        bill.accountID = account.id
        try await store.save(bill)
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refreshAccountOverview()
        var edited = account
        edited.type = .investment
        try await model.saveAccount(edited, reconcileBalance: false)
        let reopened = try LocalStore(databaseURL: sandbox.appendingPathComponent("category-restored.sqlite"))
        // Backup round-trip must retain the accounting identity and amount.
        let persisted = try await store.account(id: account.id)
        XCTAssertEqual(persisted?.type, .investment)
        XCTAssertEqual(persisted?.cardIconOverride, .alipay)
        XCTAssertEqual(persisted?.openingBalanceCents, 20_000)
        XCTAssertEqual(model.accountBalances[account.id], 18_750)
        let savedBill = try await store.entry(id: bill.id)
        XCTAssertEqual(savedBill?.accountID, account.id)
        try await reopened.restore(await store.backup(), replace: true)
        let overview = try await reopened.accountOverview()
        XCTAssertEqual(overview.balances[account.id], 18_750)
        edited.type = .creditCard
        do {
            try await model.saveAccount(edited, reconcileBalance: false)
            XCTFail("Changing asset/debt nature must not reinterpret historical transactions")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.invalidAccount.localizedDescription)
        }
        let unchanged = try await store.account(id: account.id)
        XCTAssertEqual(unchanged?.type, .investment)
        XCTAssertEqual(model.accountBalances[account.id], 18_750)
    }

    func testV14AccountMigrationPreservesEveryFieldAndLedgerReferences() async throws {
        let url = sandbox.appendingPathComponent("legacy-v14.sqlite")
        let store = try LocalStore(databaseURL: url)
        for category in BookCategory.defaults { try await store.save(category) }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/uQAAAABJRU5ErkJggg=="
        let bank = BookAccount(id: "v14-bank", name: "旅行银行卡", type: .debitCard, openingBalanceCents: 50_000,
                               balanceAdjustmentCents: -1_000, cardLabelOverride: "旅行", cardIcon: .travel,
                               cardColor: .plum, cardIconPNGBase64: png, providerName: "招商银行", sortOrder: 3)
        let debt = BookAccount(id: "v14-debt", name: "信用卡", type: .creditCard, openingBalanceCents: 20_000,
                               creditLimitCents: 80_000, dueAmountCents: 12_000, repaymentDay: 31,
                               repaymentReminderEnabled: true, sortOrder: 4)
        try await store.save(bank)
        try await store.save(debt)
        var expense = entry(id: "v14-bill", cents: 1_000, kind: .expense, category: "dining")
        expense.accountID = bank.id
        try await store.save(expense)
        try await store.save(AccountTransfer(id: "v14-payment", cents: 2_000, fromAccountID: bank.id,
                                            toAccountID: debt.id, occurredAt: Date()))
        let before = try await store.accountOverview()
        let entryBefore = try await store.entry(id: expense.id)
        // Recreate the actual v14 shape and its restrictive type CHECK, rather than just changing user_version.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        let sql = """
        PRAGMA foreign_keys=OFF;
        BEGIN;
        CREATE TABLE legacy_accounts(
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          type TEXT NOT NULL CHECK(type IN ('cash','debitCard','eWallet','creditCard','loan','otherDebt')),
          opening_balance_cents INTEGER NOT NULL DEFAULT 0 CHECK(opening_balance_cents>=0),
          credit_limit_cents INTEGER CHECK(credit_limit_cents>=0), due_amount_cents INTEGER CHECK(due_amount_cents>=0),
          next_due_at REAL, is_active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL, balance_adjustment_cents INTEGER NOT NULL DEFAULT 0,
          card_label TEXT,card_icon TEXT,card_color TEXT,card_icon_png TEXT,provider_name TEXT,
          repayment_day INTEGER,repayment_reminder_enabled INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO legacy_accounts SELECT id,name,type,opening_balance_cents,credit_limit_cents,due_amount_cents,
          next_due_at,is_active,sort_order,created_at,updated_at,balance_adjustment_cents,card_label,card_icon,
          card_color,card_icon_png,provider_name,repayment_day,repayment_reminder_enabled FROM accounts;
        DROP TABLE accounts;
        ALTER TABLE legacy_accounts RENAME TO accounts;
        PRAGMA user_version=14;
        COMMIT;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        let migrated = try LocalStore(databaseURL: url)
        let after = try await migrated.accountOverview()
        XCTAssertEqual(after.accounts, before.accounts)
        XCTAssertEqual(after.balances, before.balances)
        XCTAssertEqual(after.transfers, before.transfers)
        let migratedEntry = try await migrated.entry(id: expense.id)
        XCTAssertEqual(migratedEntry, entryBefore)
        try await migrated.save(BookAccount(id: "new-fund", name: "基金", type: .investment,
                                            openingBalanceCents: 0, cardIconOverride: .fund))
        var invalidEntry = expense
        invalidEntry.id = "invalid-fk"
        invalidEntry.accountID = "missing-account"
        do { try await migrated.save(invalidEntry); XCTFail("Foreign key enforcement must be restored") }
        catch { /* expected */ }
    }

    func testFailedAccountMigrationRollsBackWithoutChangingLegacyRows() async throws {
        let url = sandbox.appendingPathComponent("migration-rollback.sqlite")
        let store = try LocalStore(databaseURL: url)
        for category in BookCategory.defaults { try await store.save(category) }
        try await store.save(BookAccount(id: "legacy-account", name: "纸币现金", type: .cash, openingBalanceCents: 9_999))
        var expense = entry(id: "orphan-bill", cents: 500, kind: .expense, category: "dining")
        expense.accountID = "legacy-account"
        try await store.save(expense)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys=OFF; UPDATE entries SET account_id='missing'; ALTER TABLE accounts DROP COLUMN card_icon_override; PRAGMA user_version=14;", nil, nil, nil), SQLITE_OK)
        do {
            _ = try LocalStore(databaseURL: url)
            XCTFail("A broken reference must cancel migration")
        } catch {
            XCTAssertEqual(error.localizedDescription, "账户关联数据不完整，账本升级已取消。")
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT (SELECT user_version FROM pragma_user_version),(SELECT COUNT(*) FROM pragma_table_info('accounts') WHERE name='card_icon_override'),name,opening_balance_cents FROM accounts WHERE id='legacy-account'", -1, &statement, nil), SQLITE_OK)
        let row = try XCTUnwrap(statement)
        defer { sqlite3_finalize(row) }
        XCTAssertEqual(sqlite3_step(row), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(row, 0), 14, "Version must not advance on failure")
        XCTAssertEqual(sqlite3_column_int(row, 1), 0, "Table rebuild must be rolled back")
        XCTAssertEqual(String(cString: sqlite3_column_text(row, 2)), "纸币现金")
        XCTAssertEqual(sqlite3_column_int64(row, 3), 9_999)
    }

    func testAccountCardsCanBeReorderedWithoutChangingTheirBalances() async throws {
        let store = try isolatedStore()
        try await store.save(BookAccount(id: "wallet-a", name: "支付宝余额", type: .eWallet, openingBalanceCents: 12_500, sortOrder: 0))
        try await store.save(BookAccount(id: "bank-b", name: "日常银行卡", type: .debitCard, openingBalanceCents: 84_000, sortOrder: 1))

        try await store.reorderActiveAccounts(["bank-b", "wallet-a"])

        let overview = try await store.accountOverview()
        XCTAssertEqual(overview.accounts.map(\.id), ["bank-b", "wallet-a"])
        XCTAssertEqual(overview.balances["bank-b"], 84_000)
        XCTAssertEqual(overview.balances["wallet-a"], 12_500)
    }

    func testAccountBalancesAndRepaymentTransferStayOutsideExpenseTotals() async throws {
        let store = try isolatedStore()
        for category in BookCategory.defaults { try await store.save(category) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cash = BookAccount(id: "cash-main", name: "日常银行卡", type: .debitCard,
                               openingBalanceCents: 100_000, createdAt: now, updatedAt: now)
        let card = BookAccount(id: "credit-main", name: "信用卡", type: .creditCard,
                               openingBalanceCents: 200_000, creditLimitCents: 500_000,
                               dueAmountCents: 50_000, createdAt: now, updatedAt: now)
        try await store.save(cash)
        try await store.save(card)

        var purchase = entry(id: "card-purchase", cents: 10_000, kind: .expense, category: "dining")
        purchase.accountID = card.id
        try await store.save(purchase)
        var refund = BookEntry(id: "card-refund", cents: 1_000, kind: .refund, occurredAt: now,
                               categoryID: "dining", iconChoice: "dining", note: "退款",
                               sourceID: nil, originalEntryID: purchase.id, createdAt: now, updatedAt: now)
        refund.accountID = card.id
        try await store.save(refund)

        let transfer = AccountTransfer(id: "card-payment", cents: 20_000, fromAccountID: cash.id,
                                       toAccountID: card.id, occurredAt: now, note: "还款",
                                       createdAt: now, updatedAt: now)
        try await store.save(transfer)

        let overview = try await store.accountOverview()
        XCTAssertEqual(overview.balances[cash.id], 80_000)
        XCTAssertEqual(overview.balances[card.id], 189_000)
        XCTAssertEqual(overview.accounts.first(where: { $0.id == card.id })?.dueAmountCents, 30_000)
        XCTAssertEqual(overview.netWorthCents, -109_000)
        let savedEntries = try await store.allEntries()
        XCTAssertEqual(LedgerMath.summary(savedEntries).netExpenses, 9_000)

        let encoded = try CounterCSV.encodeBackup(await store.backup())
        let restored = try LocalStore(databaseURL: sandbox.appendingPathComponent("accounts-restored.sqlite"))
        try await restored.restore(JSONDecoder().decode(CounterBackup.self, from: encoded), replace: true)
        let restoredOverview = try await restored.accountOverview()
        XCTAssertEqual(restoredOverview.balances[cash.id], 80_000)
        XCTAssertEqual(restoredOverview.balances[card.id], 189_000)
        XCTAssertEqual(restoredOverview.transfers.map(\.id), [transfer.id])

        let savedTransfer = try XCTUnwrap(overview.transfers.first)
        try await store.deleteTransfer(savedTransfer)
        let afterDelete = try await store.accountOverview()
        XCTAssertEqual(afterDelete.balances[cash.id], 100_000)
        XCTAssertEqual(afterDelete.balances[card.id], 209_000)
        XCTAssertEqual(afterDelete.accounts.first(where: { $0.id == card.id })?.dueAmountCents, 50_000)
    }

    func testIncomeCannotBeAssignedToLiabilityAccount() async throws {
        let store = try isolatedStore()
        for category in BookCategory.defaults { try await store.save(category) }
        let liability = BookAccount(id: "loan", name: "贷款", type: .loan, openingBalanceCents: 100_000)
        try await store.save(liability)
        var salary = entry(id: "salary-to-loan", cents: 2_000, kind: .income, category: "salary")
        salary.accountID = liability.id

        do {
            try await store.save(salary)
            XCTFail("收入不能关联到负债账户")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.invalidAccount.localizedDescription)
        }
    }

    @MainActor
    func testEditingAccountCurrentBalanceKeepsHistoricalEntries() async throws {
        let store = try isolatedStore()
        for category in BookCategory.defaults { try await store.save(category) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let account = BookAccount(id: "cash-edit", name: "储蓄卡", type: .debitCard,
                                  openingBalanceCents: 10_000, createdAt: now, updatedAt: now)
        try await store.save(account)
        var expense = entry(id: "cash-purchase", cents: 1_000, kind: .expense, category: "dining")
        expense.accountID = account.id
        try await store.save(expense)
        var income = entry(id: "cash-income", cents: 10_000, kind: .income, category: "salary")
        income.accountID = account.id
        try await store.save(income)

        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refreshAccountOverview()
        var edited = try XCTUnwrap(model.accounts.first(where: { $0.id == account.id }))
        edited.name = "常用卡"
        edited.openingBalanceCents = 5_000 // AccountEditorView passes the displayed current balance here.
        try await model.saveAccount(edited)

        XCTAssertEqual(model.accountBalances[account.id], 5_000)
        let savedEntry = try await store.entry(id: expense.id)
        let savedAccount = try await store.account(id: account.id)
        XCTAssertEqual(savedEntry?.accountID, account.id)
        XCTAssertEqual(savedAccount?.openingBalanceCents, 0)
        XCTAssertEqual(savedAccount?.balanceAdjustmentCents, -4_000)
    }

    func testAmountWithTrailingTextIsRejected() throws {
        let csv = Data("日期,金额,收支\n2026-09-27,12.34junk,支出\n".utf8)
        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertTrue(preview.records.isEmpty)
        XCTAssertEqual(preview.rejectedRows.count, 1)
    }

    func testUSDIsRejectedInsteadOfImportedAsCNY() throws {
        let csv = Data("Date,Amount,Currency,Direction\n2026-09-27,12.34,USD,expense\n".utf8)
        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertTrue(preview.records.isEmpty)
        XCTAssertTrue(preview.rejectedRows.first?.contains("USD") == true)
    }

    func testSharedMoneyParserEnforcesPrecisionRangeAndOptionalZero() throws {
        XCTAssertEqual(CounterMoney.cents(from: "¥1,234.50"), 123_450)
        XCTAssertEqual(CounterMoney.cents(from: "0", allowZero: true), 0)
        XCTAssertNil(CounterMoney.cents(from: "0"))
        XCTAssertNil(CounterMoney.cents(from: "12.345"))
        XCTAssertNil(CounterMoney.cents(from: "12.00junk"))
        XCTAssertNil(CounterMoney.cents(from: "90000000000000.01"))
    }

    func testReceiptSuggestionsPreferPaidAmountAndRejectEqualAmbiguity() throws {
        let suggestion = CaptureService.suggest(from: "星巴克咖啡\n订单金额 ¥100.00\n优惠金额 ¥20.00\n实付金额 ¥80.00\n付款成功\n2026-09-27 18:42")
        XCTAssertEqual(suggestion.cents, 8_000)
        XCTAssertEqual(suggestion.kind, .expense)
        XCTAssertEqual(suggestion.categoryID, "dining")
        XCTAssertEqual(suggestion.confidence["amount"], 1.0)

        let ambiguous = CaptureService.suggest(from: "支付金额 80.00\n支付金额 82.00")
        XCTAssertNil(ambiguous.cents)
    }

    func testReceiptSuggestionRejectsInvalidCalendarDate() throws {
        let suggestion = CaptureService.suggest(from: "商店\n实付金额 12.50\n2026-02-30 12:00")
        XCTAssertNil(suggestion.date)
        XCTAssertNil(suggestion.confidence["occurredAt"])
    }

    func testRecognitionRetryCannotOverwriteUserConfirmedFields() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var draft = ReviewDraft(id: "locked", state: .recognizing, cents: 2_000,
                                kind: .expense, occurredAt: date, categoryID: "shopping",
                                note: "我改过的备注", imagePath: nil, recognizedText: "",
                                sourceID: nil, errorText: nil, createdAt: date,
                                userConfirmedFields: ["amount", "categoryID", "note"])
        let suggestion = CaptureService.Suggestion(cents: 8_000, kind: .income,
                                                   date: date.addingTimeInterval(86_400), categoryID: "dining",
                                                   merchant: "原始识别", confidence: ["amount": 1])
        CaptureService.apply(suggestion, to: &draft)

        XCTAssertEqual(draft.cents, 2_000)
        XCTAssertEqual(draft.categoryID, "shopping")
        XCTAssertEqual(draft.note, "我改过的备注")
        XCTAssertEqual(draft.kind, .income)
        XCTAssertEqual(draft.occurredAt, date.addingTimeInterval(86_400))
    }

    func testDraftRecognitionClaimExpiresAndCanBeRecovered() async throws {
        let store = try isolatedStore()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .queued,
                                cents: nil, kind: nil, occurredAt: date, categoryID: nil,
                                note: "", imagePath: "/tmp/receipt.png", recognizedText: "",
                                sourceID: "image:claim", errorText: nil, createdAt: date)
        let saved = try await store.save(draft)
        let maybeFirst = try await store.claimRecognition(id: saved.id, lease: 300)
        let first = try XCTUnwrap(maybeFirst)
        XCTAssertEqual(first.state, .recognizing)
        XCTAssertNotNil(first.claimToken)
        let competing = try await store.claimRecognition(id: saved.id, lease: 300)
        XCTAssertNil(competing)

        var expired = first
        expired.claimExpiresAt = Date().addingTimeInterval(-1)
        _ = try await store.save(expired)
        let maybeRecovered = try await store.claimRecognition(id: saved.id, lease: 300)
        let recovered = try XCTUnwrap(maybeRecovered)
        XCTAssertEqual(recovered.state, .recognizing)
        XCTAssertNotEqual(recovered.claimToken, first.claimToken)
    }

    func testDraftPersistsPartialAmountTextConfidenceAndConfirmedFields() async throws {
        let store = try isolatedStore()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var draft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .needsReview,
                                cents: nil, kind: .expense, occurredAt: date, categoryID: "dining",
                                note: "咖啡", imagePath: nil, recognizedText: "", sourceID: "text:partial",
                                errorText: nil, createdAt: date, userConfirmedFields: ["amount", "note"],
                                candidateConfidence: ["amount": 0.75], amountText: "12.")
        draft = try await store.save(draft)
        let maybeSaved = try await store.draft(id: draft.id)
        let saved = try XCTUnwrap(maybeSaved)
        XCTAssertEqual(saved.amountText, "12.")
        XCTAssertEqual(saved.userConfirmedFields, ["amount", "note"])
        XCTAssertEqual(saved.candidateConfidence?["amount"], 0.75)
    }

    func testQuickEntryIntentRequestRoundTripsUserFields() throws {
        let request = CounterPendingIntent(id: "intent-123", amount: "18.25", kind: .income,
                                           occurredAt: Date(timeIntervalSince1970: 1_790_000_000), note: "奖金")
        let data = try JSONEncoder().encode(request)
        let restored = try JSONDecoder().decode(CounterPendingIntent.self, from: data)
        XCTAssertEqual(restored.id, request.id)
        XCTAssertEqual(restored.amount, "18.25")
        XCTAssertEqual(restored.kind, .income)
        XCTAssertEqual(restored.note, "奖金")
        XCTAssertEqual(restored.occurredAt, request.occurredAt)
    }

    func testQuickEntryIntentQueueDoesNotReplaceEarlierRequests() throws {
        let suite = "CounterRegressionIntent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CounterPendingIntent(id: "first", amount: "10", kind: .expense)
        let second = CounterPendingIntent(id: "second", amount: "20", kind: .income)
        try CounterIntentQueue.enqueue(first, in: defaults)
        try CounterIntentQueue.enqueue(second, in: defaults)

        XCTAssertEqual(CounterIntentQueue.takeNext(from: defaults)?.id, "first")
        XCTAssertEqual(CounterIntentQueue.takeNext(from: defaults)?.id, "second")
        XCTAssertNil(CounterIntentQueue.takeNext(from: defaults))
    }

    @MainActor
    func testLiveActivityHidesAmountCategoryNameAndPNGWhenPrivacyIsOff() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ReviewDraft(id: "privacy-check", state: .needsReview, cents: 12_500,
                                kind: .expense, occurredAt: date, categoryID: "dining", note: "咖啡",
                                imagePath: nil, recognizedText: "", sourceID: nil,
                                errorText: nil, createdAt: date)
        let category = BookCategory.defaults[0]
        let hidden = CounterActivityController.contentState(for: draft, category: category, revealDetails: false)
        XCTAssertEqual(hidden.amount, "有一笔待记账")
        XCTAssertEqual(hidden.category, "打开 Counter 核对")
        XCTAssertEqual(hidden.categoryAsset, "custom_category")

        let visible = CounterActivityController.contentState(for: draft, category: category, revealDetails: true)
        XCTAssertEqual(visible.amount, "¥125.00")
        XCTAssertEqual(visible.categoryAsset, category.symbol)
        XCTAssertEqual(CounterActivityController.draftURL(draft.id)?.absoluteString, "counter://drafts/privacy-check")
    }

    func testShareInboxPersistsEveryItemInMultiItemBatch() throws {
        let inbox = sandbox.appendingPathComponent("shared-inbox", isDirectory: true)
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for _ in 0..<5 {
            try SharedInboxItem.persist(pngHeader, id: UUID().uuidString.lowercased(), kind: "image", in: inbox)
        }
        let manifests = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(manifests.count, 5)
        for manifest in manifests {
            let item = try JSONDecoder().decode(SharedInboxItem.self, from: Data(contentsOf: manifest))
            XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(item.filename).path))
        }
    }

    func testTransactionIDIsNamespacedAndPreserved() throws {
        let csv = Data("Date,Amount,Direction,transaction_id\n2026-09-27,12.34,expense,txn-123\n".utf8)
        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertTrue(preview.records.first?.sourceID?.contains("txn-123") == true)
        XCTAssertTrue(preview.records.first?.sourceID?.hasPrefix("statement:v1:") == true)
    }

    func testImportCountMatchesRowsWrittenInIsolatedLedger() async throws {
        let store = try isolatedStore()
        let rows = [
            entry(id: "one", cents: 100, kind: .expense, category: "dining"),
            entry(id: "two", cents: 200, kind: .expense, category: "dining"),
            entry(id: "three", cents: 300, kind: .income, category: "salary")
        ]

        let result = try await store.saveImported(rows, categories: BookCategory.defaults)
        let saved = try await store.allEntries()

        XCTAssertEqual(saved.count, rows.count)
        XCTAssertEqual(result.inserted, rows.count)
        XCTAssertEqual(result.exactDuplicates, 0)
        XCTAssertEqual(result.conflicts, 0)
    }

    func testCSVFindsHeaderAfterLongPreambleAndCountsEveryDataRow() throws {
        let preamble = (0..<55).map { "export metadata \($0),ignored" }.joined(separator: "\n")
        let csv = Data((preamble + "\nDate,Amount,Direction,Note\n2026-09-27,12.34,expense,Lunch\n2026-09-28,8.00,expense,Coffee\n").utf8)

        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertEqual(preview.records.count, 2)
        XCTAssertEqual(preview.totalRows, 2)
        XCTAssertTrue(preview.rejectedRows.isEmpty)
    }

    func testUnknownProviderStatusIsRejectedInsteadOfAssumedSuccessful() throws {
        let csv = Data("交易时间,金额,交易状态,收支\n2026-09-27,12.34,SUCCESS,支出\n".utf8)

        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertTrue(preview.records.isEmpty)
        XCTAssertEqual(preview.rejectedRows.count, 1)
        XCTAssertTrue(preview.rejectedRows[0].contains("未完成"))
    }

    func testImportBatchHidesPartialRowsAndCanResumeAfterAbort() async throws {
        let store = try isolatedStore()
        let first = entry(id: "batch-one", cents: 100, kind: .expense, category: "dining")
        let second = entry(id: "batch-two", cents: 200, kind: .expense, category: "dining")
        let prepared = try await store.prepareImportBatch([first, second], categories: BookCategory.defaults,
                                                          inputRows: 2, sourceDigest: "digest")

        let partial = try await store.processImportBatch(id: prepared.id, chunkSize: 1)
        let hiddenSnapshot = try await store.snapshot(in: first.occurredAt)
        XCTAssertEqual(partial.state, "running")
        XCTAssertTrue(hiddenSnapshot.entries.isEmpty, "半批数据不能进入账本统计")

        try await store.abortImportBatch(id: prepared.id)
        let failed = try await store.importBatch(id: prepared.id)
        XCTAssertEqual(failed?.state, "failed")
        try await store.retryImportBatch(id: prepared.id)
        var resumed = try await store.importBatch(id: prepared.id)
        while let current = resumed, !current.isComplete {
            resumed = try await store.processImportBatch(id: prepared.id, chunkSize: 1)
        }

        let snapshot = try await store.snapshot(in: first.occurredAt)
        XCTAssertEqual(snapshot.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(resumed?.state, "completed")
        let completed = try XCTUnwrap(resumed)
        XCTAssertEqual(completed.inputRows, completed.inserted + completed.duplicates + completed.conflicts + completed.invalid)
    }

    func testLargeLedgerSnapshotFindsThreeThousandRowsAcrossFiftyThousand() async throws {
        let store = try isolatedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let month = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)))
        let entries = try (0..<50_000).map { index -> BookEntry in
            let date = index < 3_000
                ? month
                : try XCTUnwrap(calendar.date(byAdding: .month, value: (index % 24) + 1, to: month))
            var record = entry(id: "scale-\(index)", cents: Int64((index % 9_000) + 100), kind: .expense, category: "dining")
            record.occurredAt = date
            record.createdAt = date
            record.updatedAt = date
            record.localDayKey = CounterFormat.localDayKey(date)
            return record
        }
        var batch = try await store.prepareImportBatch(entries, categories: BookCategory.defaults,
                                                       inputRows: entries.count, sourceDigest: "large-ledger-test")
        while !batch.isComplete {
            batch = try await store.processImportBatch(id: batch.id, chunkSize: 5_000)
        }

        let snapshot = try await store.snapshot(in: month)
        XCTAssertEqual(batch.state, "completed")
        XCTAssertEqual(batch.inserted, 50_000)
        XCTAssertEqual(snapshot.entries.count, 3_000)
        XCTAssertEqual(snapshot.summary.expenses, LedgerMath.summary(snapshot.entries).expenses)
    }

    func testUndoImportBatchKeepsEntriesChangedAfterImport() async throws {
        let store = try isolatedStore()
        let edited = entry(id: "edited-after-import", cents: 500, kind: .expense, category: "dining")
        let unchanged = entry(id: "unchanged-after-import", cents: 700, kind: .expense, category: "dining")
        let result = try await store.saveImported([edited, unchanged], categories: BookCategory.defaults)
        let savedEntry = try await store.entry(id: edited.id)
        var current = try XCTUnwrap(savedEntry)
        current.note = "用户后来补充的备注"
        try await store.save(current)

        let undo = try await store.undoImportBatch(id: try XCTUnwrap(result.batchID))
        let remaining = try await store.allEntries()
        let batch = try await store.importBatch(id: try XCTUnwrap(result.batchID))

        XCTAssertEqual(undo.deleted, 1)
        XCTAssertEqual(undo.conflicts, 1)
        XCTAssertEqual(remaining.map(\.id), [edited.id])
        XCTAssertEqual(remaining.first?.note, "用户后来补充的备注")
        XCTAssertEqual(batch?.state, "completedWithConflicts")
    }

    func testCompleteBackupRoundTripsImportBatchHistory() async throws {
        let source = try isolatedStore()
        let original = entry(id: "backup-batch-entry", cents: 1_250, kind: .expense, category: "dining")
        let imported = try await source.saveImported([original], categories: BookCategory.defaults)
        let encoded = try CounterCSV.encodeBackup(try await source.backup())
        let decoded = try JSONDecoder().decode(CounterBackup.self, from: encoded)
        let destination = try LocalStore(databaseURL: sandbox.appendingPathComponent("restored.sqlite"))

        try await destination.restore(decoded, replace: true)

        let restoredEntries = try await destination.allEntries()
        let batches = try await destination.importBatches()
        XCTAssertEqual(restoredEntries.map(\.id), [original.id])
        XCTAssertEqual(restoredEntries.first?.importBatchID, imported.batchID)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.inserted, 1)
        XCTAssertEqual(batches.first?.state, "completed")
    }

    func testRestorePreviewListsConflictsAndPreventsPartialMerge() async throws {
        let store = try isolatedStore()
        let current = entry(id: "same-id", cents: 500, kind: .expense, category: "dining")
        _ = try await store.saveImported([current], categories: BookCategory.defaults)
        var conflicting = current
        conflicting.cents = 900
        let additional = entry(id: "new-id", cents: 250, kind: .income, category: "salary")
        var changedCategory = BookCategory.defaults[0]
        changedCategory.name = "已修改分类"
        let backup = CounterBackup(categories: [changedCategory] + Array(BookCategory.defaults.dropFirst()),
                                   entries: [conflicting, additional], drafts: [])

        let preview = try await store.previewRestore(backup)
        XCTAssertEqual(preview.newEntries, 1)
        XCTAssertEqual(preview.conflictingEntries, 1)
        XCTAssertEqual(preview.conflictingCategories, 1)
        XCTAssertFalse(preview.canMerge)
        XCTAssertFalse(preview.conflicts.isEmpty)

        do {
            try await store.restore(backup, replace: false)
            XCTFail("冲突备份不能部分合并")
        } catch { XCTAssertEqual(error.localizedDescription, StoreError.conflictingImport.localizedDescription) }
        let saved = try await store.allEntries()
        let category = try await store.allCategories().first(where: { $0.id == "dining" })
        XCTAssertEqual(saved.map(\.id), [current.id])
        XCTAssertEqual(saved.first?.cents, current.cents)
        XCTAssertEqual(category?.name, "餐饮")
    }

    func testInvalidRestoreIsRejectedWithoutChangingExistingLedger() async throws {
        let store = try isolatedStore()
        let original = entry(id: "existing", cents: 900, kind: .expense, category: "dining")
        _ = try await store.saveImported([original], categories: BookCategory.defaults)
        let invalid = entry(id: "negative", cents: -500, kind: .expense, category: "dining")
        let backup = CounterBackup(categories: BookCategory.defaults, entries: [invalid], drafts: [])

        do {
            try await store.restore(backup, replace: true)
            XCTFail("损坏的备份不得报告恢复成功")
        } catch { }
        let saved = try await store.allEntries()

        XCTAssertEqual(saved.map(\.id), [original.id])
    }

    func testBackupMissingReferencedImageCannotReplaceLedger() async throws {
        let store = try isolatedStore()
        let original = entry(id: "keep-me", cents: 800, kind: .expense, category: "dining")
        _ = try await store.saveImported([original], categories: BookCategory.defaults)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .failed, cents: nil, kind: nil,
                                occurredAt: date, categoryID: nil, note: "", imagePath: "/missing/receipt.png",
                                recognizedText: "", sourceID: "image:missing", errorText: "missing",
                                createdAt: date)
        let backup = CounterBackup(categories: BookCategory.defaults, entries: [], drafts: [draft])

        do {
            try await store.restore(backup, replace: true)
            XCTFail("缺少草稿原图的完整备份不得覆盖现有账本")
        } catch { }
        let saved = try await store.allEntries()
        XCTAssertEqual(saved.map(\.id), [original.id])
    }

    func testV1DatabaseMigrationPreservesRowsTotalsAndStoredLocalDays() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CounterV1Fixture", withExtension: "sqlite"))
        let databaseURL = sandbox.appendingPathComponent("migrated-v1.sqlite")
        try FileManager.default.copyItem(at: fixture, to: databaseURL)

        let store = try LocalStore(databaseURL: databaseURL)
        let rows = try await store.allEntries()
        let categories = try await store.allCategories()
        let confirmed = try await store.draft(id: "00000000-0000-4000-8000-000000000001")
        let migratedEntry = try XCTUnwrap(rows.first(where: { $0.id == "legacy-expense" }))
        let confirmedEntry = try XCTUnwrap(rows.first(where: { $0.id == "entry-00000000-0000-4000-8000-000000000001" }))

        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.accountID == nil }, "旧流水应保持未关联账户，迁移不能擅自指定账户")
        XCTAssertEqual(categories.count, 2)
        XCTAssertEqual(try XCTUnwrap(confirmed).state, .confirmed)
        XCTAssertEqual(migratedEntry.localDayKey, "2024-01-30")
        XCTAssertEqual(migratedEntry.currencyCode, "CNY")
        XCTAssertNil(migratedEntry.accountingTimeZone, "v1 中未知的时区应保持未知")
        XCTAssertEqual(confirmedEntry.confirmedDraftID, "00000000-0000-4000-8000-000000000001")
    }

    func testStaleEntryAndDraftEditsAreRejectedWithoutOverwritingLatestValues() async throws {
        let store = try isolatedStore()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.save(BookCategory.defaults[0])
        let original = entry(id: "versioned-entry", cents: 500, kind: .expense, category: "dining")
        _ = try await store.saveImported([original])
        let loadedEntry = try await store.entry(id: original.id)
        var currentEntry = try XCTUnwrap(loadedEntry)
        var staleEntry = currentEntry
        currentEntry.note = "最新内容"
        try await store.save(currentEntry)
        staleEntry.note = "旧内容"
        do {
            try await store.save(staleEntry)
            XCTFail("旧版本账单不能覆盖新版本")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.staleEntry.localizedDescription)
        }
        let latestEntry = try await store.entry(id: original.id)
        XCTAssertEqual(latestEntry?.note, "最新内容")

        let newDraft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .needsReview,
                                   cents: 600, kind: .expense, occurredAt: date,
                                   categoryID: "dining", note: "初始", imagePath: nil,
                                   recognizedText: "", sourceID: "text:versioned", errorText: nil,
                                   createdAt: date)
        var currentDraft = try await store.save(newDraft)
        var staleDraft = currentDraft
        currentDraft.note = "草稿新值"
        currentDraft = try await store.save(currentDraft)
        staleDraft.note = "草稿旧值"
        do {
            _ = try await store.save(staleDraft)
            XCTFail("旧版本草稿不能覆盖新版本")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.staleDraft.localizedDescription)
        }
        let latestDraft = try await store.draft(id: newDraft.id)
        XCTAssertEqual(latestDraft?.note, "草稿新值")
        XCTAssertEqual(currentDraft.recordVersion, 2)
    }

    func testLinkedRefundCannotExceedOriginalAndProtectsOriginalFromRemoval() async throws {
        let store = try isolatedStore()
        try await store.save(BookCategory.defaults[0])
        let original = entry(id: "purchase", cents: 5_000, kind: .expense, category: "dining")
        _ = try await store.saveImported([original])
        let maybeOriginal = try await store.entry(id: original.id)
        let persistedOriginal = try XCTUnwrap(maybeOriginal)
        let initialRemainder = try await store.remainingRefundCents(for: original.id)
        XCTAssertEqual(initialRemainder, 5_000)

        let refund = BookEntry(id: "refund-linked", cents: 4_000, kind: .refund,
                               occurredAt: original.occurredAt, categoryID: original.categoryID,
                               iconChoice: original.iconChoice, note: "部分退款", sourceID: nil,
                               originalEntryID: original.id, createdAt: original.createdAt,
                               updatedAt: original.updatedAt)
        try await store.save(refund)
        let remainderAfterPartialRefund = try await store.remainingRefundCents(for: original.id)
        XCTAssertEqual(remainderAfterPartialRefund, 1_000)

        var excessive = refund
        excessive.id = "refund-excessive"
        excessive.cents = 1_001
        excessive.originalEntryID = original.id
        do {
            try await store.save(excessive)
            XCTFail("退款总额不能超过原支出")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.refundLimitExceeded.localizedDescription)
        }

        do {
            try await store.delete(persistedOriginal)
            XCTFail("存在关联退款时不能删除原支出")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.entryHasRefunds.localizedDescription)
        }
        let maybeRefund = try await store.entry(id: refund.id)
        try await store.delete(XCTUnwrap(maybeRefund))
        try await store.delete(persistedOriginal)
        let deletedOriginal = try await store.entry(id: original.id)
        XCTAssertNil(deletedOriginal)
    }

    @MainActor
    func testSavingIntoAnotherMonthKeepsCurrentMonthScreenStable() async throws {
        let store = try isolatedStore()
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refresh()
        let january = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        let february = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 1)))
        await model.selectMonth(january)
        model.path = [.monthBill(january)]
        let category = try XCTUnwrap(model.categories.first(where: { $0.id == "dining" }))
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 9, hour: 12)))
        let movedEntry = BookEntry(id: "moved-to-february", cents: 2_500, kind: .expense,
                                   occurredAt: date, categoryID: category.id, iconChoice: category.symbol,
                                   note: "跨月编辑", sourceID: nil, originalEntryID: nil,
                                   createdAt: date, updatedAt: date)

        try await model.saveEntry(movedEntry)

        XCTAssertEqual(CounterFormat.monthKey(model.selectedMonth), "2024-01")
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.entries(in: february).contains(where: { $0.id == movedEntry.id }))
        XCTAssertTrue(model.toast?.contains("当前仍显示") == true)
    }

    @MainActor
    func testDraftDeepLinkResolvesToReviewOrItsCompletedEntry() async throws {
        let store = try isolatedStore()
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refresh()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ReviewDraft(id: UUID().uuidString.lowercased(), state: .needsReview,
                                cents: 1_250, kind: .expense, occurredAt: date, categoryID: "dining",
                                note: "待确认", imagePath: nil, recognizedText: "", sourceID: "text:link",
                                errorText: nil, createdAt: date)
        _ = try await store.save(draft)
        await model.navigateToDraft(id: draft.id)
        XCTAssertEqual(model.path, [.draft(draft.id)])

        let maybeDraft = try await store.draft(id: draft.id)
        let persistedDraft = try XCTUnwrap(maybeDraft)
        let category = try XCTUnwrap(model.categories.first(where: { $0.id == "dining" }))
        let entry = BookEntry(id: "entry-\(draft.id)", cents: 1_250, kind: .expense,
                              occurredAt: date, categoryID: category.id, iconChoice: category.symbol,
                              note: draft.note, sourceID: draft.sourceID, originalEntryID: nil,
                              createdAt: date, updatedAt: date, confirmedDraftID: draft.id)
        _ = try await store.commitDraft(persistedDraft, entry: entry)
        model.path = []
        await model.navigateToDraft(id: draft.id)
        XCTAssertEqual(model.path, [.monthBill(date)])
        XCTAssertEqual(model.toast, "这笔账单已经入账")
    }

    @MainActor
    func testLatestMonthRequestWinsWhenSelectionsOverlap() async throws {
        let store = try isolatedStore()
        let category = BookCategory.defaults[0]
        try await store.save(category)
        let january = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        let february = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 1)))
        var janEntry = entry(id: "jan", cents: 100, kind: .expense, category: category.id)
        janEntry.occurredAt = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 12)))
        var febEntry = entry(id: "feb", cents: 200, kind: .expense, category: category.id)
        febEntry.occurredAt = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 14, hour: 12)))
        _ = try await store.saveImported([janEntry, febEntry])
        let model = AppModel(store: store, synchronizesSystemActivity: false)

        let first = Task { @MainActor in await model.selectMonth(january) }
        let latest = Task { @MainActor in await model.selectMonth(february) }
        await first.value
        await latest.value

        XCTAssertEqual(model.selectedMonthKey, "2024-02")
        XCTAssertEqual(model.entries.map(\.id), ["feb"])
    }

    func testNetRefundCategoryRemainsInCategorySpending() throws {
        let store = try isolatedStore()
        let rows = [
            entry(id: "spent", cents: 3_000, kind: .expense, category: "dining"),
            entry(id: "refunded", cents: 5_000, kind: .refund, category: "dining")
        ]

        let ranking = store.categorySpending(in: rows, categories: BookCategory.defaults)

        XCTAssertEqual(ranking.first?.cents, -2_000)
        XCTAssertEqual(ranking.first?.category.id, "dining")
    }

    func testCSVHandlesCRLFQuotedCommaNewlineAndStableRepeatImport() throws {
        let original = BookEntry(id: "record-quoted", cents: 1_234, kind: .expense,
                                 occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
                                 categoryID: "dining", iconChoice: "dining",
                                 note: "茶馆,靠窗\n第二行", sourceID: "statement:test:one:expense",
                                 originalEntryID: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                 updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = CounterCSV.encode([original], categories: BookCategory.defaults)
        let first = try CounterCSV.parse(data, existingCategories: BookCategory.defaults)
        let second = try CounterCSV.parse(data, existingCategories: BookCategory.defaults)

        XCTAssertEqual(first.records.first?.note, original.note)
        XCTAssertEqual(first.records.first?.sourceID, original.sourceID)
        XCTAssertEqual(second.records.first?.id, original.id)
    }

    func testSameSourceWithDifferentAmountIsReportedAsConflict() throws {
        let csv = Data("Date,Amount,Direction,Provider,transaction_id\n2026-09-27,12.34,expense,Demo,txn-7\n2026-09-27,15.00,expense,Demo,txn-7\n".utf8)
        let preview = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertEqual(preview.records.count, 1)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.rejectedRows.count, 1)
    }

    func testDuplicateRowsHaveStableIDsWhenFileIsReimported() throws {
        let csv = Data("Date,Amount,Direction\n2026-09-27,12.34,expense\n".utf8)
        let first = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)
        let second = try CounterCSV.parse(csv, existingCategories: BookCategory.defaults)

        XCTAssertEqual(first.records.first?.id, second.records.first?.id)
        XCTAssertFalse(first.records.first?.id.isEmpty ?? true)
    }

    func testImportCommitSeparatesExactDuplicatesAndConflicts() async throws {
        let store = try isolatedStore()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let original = BookEntry(id: "original", cents: 1_000, kind: .expense, occurredAt: date,
                                 categoryID: "dining", iconChoice: "dining", note: "咖啡",
                                 sourceID: "statement:v1:4:demo|5:txn-1|7:expense", originalEntryID: nil,
                                 createdAt: date, updatedAt: date)
        _ = try await store.saveImported([original], categories: BookCategory.defaults)
        let exactCopy = BookEntry(id: "another-id", cents: 1_000, kind: .expense, occurredAt: date,
                                  categoryID: "dining", iconChoice: "dining", note: "咖啡",
                                  sourceID: original.sourceID, originalEntryID: nil,
                                  createdAt: date, updatedAt: date)
        let conflict = BookEntry(id: "conflicting-id", cents: 2_000, kind: .expense, occurredAt: date,
                                 categoryID: "dining", iconChoice: "dining", note: "咖啡",
                                 sourceID: original.sourceID, originalEntryID: nil,
                                 createdAt: date, updatedAt: date)

        let result = try await store.saveImported([exactCopy, conflict])

        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.exactDuplicates, 1)
        XCTAssertEqual(result.conflicts, 1)
        let rows = try await store.allEntries()
        XCTAssertEqual(rows.count, 1)
    }

    func testDraftConfirmationIsIdempotentInIsolatedLedger() async throws {
        let store = try isolatedStore()
        let category = BookCategory.defaults[0]
        try await store.save(category)
        let draftID = UUID().uuidString.lowercased()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ReviewDraft(id: draftID, state: .needsReview, cents: 3_400, kind: .expense,
                                occurredAt: date, categoryID: category.id, note: "午餐",
                                imagePath: nil, recognizedText: "", sourceID: "text:test-1",
                                errorText: nil, createdAt: date)
        let persistedDraft = try await store.save(draft)
        let entry = BookEntry(id: "entry-\(draftID)", cents: 3_400, kind: .expense, occurredAt: date,
                              categoryID: category.id, iconChoice: category.symbol, note: draft.note,
                              sourceID: draft.sourceID, originalEntryID: nil, createdAt: date, updatedAt: date,
                              confirmedDraftID: draftID)

        let first = try await store.commitDraft(persistedDraft, entry: entry)
        let second = try await store.commitDraft(persistedDraft, entry: entry)

        XCTAssertEqual(first.id, second.id)
        let rows = try await store.allEntries()
        let savedDraft = try await store.draft(id: draftID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(savedDraft?.state, .confirmed)
        XCTAssertEqual(savedDraft?.confirmedEntryID, entry.id)
        XCTAssertEqual(rows.first?.confirmedDraftID, draftID)
    }

    func testStaleDraftCannotConfirmOverAConcurrentReviewEdit() async throws {
        let store = try isolatedStore()
        try await store.save(BookCategory.defaults[0])
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let initial = ReviewDraft(id: UUID().uuidString.lowercased(), state: .needsReview,
                                  cents: 800, kind: .expense, occurredAt: date,
                                  categoryID: "dining", note: "原备注", imagePath: nil,
                                  recognizedText: "", sourceID: "text:stale-confirm", errorText: nil,
                                  createdAt: date)
        let persisted = try await store.save(initial)
        let stale = persisted
        var latest = persisted
        latest.note = "新备注"
        _ = try await store.save(latest)
        let entry = BookEntry(id: "entry-\(initial.id)", cents: 800, kind: .expense,
                              occurredAt: date, categoryID: "dining", iconChoice: "dining",
                              note: stale.note, sourceID: stale.sourceID, originalEntryID: nil,
                              createdAt: date, updatedAt: date, confirmedDraftID: stale.id)

        do {
            _ = try await store.commitDraft(stale, entry: entry)
            XCTFail("过期审核内容不能确认入账")
        } catch {
            XCTAssertEqual(error.localizedDescription, StoreError.staleDraft.localizedDescription)
        }
        let entries = try await store.allEntries()
        let currentDraft = try await store.draft(id: initial.id)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(currentDraft?.note, "新备注")
    }

    func testSharedInboxWritesPayloadAndManifestTogether() throws {
        let inbox = sandbox.appendingPathComponent("inbox", isDirectory: true)
        let id = UUID().uuidString.lowercased()
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let filename = try SharedInboxItem.persist(pngSignature, id: id, kind: "image", in: inbox)

        XCTAssertEqual(filename, "\(id).png")
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(filename)), pngSignature)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).json").path))
    }

    func testV12MigrationPreservesAccountAndEntryMetadataBeforeCategoryDeletion() async throws {
        let url = sandbox.appendingPathComponent("category-v12.sqlite")
        let custom = BookCategory(id: "category-v12", name: "Old Coffee", kind: "expense",
                                  symbol: "custom_category", sortOrder: 20, isActive: true)
        var original = entry(id: "v12-entry", cents: 600, kind: .expense, category: custom.id)
        original.accountID = "v12-cash"
        original.sourceID = "v12-source"
        original.localDayKey = "2024-06-01"
        original.accountingTimeZone = "Asia/Shanghai"
        original.currencyCode = "CNY"
        original.importBatchID = "v12-batch"
        original.confirmedDraftID = "v12-draft"
        do {
            let store = try LocalStore(databaseURL: url)
            try await store.bootstrap()
            try await store.save(custom)
            try await store.save(BookAccount(id: "v12-cash", name: "Cash", type: .cash, openingBalanceCents: 5_000))
            try await store.save(original)
        }
        // Recreate the actual v12 layout, including its category foreign key.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let legacySQL = """
        BEGIN IMMEDIATE;
        INSERT INTO import_batches(id,created_at,updated_at,input_rows,state) VALUES('v12-batch',0,0,1,'completed');
        CREATE TABLE entries_v12(
          id TEXT PRIMARY KEY, cents INTEGER NOT NULL CHECK(cents>0),
          kind TEXT NOT NULL CHECK(kind IN ('expense','income','refund')),
          occurred_at REAL NOT NULL, local_day TEXT NOT NULL,
          category_id TEXT NOT NULL REFERENCES categories(id), icon_choice TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '', source_id TEXT, original_entry_id TEXT,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          accounting_time_zone TEXT NOT NULL DEFAULT 'legacy-unknown',
          currency_code TEXT NOT NULL DEFAULT 'CNY', record_version INTEGER NOT NULL DEFAULT 1,
          import_batch_id TEXT, confirmed_draft_id TEXT,
          account_id TEXT REFERENCES accounts(id) ON DELETE RESTRICT
        );
        INSERT INTO entries_v12 SELECT id,cents,kind,occurred_at,local_day,category_id,icon_choice,note,
          source_id,original_entry_id,created_at,updated_at,accounting_time_zone,currency_code,
          record_version,import_batch_id,confirmed_draft_id,account_id FROM entries;
        DROP TABLE entries;
        ALTER TABLE entries_v12 RENAME TO entries;
        ALTER TABLE categories DROP COLUMN icon_png;
        PRAGMA user_version=12;
        COMMIT;
        """
        let result = sqlite3_exec(db, legacySQL, nil, nil, nil)
        let failure = db.map { String(cString: sqlite3_errmsg($0)) } ?? "No database"
        sqlite3_close(db)
        XCTAssertEqual(result, SQLITE_OK, failure)
        let migrated = try LocalStore(databaseURL: url)
        let rows = try await migrated.allEntries()
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved.accountID, original.accountID)
        XCTAssertEqual(saved.sourceID, original.sourceID)
        XCTAssertEqual(saved.localDayKey, original.localDayKey)
        XCTAssertEqual(saved.accountingTimeZone, original.accountingTimeZone)
        XCTAssertEqual(saved.importBatchID, original.importBatchID)
        XCTAssertEqual(saved.confirmedDraftID, original.confirmedDraftID)
        XCTAssertEqual(saved.recordVersion, 1)
        XCTAssertEqual(saved.cents, 600)
        try await migrated.deleteCategory(id: custom.id)
        let history = try await migrated.allEntries()
        XCTAssertEqual(history.first?.historicalCategory?.name, "Old Coffee")
        let overview = try await migrated.accountOverview()
        XCTAssertEqual(overview.balances["v12-cash"], 4_400)
    }

    func testCategoryPNGAndDeletionSurviveReopeningDatabase() async throws {
        let url = sandbox.appendingPathComponent("category-restart.sqlite")
        let store = try LocalStore(databaseURL: url)
        try await store.bootstrap()
        let png = try CategoryIconArtwork.preparePNG(testPNG(side: 2_048))
        let coffee = BookCategory(id: "category-coffee", name: "Coffee", kind: "expense",
                                  symbol: "custom_category", sortOrder: 20, isActive: true, iconPNGBase64: png)
        try await store.save(coffee)
        let reopened = try LocalStore(databaseURL: url)
        let categories = try await reopened.allCategories()
        XCTAssertEqual(categories.first { $0.id == coffee.id }?.iconPNGBase64, png)
        XCTAssertTrue(CategoryIconArtwork.isValidPNGBase64(png))
        try await reopened.deleteCategory(id: coffee.id)
        try await reopened.toggleCategory(id: coffee.id)
        let afterRestart = try LocalStore(databaseURL: url)
        try await afterRestart.bootstrap()
        let remaining = try await afterRestart.allCategories()
        XCTAssertFalse(remaining.contains { $0.id == coffee.id })
        XCTAssertEqual(Set(remaining.map(\.id)), Set(BookCategory.defaults.map(\.id)))
        // Check the database itself, independently of the category-list query.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM categories WHERE id='category-coffee'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }

    func testDeletingUsedCategoryPreservesHistoryRefundsEditingAndBackup() async throws {
        let store = try isolatedStore()
        try await store.bootstrap()
        let png = try CategoryIconArtwork.preparePNG(testPNG(side: 256))
        let coffee = BookCategory(id: "category-used-coffee", name: "Coffee", kind: "expense",
                                  symbol: "custom_category", sortOrder: 20, isActive: true, iconPNGBase64: png)
        try await store.save(coffee)
        try await store.save(BookAccount(id: "cash", name: "Cash", type: .cash, openingBalanceCents: 10_000))
        var original = entry(id: "coffee-bill", cents: 1_000, kind: .expense, category: coffee.id)
        original.accountID = "cash"
        try await store.save(original)
        let draft = ReviewDraft(id: UUID().uuidString, state: .needsReview, cents: 500, kind: .expense,
                                occurredAt: original.occurredAt, categoryID: coffee.id, note: "",
                                imagePath: nil, recognizedText: "", sourceID: nil, errorText: nil,
                                createdAt: original.createdAt)
        _ = try await store.save(draft)
        try await store.deleteCategory(id: coffee.id)
        let loadedEntry = try await store.entry(id: original.id)
        var saved = try XCTUnwrap(loadedEntry)
        XCTAssertEqual(saved.historicalCategory?.name, "Coffee")
        XCTAssertEqual(saved.historicalCategory?.iconPNGBase64, png)
        let categories = try await store.allCategories()
        XCTAssertFalse(categories.contains { $0.id == coffee.id })
        let spending = LedgerMath.categorySpending([saved], categories: categories)
        XCTAssertEqual(spending.first?.cents, 1_000)
        XCTAssertEqual(spending.first?.category.name, "Coffee")
        let savedDraft = try await store.draft(id: draft.id)
        XCTAssertNil(savedDraft?.categoryID)
        saved.note = "Edited after deleting category"
        try await store.save(saved)
        var refund = entry(id: "coffee-refund", cents: 200, kind: .refund, category: coffee.id)
        refund.originalEntryID = original.id
        refund.accountID = "cash"
        try await store.save(refund)
        let overview = try await store.accountOverview()
        XCTAssertEqual(overview.balances["cash"], 9_200)
        let backup = try await store.backup()
        XCTAssertFalse(backup.categories.contains { $0.id == coffee.id })
        let encoded = try CounterCSV.encodeBackup(backup)
        let restored = try LocalStore(databaseURL: sandbox.appendingPathComponent("deleted-category-restore.sqlite"))
        try await restored.restore(JSONDecoder().decode(CounterBackup.self, from: encoded), replace: true)
        let history = try await restored.allEntries()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.historicalCategory?.name == "Coffee" })
        XCTAssertEqual(LedgerMath.categorySpending(history, categories: categories).first?.cents, 800)
        let csv = String(decoding: CounterCSV.encode(history, categories: categories), as: UTF8.self)
        XCTAssertTrue(csv.contains("Coffee"))
        let restoredCategories = try await restored.allCategories()
        XCTAssertFalse(restoredCategories.contains { $0.id == coffee.id })
        let remainingRefund = try await restored.remainingRefundCents(for: original.id)
        XCTAssertEqual(remainingRefund, 800)
    }

    func testBuiltInCategoriesCannotBeDeletedAndLegacyCustomIDsRemainDeletable() async throws {
        let store = try isolatedStore()
        try await store.bootstrap()
        do { try await store.deleteCategory(id: "dining"); XCTFail("Built-in category must be protected") }
        catch { XCTAssertEqual(error.localizedDescription, StoreError.protectedCategory.localizedDescription) }
        let legacy = Data(#"{"id":"category-legacy","name":"Coffee","kind":"expense","symbol":"custom_category","sortOrder":20,"isActive":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BookCategory.self, from: legacy)
        XCTAssertTrue(decoded.isUserCreated)
        XCTAssertNil(decoded.iconPNGBase64)
        try await store.save(decoded)
        try await store.deleteCategory(id: decoded.id)
        let categories = try await store.allCategories()
        XCTAssertTrue(categories.contains { $0.id == "dining" })
        XCTAssertFalse(categories.contains { $0.id == decoded.id })
    }

    @MainActor
    func testCategoryModelUsesPNGAndRefreshesSnapshotsAfterDeletion() async throws {
        let store = try isolatedStore()
        try await store.bootstrap()
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refresh()
        let png = try CategoryIconArtwork.preparePNG(testPNG(side: 200))
        try await model.addCategory("Coffee", kind: .expense, iconPNGBase64: png)
        let coffee = try XCTUnwrap(model.categories.first { $0.name == "Coffee" })
        XCTAssertEqual(coffee.iconPNGBase64, png)
        try await model.deleteCategory(coffee)
        XCTAssertFalse(model.categories.contains { $0.id == coffee.id })
        XCTAssertTrue(model.monthSnapshots.values.allSatisfy { !$0.categories.contains { $0.id == coffee.id } })
    }

    func testPNGIsDownsampledAndCorruptImagesFallBack() throws {
        let prepared = try CategoryIconArtwork.preparePNG(testPNG(side: 3_000))
        let data = try XCTUnwrap(Data(base64Encoded: prepared))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, 128)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 128)
        XCTAssertLessThanOrEqual(data.count, CategoryIconArtwork.maximumBytes)
        XCTAssertThrowsError(try CategoryIconArtwork.preparePNG(Data([137,80,78,71,13,10,26,10])))
        XCTAssertFalse(CategoryIconArtwork.isValidPNGBase64("broken"))
        XCTAssertNil(CounterIconCache.image(base64: "broken"))
        XCTAssertNotNil(CounterIconCache.image(base64: prepared))
    }

    @MainActor
    func testInlineIncomeAndExpenseUpdateBalanceEditingDeletionAndDeduplication() async throws {
        let store = try isolatedStore()
        try await store.bootstrap()
        let wallet = BookAccount(id: "wechat", name: "微信", type: .eWallet, openingBalanceCents: 10_000)
        try await store.save(wallet)
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.selectMonth(Date(timeIntervalSince1970: 1_790_000_000))
        var meal = entry(id: "meal", cents: 3_000, kind: .expense, category: "dining")
        meal.accountID = wallet.id
        try await model.saveEntry(meal)
        XCTAssertEqual(model.accountBalances[wallet.id], 7_000)
        var income = entry(id: "inline-income", cents: 100_000, kind: .income, category: BookCategory.incomeOption.id)
        income.accountID = wallet.id
        try await model.saveEntry(income)
        XCTAssertEqual(model.accountBalances[wallet.id], 107_000)
        XCTAssertEqual(model.summary.income, 100_000)
        XCTAssertEqual(model.summary.expenses, 3_000)
        XCTAssertEqual(model.summary.netCents, 97_000)
        XCTAssertEqual(model.entries.first { $0.id == income.id }?.resolvedCategory(in: model.categories)?.name, "收入")
        do { try await model.saveEntry(income); XCTFail("Same saved record must not be inserted twice") }
        catch { XCTAssertTrue(error is StoreError) }
        let afterRepeat = try await store.allEntries()
        XCTAssertEqual(afterRepeat.count, 2)
        var edited = try XCTUnwrap(model.entries.first { $0.id == income.id })
        edited.cents = 120_000
        try await model.saveEntry(edited)
        XCTAssertEqual(model.accountBalances[wallet.id], 127_000)
        XCTAssertEqual(model.summary.income, 120_000)
        let savedIncome = try XCTUnwrap(model.entries.first { $0.id == income.id })
        await model.removeEntry(savedIncome)
        XCTAssertEqual(model.accountBalances[wallet.id], 7_000)
        XCTAssertEqual(model.summary.income, 0)
        XCTAssertEqual(model.summary.expenses, 3_000)
        await model.undo(savedIncome)
        XCTAssertEqual(model.accountBalances[wallet.id], 127_000)
        XCTAssertEqual(model.summary.income, 120_000)
    }

    @MainActor
    func testBorrowedAccountIncreasesWechatAndDebtWithoutIncomeAndIsIdempotent() async throws {
        let store = try isolatedStore()
        try await store.bootstrap()
        try await store.save(BookAccount(id: "wechat", name: "微信", type: .eWallet, openingBalanceCents: 5_000))
        let model = AppModel(store: store, synchronizesSystemActivity: false)
        await model.refresh()
        let debt = BookAccount(id: "zhangsan", name: "张三", type: .otherDebt, openingBalanceCents: 0,
                               cardLabelOverride: "借入", cardIconOverride: .work)
        let first = try await model.saveBorrowingAccount(debt, cents: 200_000, toAccountID: "wechat")
        let repeated = try await model.saveBorrowingAccount(debt, cents: 200_000, toAccountID: "wechat")
        XCTAssertEqual(first.id, repeated.id)
        let overview = try await store.accountOverview()
        XCTAssertEqual(overview.balances["wechat"], 205_000)
        XCTAssertEqual(overview.balances[debt.id], 200_000)
        XCTAssertEqual(overview.assetsCents, 205_000)
        XCTAssertEqual(overview.liabilitiesCents, 200_000)
        XCTAssertEqual(overview.netWorthCents, 5_000)
        XCTAssertEqual(overview.transfers.count, 1)
        XCTAssertEqual(overview.accounts.count, 2)
        XCTAssertEqual(overview.transfers.first?.fromAccountID, debt.id)
        XCTAssertEqual(overview.transfers.first?.toAccountID, "wechat")
        XCTAssertEqual(overview.transfers.first?.cents, 200_000)
        XCTAssertEqual(model.accountBalances["wechat"], 205_000)
        XCTAssertEqual(model.summary.income, 0)
        XCTAssertEqual(model.summary.netCents, 0)
        let entries = try await store.allEntries()
        XCTAssertTrue(entries.isEmpty, "Borrowing cannot become an income entry")
        do {
            _ = try await model.saveBorrowingAccount(debt, cents: 300_000, toAccountID: "wechat")
            XCTFail("An existing borrowing operation cannot be reinterpreted")
        } catch {}
        let unchanged = try await store.accountOverview()
        XCTAssertEqual(unchanged.balances, overview.balances)
    }

    func testBorrowingRollsBackBothSidesWhenMovementInsertFailsThenRetriesOnce() async throws {
        let url = sandbox.appendingPathComponent("atomic-borrow.sqlite")
        let store = try LocalStore(databaseURL: url)
        try await store.save(BookAccount(id: "wallet", name: "微信", type: .eWallet, openingBalanceCents: 0))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TRIGGER reject_test_borrow BEFORE INSERT ON account_transfers
        WHEN NEW.id='borrow-atomic' BEGIN SELECT RAISE(ABORT,'injected transfer failure'); END;
        """, nil, nil, nil), SQLITE_OK)
        let debt = BookAccount(id: "atomic", name: "张三", type: .otherDebt, openingBalanceCents: 0, cardLabelOverride: "借入")
        do { try await store.saveBorrowing(debt, cents: 200_000, toAccountID: "wallet"); XCTFail("Injected insert failure") } catch {}
        let failed = try await store.accountOverview()
        XCTAssertEqual(failed.accounts.map(\.id), ["wallet"])
        XCTAssertEqual(failed.balances["wallet"], 0)
        XCTAssertTrue(failed.transfers.isEmpty)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_test_borrow", nil, nil, nil), SQLITE_OK)
        try await store.saveBorrowing(debt, cents: 200_000, toAccountID: "wallet")
        try await store.saveBorrowing(debt, cents: 200_000, toAccountID: "wallet")
        let retried = try await store.accountOverview()
        XCTAssertEqual(retried.balances["wallet"], 200_000)
        XCTAssertEqual(retried.balances[debt.id], 200_000)
        XCTAssertEqual(retried.transfers.count, 1)
    }

    func testBorrowingRejectsMissingLiabilityOrInactiveRecipientAndInvalidAmount() async throws {
        let store = try isolatedStore()
        try await store.save(BookAccount(id: "card", name: "信用卡", type: .creditCard, openingBalanceCents: 0))
        try await store.save(BookAccount(id: "archived", name: "旧微信", type: .eWallet, openingBalanceCents: 0, isActive: false))
        try await store.save(BookAccount(id: "wallet", name: "微信", type: .eWallet, openingBalanceCents: 0))
        let debt = BookAccount(id: "zhangsan", name: "张三", type: .otherDebt, openingBalanceCents: 0)
        for recipient in ["missing", "card", "archived"] {
            do { try await store.saveBorrowing(debt, cents: 200_000, toAccountID: recipient); XCTFail("Invalid recipient") } catch {}
        }
        for cents: Int64 in [0, -1, CounterMoney.maximumCents + 1] {
            do { try await store.saveBorrowing(debt, cents: cents, toAccountID: "wallet"); XCTFail("Invalid amount") } catch {}
        }
        let after = try await store.accountOverview()
        XCTAssertFalse(after.accounts.contains { $0.id == debt.id })
        XCTAssertTrue(after.transfers.isEmpty)
        XCTAssertEqual(after.balances["wallet"], 0)
    }

    func testBorrowingAssociationAndLegacyDataSurviveReopenAndBackup() async throws {
        let url = sandbox.appendingPathComponent("borrow-reopen.sqlite")
        let store = try LocalStore(databaseURL: url)
        try await store.bootstrap()
        let category = BookCategory(id: "category-legacy", name: "历史分类", kind: "expense", symbol: "custom_category", sortOrder: 99, isActive: false)
        try await store.save(category)
        let asset = BookAccount(id: "wallet", name: "微信", type: .eWallet, openingBalanceCents: 10_000,
                                cardIconOverride: .wechat)
        try await store.save(asset)
        let persistedAsset = try await store.account(id: asset.id)
        var bill = entry(id: "legacy-bill", cents: 3_000, kind: .expense, category: category.id)
        bill.accountID = asset.id
        try await store.save(bill)
        let originalBill = try await store.entry(id: bill.id)
        let debt = BookAccount(id: "lender", name: "张三", type: .otherDebt, openingBalanceCents: 0, cardLabelOverride: "借入")
        try await store.saveBorrowing(debt, cents: 200_000, toAccountID: asset.id)
        var relabeledDebt = debt
        relabeledDebt.type = .loan // Existing account subtype editing must retain the borrowing association.
        try await store.save(relabeledDebt)
        let reopened = try LocalStore(databaseURL: url)
        let after = try await reopened.accountOverview()
        XCTAssertEqual(after.balances[asset.id], 207_000)
        XCTAssertEqual(after.balances[debt.id], 200_000)
        XCTAssertEqual(after.netWorthCents, 7_000)
        let reopenedBill = try await reopened.entry(id: bill.id)
        XCTAssertEqual(reopenedBill, originalBill)
        let categories = try await reopened.allCategories()
        XCTAssertEqual(categories.first { $0.id == category.id }, category)
        let document = try CounterCSV.encodeBackup(await reopened.backup())
        let restored = try LocalStore(databaseURL: sandbox.appendingPathComponent("borrow-restored.sqlite"))
        try await restored.restore(JSONDecoder().decode(CounterBackup.self, from: document), replace: true)
        let restoredOverview = try await restored.accountOverview()
        XCTAssertEqual(restoredOverview.balances, after.balances)
        XCTAssertEqual(restoredOverview.transfers, after.transfers)
        XCTAssertEqual(restoredOverview.accounts.first { $0.id == debt.id }?.name, "张三")
        XCTAssertEqual(restoredOverview.accounts.first { $0.id == debt.id }?.type, .loan)
        XCTAssertEqual(restoredOverview.accounts.first { $0.id == asset.id }, persistedAsset)
        let restoredBill = try await restored.entry(id: bill.id)
        XCTAssertEqual(restoredBill, originalBill)
    }

    func testAddingIncomeOptionDoesNotReplaceCustomCategoriesOrDisabledSettings() async throws {
        let store = try isolatedStore()
        let custom = BookCategory(id: "category-custom", name: "自定义", kind: "expense", symbol: "custom_category", sortOrder: 8, isActive: false)
        try await store.save(custom)
        try await store.bootstrap()
        try await store.bootstrap()
        var categories = try await store.allCategories()
        XCTAssertEqual(categories.first { $0.id == custom.id }, custom)
        XCTAssertEqual(categories.filter { $0.id == BookCategory.incomeOption.id }.count, 1)
        XCTAssertEqual(categories.first { $0.id == BookCategory.incomeOption.id }?.name, "收入")
        try await store.toggleCategory(id: BookCategory.incomeOption.id)
        try await store.bootstrap()
        categories = try await store.allCategories()
        XCTAssertEqual(categories.first { $0.id == BookCategory.incomeOption.id }?.isActive, false)
        XCTAssertEqual(categories.first { $0.id == custom.id }, custom)
    }

    private func testPNG(side: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        return renderer.pngData { context in
            UIColor.systemBrown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func isolatedStore() throws -> LocalStore {
        try LocalStore(databaseURL: sandbox.appendingPathComponent("ledger.sqlite"))
    }

    private func entry(id: String, cents: Int64, kind: EntryKind, category: String) -> BookEntry {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return BookEntry(id: id, cents: cents, kind: kind, occurredAt: date,
                         categoryID: category, iconChoice: category, note: "",
                         sourceID: nil, originalEntryID: nil, createdAt: date, updatedAt: date)
    }
}
