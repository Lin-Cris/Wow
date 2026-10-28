import SwiftUI
import PhotosUI
import UIKit

private enum AccountsSheet: Identifiable {
    case add, edit(BookAccount), transfer, entry(BookAccount)
    var id: String {
        switch self {
        case .add: "add"
        case .edit(let account): "edit-\(account.id)"
        case .transfer: "transfer"
        case .entry(let account): "entry-\(account.id)"
        }
    }
}

private enum AccountActivity: Identifiable {
    case entry(BookEntry)
    case transfer(AccountTransfer)

    var id: String {
        switch self {
        case .entry(let entry): "entry-\(entry.id)"
        case .transfer(let transfer): "transfer-\(transfer.id)"
        }
    }

    var occurredAt: Date {
        switch self {
        case .entry(let entry): entry.occurredAt
        case .transfer(let transfer): transfer.occurredAt
        }
    }
}

struct AccountsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: AccountsSheet?
    @State private var selectedAccountID: String?
    @State private var archiveTarget: BookAccount?
    @State private var showingArchiveConfirmation = false
    @State private var transferToDelete: AccountTransfer?
    @State private var showingTransferDeleteConfirmation = false
    @State private var newlyAddedAccountID: String?
    @State private var activityRevision = 0
    @State private var detailContentVisible = false
    private let cardRevealHeight: CGFloat = 64
    private let compactCardHeight: CGFloat = 156
    private let expandedCardHeight: CGFloat = 176
    @Namespace private var walletCardNamespace
    @AppStorage("counter.accounts.walletOrder") private var walletOrderRaw = ""

    private var activeAssets: [BookAccount] { model.activeAccounts.filter { !$0.type.isLiability } }
    private var activeDebts: [BookAccount] { model.activeAccounts.filter { $0.type.isLiability } }
    private var walletAccounts: [BookAccount] {
        let active = model.activeAccounts
        let ids = walletOrderRaw.split(separator: "|").map(String.init)
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return active.sorted { lhs, rhs in
            let left = position[lhs.id]
            let right = position[rhs.id]
            if let left, let right, left != right { return left < right }
            if left != nil { return true }
            if right != nil { return false }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id < rhs.id
        }
    }
    private var selectedAccount: BookAccount? { walletAccounts.first { $0.id == selectedAccountID } }
    private var archived: [BookAccount] { model.accounts.filter { !$0.isActive } }
    private var assetsCents: Int64 { activeAssets.reduce(0) { LedgerMath.add($0, model.accountBalances[$1.id] ?? openingBalance(for: $1)) } }
    private var debtsCents: Int64 { activeDebts.reduce(0) { LedgerMath.add($0, model.accountBalances[$1.id] ?? openingBalance(for: $1)) } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let selectedAccount { detailTopBar(for: selectedAccount) }
                else { topBar }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            ZStack {
                // Keep the overview mounted, including its native scroll position.
                accountOverview
                    .allowsHitTesting(selectedAccountID == nil)
                    .accessibilityHidden(selectedAccountID != nil)
                if let selectedAccount {
                    cardDetail(for: selectedAccount)
                        .zIndex(1)
                        .transition(.identity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dynamicTypeSize(.large)
        .scrollIndicators(.hidden)
        .background(AccountPalette.canvas.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .task { await model.refreshAccountOverview() }
        .task(id: selectedAccountID) {
            detailContentVisible = false
            guard selectedAccountID != nil else { return }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.24)) {
                detailContentVisible = true
            }
        }
        .onChange(of: model.activeAccounts.map(\.id)) { _, ids in
            if let selectedAccountID, !ids.contains(selectedAccountID) {
                withAnimation(walletTransition) { self.selectedAccountID = nil }
            }
        }
        .sheet(item: $sheet, onDismiss: {
            activityRevision += 1
            Task { await model.refreshAccountOverview() }
        }) { value in
            switch value {
            case .add:
                AccountEditorView(model: model, account: nil) { account in
                    walletOrderRaw = ([account.id] + walletAccounts.filter { $0.id != account.id }.map(\.id)).joined(separator: "|")
                    newlyAddedAccountID = account.id
                }
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            case .edit(let account):
                AccountEditorView(model: model, account: account)
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            case .entry(let account):
                EntryEditorView(model: model, route: .create(.expense), initialAccountID: account.id)
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            case .transfer:
                AccountTransferSheet(model: model)
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
            }
        }
        .confirmationDialog("停用这个账户？", isPresented: $showingArchiveConfirmation, titleVisibility: .visible) {
            Button("停用账户", role: .destructive) {
                if let archiveTarget {
                    Task { do { try await model.archiveAccount(archiveTarget) } catch { model.toast = error.localizedDescription } }
                }
                archiveTarget = nil
            }
            Button("取消", role: .cancel) { archiveTarget = nil }
        } message: {
            Text("历史流水会保留；停用后不会出现在记账账户选择中。")
        }
        .confirmationDialog("删除这笔转账 / 还款？", isPresented: $showingTransferDeleteConfirmation, titleVisibility: .visible) {
            Button("删除转账 / 还款", role: .destructive) {
                if let transferToDelete {
                    Task { do { try await model.deleteTransfer(transferToDelete) } catch { model.toast = error.localizedDescription } }
                }
                transferToDelete = nil
            }
            Button("取消", role: .cancel) { transferToDelete = nil }
        } message: {
            Text("账户余额和本期应还金额会一并恢复。")
        }
    }

    private var accountOverview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    netWorthCard.id("accounts.summary").opacity(selectedAccountID == nil ? 1 : 0)
                    if walletAccounts.isEmpty {
                        walletEmptyState
                    } else {
                        walletHeading.opacity(selectedAccountID == nil ? 1 : 0)
                        walletDeck
                        if !model.accountTransfers.isEmpty { transferSection.padding(.top, 10).opacity(selectedAccountID == nil ? 1 : 0) }
                    }
                    if !archived.isEmpty { archivedSection.opacity(selectedAccountID == nil ? 1 : 0) }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
            .accessibilityIdentifier("accounts.overviewScroll")
            .onChange(of: newlyAddedAccountID) { _, id in
                guard id != nil else { return }
                withAnimation(walletTransition) { proxy.scrollTo("accounts.summary", anchor: .top) }
            }
        }
    }

    private var walletTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .interactiveSpring(response: 0.48, dampingFraction: 0.88, blendDuration: 0.12)
    }

    private func cardDetail(for account: BookAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The same full card moves above the deck; only one geometry source exists.
            walletCard(account, isExpanded: true)
                .matchedGeometryEffect(id: account.id, in: walletCardNamespace)
                .simultaneousGesture(detailCardBrowseGesture(from: account))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("accounts.selectedCard")

            HStack(spacing: 20) { detailActions(for: account) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.subheadline).buttonStyle(.borderless).tint(AccountPalette.accent)
                .padding(.horizontal, 4)
                .opacity(detailContentVisible ? 1 : 0)
                .offset(y: detailContentVisible || reduceMotion ? 0 : 16)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))

            // Keep the card at the top while browsing, so collapse always starts here.
            ScrollView {
                AccountRecentActivityView(model: model, account: account, revision: activityRevision)
                    .id(account.id)
                    .transaction { $0.animation = nil }
                    .padding(.bottom, 24)
            }
            .opacity(detailContentVisible ? 1 : 0)
            .offset(y: detailContentVisible || reduceMotion ? 0 : 16)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
            .accessibilityIdentifier("accounts.activityScroll")
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }

    private func detailTopBar(for account: BookAccount) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(walletTransition) { selectedAccountID = nil }
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起账户").accessibilityIdentifier("accounts.closeDetail")
            Spacer(minLength: 0)
            Text("账户详情").font(.headline)
            Spacer(minLength: 0)
            accountActionsMenu(for: account).frame(width: 44, height: 44)
        }
        .foregroundStyle(AccountPalette.ink)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("返回").accessibilityIdentifier("accounts.back")
            Text("账户").font(.headline)
            Spacer(minLength: 0)
            Button { sheet = .transfer } label: {
                Image(systemName: "arrow.left.arrow.right").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("转账 / 还款").accessibilityIdentifier("accounts.transfer")
            .disabled(activeAssets.isEmpty || model.activeAccounts.count < 2)
            Button { sheet = .add } label: {
                Label("添加", systemImage: "plus").font(.subheadline.weight(.semibold))
                    .padding(.vertical, 12).contentShape(Rectangle())
            }
            .accessibilityLabel("添加账户").accessibilityIdentifier("accounts.add")
        }
        .buttonStyle(.plain).foregroundStyle(AccountPalette.ink)
    }

    @ViewBuilder private func detailActions(for account: BookAccount) -> some View {
        Button("记一笔", systemImage: "plus") { sheet = .entry(account) }
            .accessibilityIdentifier("accounts.record")
        Button("编辑账户", systemImage: "pencil") { sheet = .edit(account) }
            .accessibilityIdentifier("accounts.edit")
        Button("转账 / 还款", systemImage: "arrow.left.arrow.right") { sheet = .transfer }
            .disabled(activeAssets.isEmpty || model.activeAccounts.count < 2)
    }

    private var netWorthCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                netWorthAmount
                Spacer(minLength: 0)
                metric("资产", value: assetsCents)
                metric("负债", value: debtsCents)
            }
            VStack(alignment: .leading, spacing: 10) {
                netWorthAmount
                HStack(spacing: 24) {
                    metric("资产", value: assetsCents)
                    metric("负债", value: debtsCents)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var netWorthAmount: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("净资产").font(.caption).foregroundStyle(AccountPalette.secondary)
            Text(CounterFormat.amount(LedgerMath.subtract(assetsCents, debtsCents)))
                .font(.title2.weight(.semibold)).foregroundStyle(AccountPalette.ink)
                .monospacedDigit().accessibilityIdentifier("accounts.netWorth")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func metric(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(AccountPalette.secondary)
            Text(CounterFormat.amount(value)).font(.subheadline.weight(.medium))
                .foregroundStyle(AccountPalette.ink).monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var walletEmptyState: some View {
        ContentUnavailableView("还没有账户", systemImage: "wallet.pass", description: Text("轻点右上角添加，记录现金、银行卡或投资账户。"))
    }

    private var walletHeading: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("我的账户").font(.subheadline.weight(.semibold))
            Text("\(walletAccounts.count)").font(.caption).foregroundStyle(AccountPalette.secondary)
            Spacer()
        }
        .foregroundStyle(AccountPalette.ink)
    }

    private var walletDeck: some View {
        let accounts = walletAccounts
        return VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                Button {
                    withAnimation(walletTransition) { selectedAccountID = account.id }
                } label: {
                    ZStack {
                        // A fixed placeholder preserves deck layout throughout the transition.
                        Color.clear.frame(height: compactCardHeight)
                        if selectedAccountID != account.id {
                            walletCard(account, isExpanded: false)
                                .matchedGeometryEffect(id: account.id, in: walletCardNamespace)
                                .transition(.identity)
                        }
                    }
                    .frame(height: index == accounts.count - 1 ? compactCardHeight : cardRevealHeight, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .draggable(account.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let movingID = ids.first, movingID != account.id,
                          walletAccounts.contains(where: { $0.id == movingID }) else { return false }
                    var order = walletAccounts.map(\.id)
                    guard let source = order.firstIndex(of: movingID),
                          let target = order.firstIndex(of: account.id) else { return false }
                    order.remove(at: source)
                    order.insert(movingID, at: target)
                    withAnimation(walletTransition) { walletOrderRaw = order.joined(separator: "|") }
                    UISelectionFeedbackGenerator().selectionChanged()
                    return true
                }
                .accessibilityLabel("\(account.displayName)，\(account.displayTypeLabel)，\(account.type.isLiability ? "欠款" : "余额") \(CounterFormat.amount(accountBalance(for: account)))")
                .accessibilityHint("点按查看流水，长按拖动调整顺序")
                .accessibilityIdentifier("accounts.card.\(account.id)")
                .frame(height: index == accounts.count - 1 ? compactCardHeight : cardRevealHeight)
                .opacity(selectedAccountID == nil || selectedAccountID == account.id ? 1 : 0)
                .offset(y: selectedAccountID == nil || selectedAccountID == account.id || reduceMotion ? 0 : 24)
                .id(account.id)
                // Later cards cover the lower part of earlier cards and receive those taps.
                .zIndex(selectedAccountID == account.id ? Double(accounts.count + 1) : Double(index))
            }
        }
        .animation(walletTransition, value: model.activeAccounts.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts.walletDeck")
    }

    private func walletCard(_ account: BookAccount, isExpanded: Bool) -> some View {
        WalletStackCard(name: account.displayName, brandIcon: account.brandIcon, provider: account.displayProviderName,
                        category: account.displayTypeLabel, icon: account.displayCardIcon,
                        iconPNG: account.cardIconPNGBase64.flatMap { Data(base64Encoded: $0) },
                        color: account.displayCardColor,
                        amount: CounterFormat.amount(accountBalance(for: account)),
                        secondaryInfo: accountSecondaryInfo(for: account),
                        height: isExpanded ? expandedCardHeight : compactCardHeight)
    }

    private func accountBalance(for account: BookAccount) -> Int64 {
        model.accountBalances[account.id] ?? openingBalance(for: account)
    }

    private func detailCardBrowseGesture(from account: BookAccount) -> some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > 54, abs(horizontal) > abs(value.translation.height) * 1.25,
                      let index = walletAccounts.firstIndex(where: { $0.id == account.id }) else { return }
                let targetIndex = index + (horizontal < 0 ? 1 : -1)
                guard walletAccounts.indices.contains(targetIndex) else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(walletTransition) { selectedAccountID = walletAccounts[targetIndex].id }
            }
    }

    private func accountSecondaryInfo(for account: BookAccount) -> String {
        let balance = accountBalance(for: account)
        if account.type == .creditCard, let limit = account.creditLimitCents {
            return "可用额度  \(CounterFormat.amount(min(limit, max(0, limit - balance))))"
        }
        if account.type.isLiability, (account.dueAmountCents ?? 0) > 0 {
            let date = account.effectiveRepaymentDay.map { " · 每月 \($0) 日还款" } ?? ""
            return "本期应还  \(CounterFormat.amount(account.dueAmountCents ?? 0))\(date)"
        }
        return ""
    }

    private func accountActionsMenu(for account: BookAccount) -> some View {
        Menu {
            Button("编辑账户", systemImage: "pencil") { sheet = .edit(account) }
            Button("置顶账户", systemImage: "arrow.up.to.line") {
                Task {
                    do {
                        try await model.moveAccountToTop(account)
                        walletOrderRaw = ([account.id] + walletAccounts.filter { $0.id != account.id }.map(\.id)).joined(separator: "|")
                    }
                    catch { model.toast = error.localizedDescription }
                }
            }
            Button("停用账户", systemImage: "archivebox", role: .destructive) {
                archiveTarget = account
                showingArchiveConfirmation = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AccountPalette.ink)
                .frame(width: 36, height: 36)
                .background(AccountPalette.paper, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(account.displayName)更多操作")
        .accessibilityIdentifier("accounts.cardActions.\(account.id)")
    }

    private var transferSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AccountPalette.purple)
                Text("最近转账 / 还款").font(.system(size: 14, weight: .semibold)).foregroundStyle(AccountPalette.ink)
            }
            AccountSurface(inset: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(model.accountTransfers.prefix(5).enumerated()), id: \.element.id) { index, transfer in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                                .font(.system(size: 22)).foregroundStyle(AccountPalette.purple.opacity(0.82))
                            AccountBrandMark(account: model.account(for: transfer.fromAccountID), side: 15)
                            AccountBrandMark(account: model.account(for: transfer.toAccountID), side: 15)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(model.accountName(transfer.fromAccountID) ?? "账户") → \(model.accountName(transfer.toAccountID) ?? "账户")")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AccountPalette.ink).lineLimit(1)
                                Text(transfer.note.isEmpty ? transfer.occurredAt.formatted(.dateTime.month().day()) : transfer.note)
                                    .font(.system(size: 10)).foregroundStyle(AccountPalette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Text(CounterFormat.amount(transfer.cents))
                                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(AccountPalette.ink).monospacedDigit()
                            Menu {
                                Button("删除转账 / 还款", systemImage: "trash", role: .destructive) {
                                    transferToDelete = transfer
                                    showingTransferDeleteConfirmation = true
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(AccountPalette.secondary)
                                    .frame(width: 26, height: 38)
                            }
                            .accessibilityLabel("删除这笔转账或还款")
                        }
                        .padding(.horizontal, 7).padding(.vertical, 8)
                        if index < min(5, model.accountTransfers.count) - 1 {
                            Rectangle().fill(AccountPalette.divider).frame(height: 1).padding(.leading, 39)
                        }
                    }
                }
            }
        }
    }

    private var archivedSection: some View {
        DisclosureGroup {
            AccountSurface(inset: 7) {
                VStack(spacing: 0) {
                    ForEach(archived) { account in
                        Button { sheet = .edit(account) } label: {
                            HStack(spacing: 10) {
                                AccountBrandMark(account: account, side: 22)
                                    .frame(width: 34, height: 34)
                                Text(account.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(AccountPalette.ink)
                                Text("已停用").font(.system(size: 10)).foregroundStyle(AccountPalette.secondary)
                                Spacer()
                                Text(CounterFormat.amount(model.accountBalances[account.id] ?? openingBalance(for: account)))
                                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(AccountPalette.secondary)
                            }.padding(8)
                        }.buttonStyle(.plain)
                    }
                }
            }
        } label: {
            Text("已停用账户（\(archived.count)）").font(.system(size: 12, weight: .medium)).foregroundStyle(AccountPalette.secondary)
        }
        .tint(AccountPalette.secondary)
        .padding(.horizontal, 4)
    }

    private func openingBalance(for account: BookAccount) -> Int64 {
        LedgerMath.add(account.openingBalanceCents, account.balanceAdjustmentCents ?? 0)
    }
}

private struct AccountRecentActivityView: View {
    let model: AppModel
    let account: BookAccount
    let revision: Int
    @State private var cardEntries: [BookEntry] = []
    @State private var isLoadingCardEntries = false
    @State private var cardEntriesError: String?
    @State private var entriesRequestID = UUID()

    private var selectedAccountActivities: [AccountActivity] {
        let selectedAccountID = account.id
        let entries = cardEntries.map(AccountActivity.entry)
        let transfers = model.accountTransfers
            .filter { $0.fromAccountID == selectedAccountID || $0.toAccountID == selectedAccountID }
            .map(AccountActivity.transfer)
        return Array((entries + transfers).sorted { $0.occurredAt > $1.occurredAt }.prefix(30))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近流水").font(.system(size: 21, weight: .bold)).foregroundStyle(AccountPalette.ink)
                Spacer()
                Text("最近 30 笔").font(.system(size: 11, weight: .medium)).foregroundStyle(AccountPalette.secondary)
            }

            AccountSurface(inset: 14) {
                if isLoadingCardEntries && cardEntries.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().tint(AccountPalette.purple)
                        Text("正在读取这张卡的流水…").font(.system(size: 12)).foregroundStyle(AccountPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                } else if let cardEntriesError {
                    VStack(spacing: 8) {
                        Text("暂时无法读取流水").font(.system(size: 13, weight: .semibold)).foregroundStyle(AccountPalette.ink)
                        Text(cardEntriesError).font(.system(size: 10)).foregroundStyle(AccountPalette.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await loadSelectedAccountEntries() } }
                            .font(.system(size: 12, weight: .semibold)).tint(AccountPalette.purple)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74)
                } else if selectedAccountActivities.isEmpty {
                    ContentUnavailableView("还没有流水", systemImage: account.type.symbol, description: Text("使用这个账户记账或转账后，记录会显示在这里。"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(selectedAccountActivities.enumerated()), id: \.element.id) { index, activity in
                            cardActivityRow(activity, account: account)
                            if index < selectedAccountActivities.count - 1 {
                                Rectangle().fill(AccountPalette.divider).frame(height: 1).padding(.leading, 43)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(account.id)-\(revision)") { await loadSelectedAccountEntries() }
    }

    @MainActor
    private func loadSelectedAccountEntries() async {
        let accountID = account.id
        let requestID = UUID()
        entriesRequestID = requestID
        cardEntries = []
        cardEntriesError = nil
        isLoadingCardEntries = true
        do {
            let entries = try await model.recentEntries(forAccountID: accountID, limit: 30)
            guard !Task.isCancelled, entriesRequestID == requestID else { return }
            cardEntries = entries
            isLoadingCardEntries = false
        } catch {
            guard !Task.isCancelled, entriesRequestID == requestID else { return }
            cardEntriesError = error.localizedDescription
            isLoadingCardEntries = false
        }
    }

    @ViewBuilder
    private func cardActivityRow(_ activity: AccountActivity, account: BookAccount) -> some View {
        switch activity {
        case .entry(let entry):
            let category = entry.resolvedCategory(in: model.categories)
            HStack(spacing: 10) {
                CounterCategoryArtwork(assetName: entry.iconChoice.isEmpty ? (category?.symbol ?? "custom_category") : entry.iconChoice, side: 28, iconPNGBase64: category?.iconPNGBase64)
                    .frame(width: 34, height: 34)
                    .background(AccountPalette.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (category?.name ?? entry.kind.label) : entry.note)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(AccountPalette.ink).lineLimit(1)
                    Text("\(category?.name ?? entry.kind.label) · \(entry.occurredAt.formatted(.dateTime.year().month().day().hour().minute()))")
                        .font(.system(size: 10)).foregroundStyle(AccountPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(entry.signedCents < 0 ? "−" : "+")\(CounterFormat.amount(entry.cents))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.signedCents < 0 ? AccountPalette.ink : Color(red: 0.12, green: 0.56, blue: 0.38))
                    .monospacedDigit().lineLimit(1)
            }
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
        case .transfer(let transfer):
            let isOutgoing = transfer.fromAccountID == account.id
            let otherAccountID = isOutgoing ? transfer.toAccountID : transfer.fromAccountID
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 25)).foregroundStyle(AccountPalette.purple.opacity(0.82))
                    .frame(width: 34, height: 34)
                AccountBrandMark(account: model.account(for: otherAccountID), side: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isOutgoing ? "转出至\(model.accountName(otherAccountID) ?? "其他账户")" : "来自\(model.accountName(otherAccountID) ?? "其他账户")")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(AccountPalette.ink).lineLimit(1)
                    Text("\(transfer.dueAmountReductionCents > 0 ? "还款" : "转账") · \(transfer.occurredAt.formatted(.dateTime.year().month().day().hour().minute()))")
                        .font(.system(size: 10)).foregroundStyle(AccountPalette.secondary).lineLimit(1)
                    if !transfer.note.isEmpty {
                        Text(transfer.note).font(.system(size: 10)).foregroundStyle(AccountPalette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(isOutgoing ? "−" : "+")\(CounterFormat.amount(transfer.cents))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(AccountPalette.ink).monospacedDigit().lineLimit(1)
            }
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
        }
    }

}

private struct AccountInstitutionPreset: Identifiable {
    let id: String
    let title: String
    let hint: String
    let symbol: String
    let type: AccountType
    let icon: AccountCardIcon
    let color: AccountCardColor
    let accountName: String
    var brandIcon: String? { icon.assetName ?? AccountBrand.resolve(providerName: title, accountName: accountName)?.assetName }

    static let categories = [
        AccountInstitutionPreset(id: "cash", title: "现金账户", hint: "纸币与零钱", symbol: "banknote.fill", type: .cash, icon: .cash, color: .forest, accountName: "纸币现金"),
        AccountInstitutionPreset(id: "investment", title: "投资账户", hint: "基金、证券", symbol: "chart.pie.fill", type: .investment, icon: .fund, color: .teal, accountName: "基金"),
        AccountInstitutionPreset(id: "bank", title: "银行账户", hint: "借记卡、信用卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .midnight, accountName: "银行卡"),
        AccountInstitutionPreset(id: "wallet", title: "支付账户", hint: "电子钱包", symbol: "wallet.pass.fill", type: .eWallet, icon: .wallet, color: .ocean, accountName: "电子钱包"),
        AccountInstitutionPreset(id: "borrowing", title: "借入", hint: "出借人与收款账户", symbol: "person.fill", type: .otherDebt, icon: .work, color: .copper, accountName: ""),
        AccountInstitutionPreset(id: "custom", title: "自定义账户", hint: "名称、图标和类别由你设置", symbol: "square.grid.2x2.fill", type: .otherAsset, icon: .star, color: .graphite, accountName: "")
    ]

    static let wallets = [
        AccountInstitutionPreset(id: "yuebao", title: "余额宝", hint: "支付宝 · 理财", symbol: "chart.line.uptrend.xyaxis", type: .investment, icon: .alipay, color: .copper, accountName: "余额宝"),
        AccountInstitutionPreset(id: "alipay", title: "支付宝", hint: "电子钱包", symbol: "wallet.pass.fill", type: .eWallet, icon: .alipay, color: .ocean, accountName: "支付宝"),
        AccountInstitutionPreset(id: "wechat", title: "微信", hint: "电子钱包", symbol: "message.fill", type: .eWallet, icon: .wechat, color: .forest, accountName: "微信"),
        AccountInstitutionPreset(id: "unionpay", title: "云闪付", hint: "电子钱包", symbol: "wave.3.right", type: .eWallet, icon: .unionpay, color: .ruby, accountName: "云闪付"),
        AccountInstitutionPreset(id: "jd", title: "京东金融", hint: "电子钱包", symbol: "bag.fill", type: .eWallet, icon: .jdFinance, color: .ruby, accountName: "京东金融"),
        AccountInstitutionPreset(id: "huabei", title: "花呗", hint: "信用支付", symbol: "creditcard.fill", type: .creditCard, icon: .huabei, color: .ocean, accountName: "花呗")
    ]

    static let banks = [
        AccountInstitutionPreset(id: "cmb", title: "招商银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .ruby, accountName: "招商银行"),
        AccountInstitutionPreset(id: "boc", title: "中国银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .midnight, accountName: "中国银行"),
        AccountInstitutionPreset(id: "abc", title: "中国农业银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .forest, accountName: "中国农业银行"),
        AccountInstitutionPreset(id: "icbc", title: "中国工商银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .ruby, accountName: "中国工商银行"),
        AccountInstitutionPreset(id: "ccb", title: "中国建设银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .ocean, accountName: "中国建设银行"),
        AccountInstitutionPreset(id: "bocom", title: "交通银行", hint: "银行卡", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .midnight, accountName: "交通银行"),
        AccountInstitutionPreset(id: "other-bank", title: "其他银行", hint: "自定义银行", symbol: "building.columns.fill", type: .debitCard, icon: .bank, color: .graphite, accountName: "其他银行")
    ]

    static let other = [
        AccountInstitutionPreset(id: "overseas", title: "海外 / 外币账户", hint: "银行或钱包", symbol: "globe.americas.fill", type: .debitCard, icon: .bank, color: .plum, accountName: "海外账户")
    ]
}

struct AccountEditorView: View {
    @Bindable var model: AppModel
    let account: BookAccount?
    var onSave: ((BookAccount) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    @State private var searchText = ""
    @State private var choosingInstitution: Bool
    @State private var name: String
    @State private var providerName: String
    @State private var type: AccountType
    @State private var cardLabel: String
    @State private var cardIcon: AccountCardIcon
    @State private var cardColor: AccountCardColor
    @State private var cardIconPNGBase64: String?
    @State private var balanceText: String
    @State private var limitText: String
    @State private var dueAmountText: String
    @State private var hasDueDate: Bool
    @State private var repaymentDay: Int
    @ObservedObject private var notifications = ReminderNotifications.shared
    @State private var isActive: Bool
    @State private var showingAppearance = false
    @State private var showingIconPicker = false
    private let initialBalanceText: String
    @State private var error: String?
    @State private var isSaving = false
    @State private var newAccountID = "account-\(UUID().uuidString.lowercased())"
    @State private var isBorrowing = false
    @State private var borrowingRecipientID = ""

    init(model: AppModel, account: BookAccount?, onSave: ((BookAccount) -> Void)? = nil) {
        self.model = model
        self.account = account
        self.onSave = onSave
        let selectedType = account?.type ?? .debitCard
        let currentBalance = account.map {
            model.accountBalances[$0.id] ?? LedgerMath.add($0.openingBalanceCents, $0.balanceAdjustmentCents ?? 0)
        } ?? 0
        initialBalanceText = account == nil ? "" : AccountEditorView.amountText(currentBalance)
        _choosingInstitution = State(initialValue: account == nil)
        _name = State(initialValue: account?.displayName ?? "")
        _providerName = State(initialValue: account?.providerName ?? "")
        _type = State(initialValue: selectedType)
        _cardLabel = State(initialValue: account?.cardLabelOverride ?? selectedType.title)
        _cardIcon = State(initialValue: account?.cardIconOverride ?? account?.brand.flatMap { AccountCardIcon(rawValue: $0.rawValue) } ?? account?.displayCardIcon ?? AccountCardIcon.defaultIcon(for: selectedType))
        _cardColor = State(initialValue: account?.displayCardColor ?? AccountCardColor.defaultColor(for: selectedType))
        _cardIconPNGBase64 = State(initialValue: account?.cardIconPNGBase64)
        _balanceText = State(initialValue: initialBalanceText)
        _limitText = State(initialValue: account?.creditLimitCents.map(AccountEditorView.amountText) ?? "")
        _dueAmountText = State(initialValue: account?.dueAmountCents.map(AccountEditorView.amountText) ?? "")
        _hasDueDate = State(initialValue: account?.repaymentReminderIsEnabled ?? false)
        _repaymentDay = State(initialValue: account?.effectiveRepaymentDay ?? 7)
        _isActive = State(initialValue: account?.isActive ?? true)
        _borrowingRecipientID = State(initialValue: model.activeAccounts.first(where: { !$0.type.isLiability })?.id ?? "")
    }

    private var isLiability: Bool { type.isLiability }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var previewName: String { trimmedName.isEmpty ? "账户名称" : trimmedName }

    var body: some View {
        NavigationStack {
            Group {
                if choosingInstitution { institutionChooser }
                else { accountDetails }
            }
            .background(AccountPalette.canvas.ignoresSafeArea())
            .navigationTitle(choosingInstitution ? "添加账户" : (account == nil ? "新账户" : "编辑账户"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成输入") { focusedField = nil }.accessibilityIdentifier("account.dismissKeyboard")
                }
                if !choosingInstitution {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await save() } }.fontWeight(.semibold)
                            .disabled(isSaving || (isBorrowing && borrowingRecipientID.isEmpty)).accessibilityIdentifier("account.save")
                    }
                }
            }
            .sheet(isPresented: $showingIconPicker) {
                AccountIconPicker(icon: $cardIcon, pngBase64: $cardIconPNGBase64)
            }
            .task { _ = await notifications.checkPermission() }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .dynamicTypeSize(.large)
    }

    private var institutionChooser: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    presetRow(AccountInstitutionPreset.categories.last!)
                }
                Section("账户类型") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                            ForEach(AccountInstitutionPreset.categories.dropLast()) { preset in
                                Button { select(preset) } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: preset.symbol).font(.body)
                                        Text(preset.title.replacingOccurrences(of: "账户", with: "")).font(.caption)
                                    }
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(AccountPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("account.provider.\(preset.id)")
                            }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                Section("常用账户") {
                    ForEach(AccountInstitutionPreset.wallets) { presetRow($0) }
                }
                Section("银行") {
                    ForEach(AccountInstitutionPreset.banks) { presetRow($0) }
                }
                Section("其他来源") {
                    ForEach(AccountInstitutionPreset.other) { presetRow($0) }
                }
            } else {
                Section("搜索结果") {
                    ForEach(searchResults) { presetRow($0) }
                    if searchResults.isEmpty {
                        Text("没有找到匹配的账户").foregroundStyle(AccountPalette.secondary)
                        presetRow(AccountInstitutionPreset.categories.last!)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .listSectionSpacing(16)
        .contentMargins(.top, 8, for: .scrollContent)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索银行、支付平台或账户")
        .autocorrectionDisabled()
        .accessibilityIdentifier("account.providerScroll")
    }

    private var searchResults: [AccountInstitutionPreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = AccountBrand.resolve(providerName: query, accountName: nil)
        return (AccountInstitutionPreset.wallets + AccountInstitutionPreset.banks + AccountInstitutionPreset.categories + AccountInstitutionPreset.other).filter {
            [$0.title, $0.hint, $0.accountName, $0.type.title, $0.id].contains { $0.localizedStandardContains(query) }
                || (brand != nil && brand?.assetName == $0.brandIcon)
        }
    }

    private func presetRow(_ preset: AccountInstitutionPreset) -> some View {
        Button { select(preset) } label: {
            HStack(spacing: 12) {
                AccountIconArtwork(assetName: preset.brandIcon, icon: preset.icon, side: 30)
                    .foregroundStyle(AccountPalette.accent)
                    .padding(5).background(AccountPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title).font(.body).foregroundStyle(AccountPalette.ink)
                    Text(preset.hint).font(.caption).foregroundStyle(AccountPalette.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AccountPalette.secondary)
            }
            .padding(.vertical, 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("account.provider.\(preset.id)")
        .listRowBackground(AccountPalette.paper)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    private var editableTypes: [AccountType] {
        // Keep historical expense/repayment signs intact when editing existing accounts.
        guard let account else { return AccountType.allCases }
        return account.type.isLiability ? AccountType.liabilities : AccountType.assets
    }

    private var accountDetails: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AccountIconArtwork(assetName: cardIcon.assetName, icon: cardIcon, pngBase64: cardIconPNGBase64, side: 40)
                        .foregroundStyle(AccountPalette.ink)
                        .padding(6).background(AccountPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(previewName).font(.headline).foregroundStyle(AccountPalette.ink)
                        Text(isBorrowing ? "借入" : type.title).font(.caption).foregroundStyle(AccountPalette.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                labeledField(isBorrowing ? "出借人姓名" : "账户名称", placeholder: isBorrowing ? "例如：张三" : "例如：余额宝、基金、纸币现金", text: $name, identifier: "account.name")
                Button { focusedField = nil; showingIconPicker = true } label: {
                    HStack {
                        Text("账户图标")
                        Spacer()
                        AccountIconArtwork(assetName: cardIcon.assetName, icon: cardIcon, pngBase64: cardIconPNGBase64, side: 24)
                            .foregroundStyle(AccountPalette.ink)
                        Text(cardIconPNGBase64 == nil ? cardIcon.title : "自定义图片").foregroundStyle(AccountPalette.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AccountPalette.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("account.chooseIcon")
                Menu {
                    ForEach(editableTypes) { option in
                        Button { selectType(option) } label: {
                            if type == option && !isBorrowing { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                        .accessibilityIdentifier("account.type.\(option.id)")
                    }
                    if account == nil {
                        Button {
                            selectType(.otherDebt)
                            isBorrowing = true
                            cardLabel = "借入"
                        } label: {
                            if isBorrowing { Label("借入", systemImage: "checkmark") }
                            else { Text("借入") }
                        }.accessibilityIdentifier("account.type.borrowing")
                    }
                } label: {
                    HStack {
                        Text("账户类别").foregroundStyle(AccountPalette.ink)
                        Spacer()
                        Text(isBorrowing ? "借入" : type.title).foregroundStyle(AccountPalette.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(AccountPalette.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("account.type")
                // A borrowing form's account is the creditor. Assets belong only in the recipient picker.
                .disabled(isBorrowing)
            } footer: {
                if account != nil {
                    Text("类别可在同一资产或负债性质内修改，保留历史记账和还款含义。")
                }
            }
            Section {
                HStack {
                    Text(isBorrowing ? "借入金额" : "金额")
                    Spacer()
                    Text("¥").foregroundStyle(AccountPalette.secondary)
                    TextField("0.00", text: $balanceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .monospacedDigit().focused($focusedField, equals: "account.balance").accessibilityIdentifier("account.balance")
                }
                if type == .creditCard { labeledAmount("信用额度（选填）", text: $limitText, identifier: "account.creditLimit") }
                if isBorrowing {
                    Picker("收款账户", selection: $borrowingRecipientID) {
                        ForEach(model.activeAccounts.filter { !$0.type.isLiability }) { recipient in
                            Text(recipient.displayName).tag(recipient.id)
                        }
                    }.accessibilityIdentifier("account.borrowing.recipient")
                    if model.activeAccounts.allSatisfy({ $0.type.isLiability }) {
                        Text("请先添加一个资产账户作为收款账户。")
                            .font(.footnote).foregroundStyle(AccountPalette.secondary)
                    }
                }
            } header: {
                Text(isBorrowing ? "借入" : (account == nil ? (isLiability ? "初始欠款" : "初始余额") : (isLiability ? "当前欠款" : "当前余额")))
            } footer: {
                if account != nil { Text("修改金额会调整账户余额；只修改名称或图标不会影响流水。") }
            }
            if isLiability && !isBorrowing {
                Section("还款") {
                    labeledAmount("本期应还（选填）", text: $dueAmountText, identifier: "account.dueAmount")
                    Toggle("还款提醒", isOn: $hasDueDate).accessibilityIdentifier("account.repaymentReminder")
                    if hasDueDate {
                        Picker("还款日", selection: $repaymentDay) {
                            ForEach(1...31, id: \.self) { Text("每月 \($0) 日").tag($0) }
                        }
                        .accessibilityIdentifier("account.repaymentDay")
                        Text(ReminderNotifications.repaymentNote(day: repaymentDay)).font(.footnote).foregroundStyle(AccountPalette.secondary)
                        if !notifications.notificationsAllowed { Text(notifications.message).font(.footnote).foregroundStyle(AccountPalette.secondary) }
                    }
                }
            }
            Section("选填资料") {
                labeledField("所属机构", placeholder: "银行或平台名称", text: $providerName, identifier: "account.provider")
                DisclosureGroup("外观", isExpanded: $showingAppearance) {
                    labeledField("显示标签", placeholder: type.title, text: $cardLabel, identifier: "account.cardLabel")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                        ForEach(AccountCardColor.allCases) { option in
                            Button { cardColor = option } label: {
                                Circle().fill(option.swiftUIColor).frame(width: 28, height: 28)
                                    .overlay { if cardColor == option { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).accessibilityLabel(option.title).accessibilityIdentifier("account.cardColor.\(option.id)")
                        }
                    }
                }
                if account != nil { Toggle("账户启用", isOn: $isActive) }
            }
        }
        .font(.body).tint(AccountPalette.accent)
        .scrollContentBackground(.hidden).background(AccountPalette.canvas)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("account.editorScroll")
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(AccountPalette.secondary)
            TextField(placeholder, text: text).font(.body).foregroundStyle(AccountPalette.ink)
                .textInputAutocapitalization(.never).focused($focusedField, equals: identifier).accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 2)
    }

    private func labeledAmount(_ title: String, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("¥").foregroundStyle(AccountPalette.secondary)
            TextField("0.00", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(maxWidth: 120).focused($focusedField, equals: identifier).accessibilityIdentifier(identifier)
        }
    }

    private func select(_ preset: AccountInstitutionPreset) {
        providerName = AccountInstitutionPreset.categories.contains(where: { $0.id == preset.id }) ? "" : preset.title
        name = preset.accountName
        type = preset.type
        isBorrowing = preset.id == "borrowing"
        cardLabel = isBorrowing ? "借入" : preset.type.title
        cardIcon = preset.brandIcon.flatMap { asset in AccountCardIcon.brandIcons.first { $0.assetName == asset } } ?? preset.icon
        cardColor = preset.color
        cardIconPNGBase64 = nil
        choosingInstitution = false
    }

    private func selectType(_ newType: AccountType) {
        let oldType = type
        type = newType
        if isBorrowing && cardLabel == "借入" { cardLabel = newType.title }
        isBorrowing = false
        if cardLabel.trimmingCharacters(in: .whitespacesAndNewlines) == oldType.title { cardLabel = newType.title }
        if cardColor == AccountCardColor.defaultColor(for: oldType) { cardColor = AccountCardColor.defaultColor(for: newType) }
    }

    private func save() async {
        guard !isSaving else { return }
        guard !trimmedName.isEmpty else { error = isBorrowing ? "请填写出借人姓名。" : "请填写账户名称。"; return }
        guard trimmedName.count <= 40 else { error = "账户名称请控制在 40 个字以内。"; return }
        let trimmedProvider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedProvider.count <= 40 else { error = "机构名称请控制在 40 个字以内。"; return }
        let trimmedCardLabel = cardLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCardLabel.count <= 24 else { error = "卡片标签请控制在 24 个字以内。"; return }
        let balanceChanged = balanceText != initialBalanceText
        guard let balance = !balanceChanged && account != nil ? account?.openingBalanceCents : CounterMoney.cents(from: balanceText.isEmpty ? "0" : balanceText, allowZero: true) else {
            error = "余额或欠款请输入不超过两位小数的金额。"; return
        }
        let limit = limitText.isEmpty ? nil : CounterMoney.cents(from: limitText, allowZero: true)
        guard limitText.isEmpty || limit != nil else { error = "信用额度格式不正确。"; return }
        let due = dueAmountText.isEmpty ? nil : CounterMoney.cents(from: dueAmountText, allowZero: true)
        guard dueAmountText.isEmpty || due != nil else { error = "本期应还金额格式不正确。"; return }
        if isBorrowing && (balance <= 0 || borrowingRecipientID.isEmpty) {
            error = "请填写大于零的借入金额并选择收款账户。"; return
        }
        isSaving = true
        defer { isSaving = false }
        let now = Date()
        let value = BookAccount(id: account?.id ?? newAccountID,
                                name: trimmedName, type: isBorrowing ? .otherDebt : type, openingBalanceCents: isBorrowing ? 0 : balance,
                                cardLabelOverride: trimmedCardLabel == type.title || trimmedCardLabel.isEmpty ? nil : trimmedCardLabel,
                                cardIcon: account?.cardIcon, cardIconOverride: cardIcon, cardColor: cardColor,
                                cardIconPNGBase64: cardIconPNGBase64,
                                providerName: trimmedProvider.isEmpty ? nil : trimmedProvider,
                                creditLimitCents: type == .creditCard ? limit : account?.creditLimitCents,
                                dueAmountCents: isLiability && !isBorrowing ? due : nil,
                                nextDueDate: account?.nextDueDate,
                                repaymentDay: isLiability && !isBorrowing && (hasDueDate || account?.effectiveRepaymentDay != nil) ? repaymentDay : nil,
                                repaymentReminderEnabled: isLiability && !isBorrowing && hasDueDate,
                                isActive: isActive, sortOrder: account?.sortOrder ?? model.accounts.count,
                                createdAt: account?.createdAt ?? now, updatedAt: now)
        do {
            if isBorrowing {
                let saved = try await model.saveBorrowingAccount(value, cents: balance, toAccountID: borrowingRecipientID)
                onSave?(saved)
            } else {
                try await model.saveAccount(value, reconcileBalance: balanceChanged)
                onSave?(value)
            }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }

    private static func amountText(_ cents: Int64) -> String {
        CounterFormat.amount(cents).replacingOccurrences(of: "¥", with: "")
    }

}

struct AccountPickerSheet: View {
    @Bindable var model: AppModel
    @Binding var selectedAccountID: String?
    let kind: EntryKind
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingAccount = false

    private var choices: [BookAccount] {
        let allowed = model.activeAccounts.filter { kind != .income || !$0.type.isLiability }
        let selectedArchived = model.accounts.filter { !$0.isActive && $0.id == selectedAccountID }
        return allowed + selectedArchived.filter { old in !allowed.contains(where: { $0.id == old.id }) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 9) {
                    pickerRow(title: "暂不关联账户", subtitle: "保留为普通记账", symbol: "minus.circle", isSelected: selectedAccountID == nil) {
                        selectedAccountID = nil
                        dismiss()
                    }
                    ForEach(choices) { account in
                        let debt = account.type.isLiability
                        let balance = model.accountBalances[account.id] ?? LedgerMath.add(account.openingBalanceCents, account.balanceAdjustmentCents ?? 0)
                        pickerRow(title: account.displayName, subtitle: "\(debt ? "欠款" : "余额") \(CounterFormat.amount(balance))",
                                  symbol: account.displayCardIcon.symbol, account: account, isSelected: selectedAccountID == account.id) {
                            selectedAccountID = account.id
                            dismiss()
                        }
                    }
                    Button { isAddingAccount = true } label: {
                        Label("添加账户", systemImage: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(AccountPalette.ink)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(AccountPalette.yellow, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }.buttonStyle(.plain).padding(.top, 3)
                }
                .padding(18)
            }
            .background(AccountPalette.canvas)
            .navigationTitle("选择账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $isAddingAccount) {
                AccountEditorView(model: model, account: nil)
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await model.refreshAccountOverview() }
    }

    private func pickerRow(title: String, subtitle: String, symbol: String, account: BookAccount? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Group {
                    if let account { AccountBrandMark(account: account, side: 28) }
                    else { Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(AccountPalette.ink) }
                }
                .frame(width: 39, height: 39).background(AccountPalette.canvas, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AccountPalette.ink)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(AccountPalette.secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AccountPalette.purple) }
            }
            .padding(12).background(AccountPalette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private enum TransferAccountChoice: String, Identifiable, Hashable {
    case source, destination
    var id: String { rawValue }
}

struct AccountTransferSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var fromAccountID: String
    @State private var toAccountID: String
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var error: String?
    @State private var isSaving = false
    @State private var pickerPath: [TransferAccountChoice] = []

    private var sources: [BookAccount] { model.activeAccounts.filter { !$0.type.isLiability } }
    private var destinations: [BookAccount] { model.activeAccounts.filter { $0.id != fromAccountID } }

    init(model: AppModel) {
        self.model = model
        let sources = model.activeAccounts.filter { !$0.type.isLiability }
        let firstSource = sources.first?.id ?? ""
        _fromAccountID = State(initialValue: firstSource)
        _toAccountID = State(initialValue: model.activeAccounts.first(where: { $0.id != firstSource })?.id ?? "")
    }

    var body: some View {
        NavigationStack(path: $pickerPath) {
            Form {
                Section("转账信息") {
                    accountPickerRow(title: "转出账户", account: model.account(for: fromAccountID), target: .source)
                    accountPickerRow(title: "转入账户", account: model.account(for: toAccountID), target: .destination)
                    HStack {
                        Text("金额")
                        Spacer()
                        Text("¥").foregroundStyle(AccountPalette.secondary)
                        TextField("0.00", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 140).accessibilityIdentifier("transfer.amount")
                    }
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("备注（选填）", text: $note)
                }
                Section {
                    Text("还款本金只减少欠款，不计入消费；利息和手续费请单独记为支出。")
                        .font(.system(size: 11)).foregroundStyle(AccountPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollContentBackground(.hidden).background(AccountPalette.canvas)
            .navigationTitle("转账 / 还款").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.fontWeight(.semibold).disabled(isSaving || destinations.isEmpty || sources.isEmpty).accessibilityIdentifier("transfer.save") }
            }
            .onChange(of: fromAccountID) { _, value in
                if value == toAccountID { toAccountID = model.activeAccounts.first(where: { $0.id != value })?.id ?? "" }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .navigationDestination(for: TransferAccountChoice.self) { target in
                AccountTransferAccountPickerSheet(
                    title: target == .source ? "选择转出账户" : "选择转入账户",
                    accounts: target == .source ? sources : destinations,
                    selectedAccountID: Binding(
                        get: { target == .source ? fromAccountID : toAccountID },
                        set: { value in
                            if target == .source { fromAccountID = value }
                            else { toAccountID = value }
                        }
                    ),
                    model: model,
                    onSelect: { if !pickerPath.isEmpty { pickerPath.removeLast() } }
                )
            }
        }
    }

    private func accountPickerRow(title: String, account: BookAccount?, target: TransferAccountChoice) -> some View {
        NavigationLink(value: target) {
            HStack(spacing: 9) {
                Text(title).foregroundStyle(AccountPalette.ink)
                Spacer()
                if let account {
                    AccountBrandMark(account: account, side: 20)
                    Text(account.displayName).foregroundStyle(AccountPalette.ink).lineLimit(1)
                } else {
                    Text("选择账户").foregroundStyle(AccountPalette.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AccountPalette.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        guard let cents = CounterMoney.cents(from: amountText), cents > 0 else { error = "请输入有效金额。"; return }
        guard !fromAccountID.isEmpty, !toAccountID.isEmpty, fromAccountID != toAccountID else { error = "请选择不同的转出和转入账户。"; return }
        isSaving = true
        defer { isSaving = false }
        let now = Date()
        let transfer = AccountTransfer(id: "transfer-\(UUID().uuidString.lowercased())", cents: cents,
                                       fromAccountID: fromAccountID, toAccountID: toAccountID,
                                       occurredAt: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                       createdAt: now, updatedAt: now)
        do { try await model.saveTransfer(transfer); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct AccountTransferAccountPickerSheet: View {
    let title: String
    let accounts: [BookAccount]
    @Binding var selectedAccountID: String
    let model: AppModel
    let onSelect: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 9) {
                ForEach(accounts) { account in
                    Button {
                        selectedAccountID = account.id
                        onSelect()
                    } label: {
                        HStack(spacing: 11) {
                            AccountBrandMark(account: account, side: 25)
                                .frame(width: 42, height: 42)
                                .background(AccountPalette.canvas, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(account.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(AccountPalette.ink)
                                    let balance = model.accountBalances[account.id] ?? LedgerMath.add(account.openingBalanceCents, account.balanceAdjustmentCents ?? 0)
                                    let typePrefix = account.displayName == account.displayTypeLabel ? "" : "\(account.displayTypeLabel) · "
                                    Text("\(typePrefix)\(account.type.isLiability ? "欠款" : "余额") \(CounterFormat.amount(balance))")
                                    .font(.system(size: 11)).foregroundStyle(AccountPalette.secondary)
                            }
                            Spacer()
                            if selectedAccountID == account.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(AccountPalette.purple)
                            }
                        }
                        .padding(12).background(AccountPalette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(AccountPalette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", action: onSelect)
            }
        }
    }
}


private struct AccountIconPicker: View {
    @Binding var icon: AccountCardIcon
    @Binding var pngBase64: String?
    @Environment(\.dismiss) private var dismiss
    @State private var iconPhotoItem: PhotosPickerItem?
    @State private var isLoadingCardIcon = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    iconGroup("通用图标", icons: AccountCardIcon.genericIcons)
                    iconGroup("支付与银行", icons: AccountCardIcon.brandIcons)
                    PhotosPicker(selection: $iconPhotoItem, matching: .images) {
                        Label(isLoadingCardIcon ? "正在处理图片…" : "从相册选择图片", systemImage: "photo.badge.plus")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 50)
                            .background(AccountPalette.paper, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .disabled(isLoadingCardIcon).accessibilityIdentifier("account.iconPhoto")
                    Text("图标独立于账户类别，可自由选择品牌、通用图标或自己的图片。")
                        .font(.footnote).foregroundStyle(AccountPalette.secondary)
                }
                .padding(18)
            }
            .background(AccountPalette.canvas)
            .accessibilityIdentifier("account.iconScroll")
            .navigationTitle("选择账户图标").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(isLoadingCardIcon) } }
            .onChange(of: iconPhotoItem) { _, item in Task { await loadCardIcon(from: item) } }
            .alert("无法读取图片", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func iconGroup(_ title: String, icons: [AccountCardIcon]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(AccountPalette.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 10) {
                ForEach(icons) { option in
                    Button {
                        icon = option
                        pngBase64 = nil
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            AccountIconArtwork(assetName: option.assetName, icon: option, side: 34)
                                .frame(width: 46, height: 46)
                            Text(option.title).font(.caption).fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
                        }
                        .foregroundStyle(AccountPalette.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(AccountPalette.paper, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(icon == option && pngBase64 == nil ? AccountPalette.purple : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("account.cardIcon.\(option.id)")
                    .accessibilityAddTraits(icon == option && pngBase64 == nil ? .isSelected : [])
                }
            }
        }
    }
    private func loadCardIcon(from item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingCardIcon = true
        defer { isLoadingCardIcon = false }
        do {
            guard let source = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: source),
                  let pngData = Self.pngIconData(from: image),
                  pngData.count <= AccountCardArtwork.maximumBytes else {
                error = "这张图片无法用作图标，请选择简单、清晰的小图标。"
                return
            }
            pngBase64 = pngData.base64EncodedString()
            dismiss()
        } catch { self.error = "读取图标失败，请重新选择。" }
    }

    private static func pngIconData(from image: UIImage) -> Data? {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }
        for maximumSide: CGFloat in [160, 128, 96, 64] {
            let scale = min(maximumSide / max(originalSize.width, originalSize.height), 1)
            let size = CGSize(width: max(1, (originalSize.width * scale).rounded()),
                              height: max(1, (originalSize.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            guard let data = renderer.image(actions: { _ in image.draw(in: CGRect(origin: .zero, size: size)) }).pngData() else { continue }
            if data.count <= AccountCardArtwork.maximumBytes { return data }
        }
        return nil
    }
}

private struct WalletStackCard: View {
    let name: String
    let brandIcon: String?
    let provider: String
    let category: String
    let icon: AccountCardIcon
    let iconPNG: Data?
    let color: AccountCardColor
    let amount: String
    let secondaryInfo: String?
    var height: CGFloat = 176

    private var subtitle: String {
        let source = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty || source == name || source == category || source == "我的账户"
            ? category : "\(category) · \(source)"
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AccountIconArtwork(assetName: brandIcon, icon: icon, pngData: iconPNG, side: 27)
                    .foregroundStyle(AccountPalette.ink)
                    .padding(5)
                    .background(AccountPalette.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(AccountPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(amount).font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            .frame(height: 40)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 5) {
                Text(secondaryInfo?.isEmpty == false ? "账户信息" : "账户类型").font(.caption).foregroundStyle(AccountPalette.secondary)
                if let secondaryInfo, !secondaryInfo.isEmpty {
                    Text(secondaryInfo).font(.subheadline).lineLimit(2)
                } else {
                    Text(category).font(.subheadline.weight(.medium))
                }
            }
        }
        .foregroundStyle(AccountPalette.ink)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AccountPalette.paper)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(color.swiftUIColor.opacity(colorScheme == .dark ? 0.28 : 0.18))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(color.swiftUIColor.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 5, x: 0, y: -1)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

}

private extension AccountCardColor {
    var swiftUIColor: Color {
        let value = UInt32(hex, radix: 16) ?? 0x26334E
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255,
                     opacity: 1)
    }
}
