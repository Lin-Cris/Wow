import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChoosingMonth = false
    @State private var showingSearch = false
    @State private var searchText = ""
    @State private var kindFilter: EntryKind?
    @State private var itemToDelete: BookEntry?
    @State private var confirmsDelete = false
    @State private var companionMenuPhase: CompanionMenuPhase = .collapsed
    @State private var companionMenuVisibleCount = 0
    @State private var companionMenuRevealTask: Task<Void, Never>?
    @State private var isCompanionPressed = false
    @State private var companionPulseTask: Task<Void, Never>?
    @State private var pendingCompanionRoute: CounterRoute?

    private struct DayGroup: Identifiable {
        var day: Date
        var entries: [BookEntry]
        var id: Date { day }
    }

    private struct CompanionModule: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let destination: CounterRoute

        static let defaults = [
            CompanionModule(id: "accounts", title: "账户", symbol: "creditcard", destination: .accounts),
            CompanionModule(id: "categories", title: "分类", symbol: "square.grid.2x2", destination: .categorySettings),
            CompanionModule(id: "settings", title: "设置", symbol: "gearshape", destination: .settings)
        ]
    }

    private struct CompanionModulePill: View {
        let title: String
        let symbol: String
        let identifier: String
        let hint: String
        let isAtRest: Bool
        let isVisible: Bool
        let offset: CGSize
        let scale: CGFloat
        let rotation: Double
        let isDragging: Bool
        let zIndex: Double
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CounterPalette.ink)
                    .frame(width: 80, height: 34)
                    .background(.white, in: Capsule())
                    .overlay(Capsule().stroke(CounterPalette.ink.opacity(0.035), lineWidth: 1))
                    .shadow(color: .black.opacity(0.045), radius: 4, x: 0, y: 1)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityHint(hint)
            .accessibilityHidden(!isAtRest)
            .allowsHitTesting(isAtRest)
            .disabled(!isAtRest)
            .opacity(isVisible ? 1 : 0)
            .offset(offset)
            .scaleEffect(scale, anchor: .center)
            .rotationEffect(.degrees(rotation), anchor: .center)
            .shadow(color: .black.opacity(isDragging ? 0.13 : 0), radius: isDragging ? 10 : 0, x: 0, y: 5)
            .zIndex(zIndex)
        }
    }

    private var categoriesByID: [String: BookCategory] {
        Dictionary(model.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var dayGroups: [DayGroup] {
        Dictionary(grouping: filteredEntries, by: { $0.localDay })
            .map { DayGroup(day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private var filteredEntries: [BookEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let categories = categoriesByID
        return model.entries.filter { entry in
            guard kindFilter == nil || entry.kind == kindFilter else { return false }
            guard !query.isEmpty else { return true }
            let category = categories[entry.categoryID] ?? entry.historicalCategory
            let amount = CounterFormat.amount(entry.cents).replacingOccurrences(of: "¥", with: "")
            let searchable = [entry.note, category?.name ?? "", entry.kind.label, entry.categoryID,
                              amount, entry.stableLocalDayKey, CounterFormat.dayTitle(entry.localDay)]
            return searchable.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var isFiltering: Bool { !searchText.isEmpty || kindFilter != nil }
    private var filteredNetExpense: Int64 { LedgerMath.summary(filteredEntries).netExpenses }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = model.loadError { loadErrorCard(error) }
                summaryPanel
                if let account = model.dueSoonAccount { accountReminder(account) }
                if let first = model.drafts.first { pendingCard(first) }
                history
                Color.clear.frame(height: 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .background(CounterPalette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button { model.openEditor(.create(.expense)) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(CounterPalette.ink)
                        .frame(width: 64, height: 64)
                        .background(CounterPalette.yellow, in: Circle())
                        .shadow(color: CounterPalette.yellow.opacity(0.24), radius: 14, x: 0, y: 7)
                }
                .accessibilityLabel("记一笔")
                .accessibilityIdentifier("home.add")
                Spacer()
            }
            .padding(.top, 9)
            .padding(.bottom, 5)
            .background(LinearGradient(colors: [CounterPalette.canvas.opacity(0), CounterPalette.canvas], startPoint: .top, endPoint: .bottom))
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $isChoosingMonth) {
            MonthSelectionSheet(selectedMonth: model.selectedMonth) { month in
                Task { await model.selectMonth(month) }
                isChoosingMonth = false
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("删除这笔记录吗？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) {
                if let itemToDelete { Task { await model.removeEntry(itemToDelete) } }
            }
            Button("取消", role: .cancel) { itemToDelete = nil }
        } message: {
        Text(itemToDelete.flatMap { item in model.entries.contains(where: { $0.originalEntryID == item.id }) ? "这笔支出有关联退款。请先编辑或删除关联退款，才能删除原支出。" : nil } ?? "删除后可在提示消失前撤销。")
        }
        .task(id: CounterFormat.monthKey(model.selectedMonth)) { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button { isChoosingMonth = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(Calendar.current.component(.year, from: model.selectedMonth)))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(CounterPalette.secondary)
                    HStack(spacing: 7) {
                        Text(Calendar.current.component(.month, from: model.selectedMonth), format: .number.precision(.integerLength(2)))
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Text("月")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(CounterPalette.ink)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择月份，\(CounterFormat.monthTitle(model.selectedMonth))")

            Spacer(minLength: 8)
            companionControl
        }
        .padding(.horizontal, 4)
        .zIndex(companionMenuPhase == .collapsed ? 0 : 1)
    }

    private var companionControl: some View {
        return ZStack {
            CompanionOrb(size: 49)
                .frame(width: 56, height: 56)
                .scaleEffect(isCompanionPressed ? 0.96 : 1)
                .allowsHitTesting(false)

            Button {
                toggleCompanionMenu()
            } label: {
                Circle()
                    .fill(.clear)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                companionMenuPhase == .collapsed || companionMenuPhase == .collapsing
                    ? "展开小紫菜单" : "收起小紫菜单"
            )
            .accessibilityHint("显示账户、分类和设置")
            .accessibilityIdentifier("home.companionMenu")
        }
        .frame(width: 56, height: 56)
        .overlay(alignment: .topTrailing) {
            if companionMenuPhase != .collapsed {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(Array(CompanionModule.defaults.enumerated()), id: \.element.id) { index, module in
                        companionMenuButton(module, index: index)
                    }
                }
                .fixedSize()
                .offset(x: -64, y: 11)
                .zIndex(10)
            }
        }
        .zIndex(companionMenuPhase == .collapsed ? 0 : 1)
    }

    private var companionCardAnimation: Animation {
        reduceMotion
            ? .spring(response: 0.30, dampingFraction: 0.96, blendDuration: 0.04)
            : .spring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.04)
    }

    private func toggleCompanionMenu() {
        pulseCompanion()
        switch companionMenuPhase {
        case .collapsed, .collapsing:
            openCompanionMenu()
        case .expanding, .expanded:
            closeCompanionMenu()
        }
    }

    private func pulseCompanion() {
        companionPulseTask?.cancel()
        withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
            isCompanionPressed = true
        }
        companionPulseTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 105_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.80)) {
                isCompanionPressed = false
            }
        }
    }

    private func openCompanionMenu() {
        companionMenuRevealTask?.cancel()
        companionMenuRevealTask = nil
        pendingCompanionRoute = nil
        companionMenuPhase = .expanding

        companionMenuRevealTask = Task { @MainActor in
            while companionMenuVisibleCount < CompanionModule.defaults.count {
                guard !Task.isCancelled else { return }
                withAnimation(companionCardAnimation) {
                    companionMenuVisibleCount += 1
                }
                if companionMenuVisibleCount < CompanionModule.defaults.count {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000)
                    } catch {
                        return
                    }
                }
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            companionMenuPhase = .expanded
            companionMenuRevealTask = nil
        }
    }

    private func closeCompanionMenu() {
        companionMenuRevealTask?.cancel()
        companionMenuRevealTask = nil
        companionMenuPhase = .collapsing

        companionMenuRevealTask = Task { @MainActor in
            while companionMenuVisibleCount > 0 {
                guard !Task.isCancelled else { return }
                withAnimation(companionCardAnimation) {
                    companionMenuVisibleCount -= 1
                }
                if companionMenuVisibleCount > 0 {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000)
                    } catch {
                        return
                    }
                }
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if pendingCompanionRoute != nil {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
            companionMenuPhase = .collapsed
            companionMenuRevealTask = nil
            navigateAfterCompanionCollapse()
        }
    }

    private func navigateAfterCompanionCollapse() {
        guard let route = pendingCompanionRoute else { return }
        pendingCompanionRoute = nil
        companionPulseTask?.cancel()
        isCompanionPressed = false
        model.path.append(route)
    }

    private func companionMenuButton(_ module: CompanionModule, index: Int) -> some View {
        let isVisible = companionMenuVisibleCount > index
        let isAtRest = companionMenuPhase == .expanded
        let startX: CGFloat = 76
        let startY: CGFloat = -CGFloat(index) * 40
        let offset = isVisible ? CGSize.zero : CGSize(width: startX, height: startY)
        let scale: CGFloat = isVisible ? 1 : 0.80
        let rotation = isVisible ? 0 : Double(index.isMultiple(of: 2) ? -1 : 1) * (2.6 + Double(index) * 0.8)
        let pill = CompanionModulePill(
            title: module.title,
            symbol: module.symbol,
            identifier: "home.companion.\(module.title)",
            hint: module.id == "accounts" ? "点按进入账户" : "",
            isAtRest: isAtRest,
            isVisible: isVisible,
            offset: offset,
            scale: scale,
            rotation: rotation,
            isDragging: false,
            zIndex: Double(CompanionModule.defaults.count - index)
        ) {
            pendingCompanionRoute = module.destination
            closeCompanionMenu()
        }
        return pill
    }

    private func accountReminder(_ account: BookAccount) -> some View {
        Button { model.path.append(.accounts) } label: {
            HStack(spacing: 11) {
                AccountBrandMark(account: account, side: 22)
                    .frame(width: 34, height: 34)
                    .background(CounterPalette.purple.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(account.displayName)还款提醒")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(CounterPalette.ink)
                    Text("\(account.upcomingRepaymentDate?.formatted(.dateTime.month().day()) ?? "近期") · 本期应还 \(CounterFormat.amount(account.dueAmountCents ?? 0))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(CounterPalette.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.white, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.accountReminder")
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("本月支出")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CounterPalette.secondary)
            Button { model.monthBill() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(CounterFormat.money.string(from: NSNumber(value: Double(model.summary.netExpenses) / 100)) ?? "0.00")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .tracking(-0.9)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text("元")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(CounterPalette.ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.monthlyExpense")

            HStack(spacing: 0) {
                Label {
                    Text("收入  \(CounterFormat.money.string(from: NSNumber(value: Double(model.summary.income) / 100)) ?? "0.00")")
                } icon: { Image(systemName: "arrow.down.left") }
                .foregroundStyle(CounterPalette.secondary)
                Rectangle().fill(CounterPalette.divider).frame(width: 1, height: 15).padding(.horizontal, 12)
                Label {
                    Text("结余  \(CounterFormat.money.string(from: NSNumber(value: Double(model.summary.netCents) / 100)) ?? "0.00")")
                } icon: { Image(systemName: "equal") }
                .foregroundStyle(model.summary.netCents < 0 ? Color(red: 0.75, green: 0.29, blue: 0.25) : CounterPalette.ink)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(.white.opacity(0.9), in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 3).padding(.top, 9).padding(.bottom, 4)
    }

    private func loadErrorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.72, green: 0.25, blue: 0.20))
            VStack(alignment: .leading, spacing: 5) {
                Text("账本暂时无法读取")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CounterPalette.ink)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(CounterPalette.secondary)
                    .textSelection(.enabled)
                Button("重试读取") { Task { await model.refresh() } }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.red.opacity(0.12), lineWidth: 1))
        .accessibilityIdentifier("home.loadError")
    }

    private func pendingCard(_ draft: ReviewDraft) -> some View {
        Button {
            if model.drafts.count == 1 { model.path.append(.draft(draft.id)) }
            else { model.path.append(.drafts) }
        } label: {
            HStack(spacing: 13) {
                CounterCategoryArtwork(assetName: draft.categoryID.flatMap { id in model.categories.first(where: { $0.id == id })?.symbol } ?? "custom_category", side: 42, iconPNGBase64: draft.categoryID.flatMap { id in model.categories.first { $0.id == id }?.iconPNGBase64 })
                    .frame(width: 42, height: 42)
                    .background(CounterPalette.yellow.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.drafts.count > 1 ? "有 \(model.drafts.count) 笔待记账" : "有一笔待记账")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CounterPalette.ink)
                    HStack(spacing: 6) {
                        Text(draft.cents.map { CounterFormat.amount($0) } ?? "等你核对")
                        Text("·")
                        Text(draft.categoryID.flatMap { id in model.categories.first(where: { $0.id == id })?.name } ?? "建议分类待确认")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CounterPalette.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(CounterPalette.secondary)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .background(.white.opacity(0.84), in: Capsule())
            .counterShadow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.pendingReview")
    }

    private var history: some View { history(categoriesByID: categoriesByID) }

    @ViewBuilder
    private func history(categoriesByID: [String: BookCategory]) -> some View {
        CounterCard(inset: 16) {
            if model.entries.isEmpty {
                if let error = model.loadError {
                    CounterEmptyState(title: "记录尚未加载", detail: "账本读取失败：\(error)", symbol: "exclamationmark.triangle")
                } else {
                    CounterEmptyState(title: "这月还没有记录", detail: "记下第一笔收支，月度账单就会在这里更新。", symbol: "leaf")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                        Text("明细").font(.system(size: 18, weight: .bold))
                        Spacer()
                        Text("\(filteredEntries.count) 笔")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CounterPalette.secondary)
                        Button {
                            showingSearch.toggle()
                            if !showingSearch { searchText = "" }
                        } label: {
                            Image(systemName: showingSearch ? "xmark.magnifyingglass" : "magnifyingglass")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(CounterPalette.ink)
                                .frame(width: 34, height: 34).background(CounterPalette.canvas, in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(showingSearch ? "关闭搜索" : "搜索明细")
                        Menu {
                            Button("全部类型") { kindFilter = nil }
                            ForEach(EntryKind.allCases) { kind in
                                Button(kind.label) { kindFilter = kind }
                            }
                        } label: {
                            Image(systemName: kindFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 17)).foregroundStyle(CounterPalette.ink)
                                .frame(width: 34, height: 34).background(CounterPalette.canvas, in: Circle())
                        }
                        .accessibilityLabel("按收支类型筛选")
                    }
                    if showingSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(CounterPalette.secondary)
                            TextField("搜索备注、分类、日期或金额", text: $searchText)
                                .font(.system(size: 13)).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().accessibilityIdentifier("home.transactionSearch")
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CounterPalette.secondary) }
                                    .accessibilityLabel("清除搜索")
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 39)
                        .background(CounterPalette.canvas, in: Capsule())
                    }
                    if isFiltering {
                        HStack {
                            Text("筛选净支出  \(CounterFormat.amount(filteredNetExpense))")
                            Spacer()
                            Text("全月汇总保持不变").foregroundStyle(CounterPalette.secondary)
                        }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.ink)
                        .padding(.horizontal, 4)
                    }
                    if filteredEntries.isEmpty {
                        CounterEmptyState(title: isFiltering ? "没有符合条件的记录" : "这月还没有记录",
                                          detail: isFiltering ? "试试其他关键词，或切换收支类型。" : "记下第一笔收支，月度账单就会在这里更新。",
                                          symbol: isFiltering ? "magnifyingglass" : "leaf")
                    } else {
                      ForEach(dayGroups) { group in
                        dayHeader(group.day, entries: group.entries)
                            .padding(.top, 7)
                        ForEach(group.entries) { entry in
                            TransactionRow(entry: entry, category: categoriesByID[entry.categoryID], account: model.account(for: entry.accountID))
                                .contentShape(Rectangle())
                                .onTapGesture { model.openEditor(.edit(entry)) }
                                .contextMenu {
                                    Button("编辑", systemImage: "pencil") { model.openEditor(.edit(entry)) }
                                    if entry.kind == .expense {
                                        Button("记一笔关联退款", systemImage: "arrow.uturn.backward") {
                                            Task { await model.openRefundEditor(for: entry) }
                                        }
                                    }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        itemToDelete = entry
                                        confirmsDelete = true
                                    }
                                }
                            if entry.id != group.entries.last?.id {
                                Rectangle().fill(CounterPalette.divider.opacity(0.7)).frame(height: 1).padding(.leading, 48)
                            }
                        }
                    }
                    }
                }
            }
        }
        .counterShadow()
    }

    private func dayHeader(_ day: Date, entries: [BookEntry]) -> some View {
        let display = LedgerMath.summary(entries).netExpenses
        return HStack(spacing: 10) {
            Text(CounterFormat.dayTitle(day))
            Rectangle().fill(CounterPalette.divider).frame(height: 1)
            Text("支出 \(CounterFormat.amount(display).replacingOccurrences(of: "¥", with: ""))")
                .foregroundStyle(CounterPalette.ink)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(CounterPalette.secondary)
        .padding(.vertical, 5)
    }
}

struct TransactionRow: View {
    var entry: BookEntry
    var category: BookCategory?
    var account: BookAccount? = nil
    private var resolvedCategory: BookCategory? { category ?? entry.historicalCategory }

    var body: some View {
        HStack(spacing: 13) {
            CounterCategoryArtwork(assetName: entry.iconChoice.isEmpty ? (resolvedCategory?.symbol ?? "custom_category") : entry.iconChoice, side: 42, iconPNGBase64: resolvedCategory?.iconPNGBase64)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(resolvedCategory?.name ?? "已停用分类").font(.system(size: 15, weight: .medium)).foregroundStyle(CounterPalette.ink)
                HStack(spacing: 4) {
                    Text(entry.note.isEmpty ? CounterFormat.time(entry.occurredAt) : entry.note)
                    if let account {
                        Text("·").foregroundStyle(CounterPalette.secondary.opacity(0.65))
                        AccountBrandMark(account: account, side: 11)
                        Text(account.displayName)
                    }
                }
                .font(.system(size: entry.note.isEmpty ? 11 : 12))
                .foregroundStyle(CounterPalette.secondary.opacity(entry.note.isEmpty ? 0.75 : 1))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text((entry.kind == .income ? "+" : entry.kind == .refund ? "↩ " : "−") + CounterFormat.amount(entry.cents).replacingOccurrences(of: "¥", with: ""))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.kind == .income || entry.kind == .refund ? Color(red: 0.20, green: 0.52, blue: 0.35) : CounterPalette.ink)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct MonthSelectionSheet: View {
    let selectedMonth: Date
    let onSelect: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    init(selectedMonth: Date, onSelect: @escaping (Date) -> Void) {
        self.selectedMonth = selectedMonth
        self.onSelect = onSelect
        _year = State(initialValue: Calendar.current.component(.year, from: selectedMonth))
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34).background(CounterPalette.canvas, in: Circle()) }
                    .accessibilityLabel("关闭月份选择")
                Spacer()
                Button("回到本月") { onSelect(Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()) }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CounterPalette.ink)
            }
            HStack(spacing: 24) {
                Button { year -= 1 } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36).background(CounterPalette.canvas, in: Circle()) }
                    .accessibilityLabel("上一年")
                Text("\(year)年").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                Button { year += 1 } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36).background(CounterPalette.canvas, in: Circle()) }
                    .accessibilityLabel("下一年")
            }
            LazyVGrid(columns: columns, spacing: 11) {
                ForEach(1...12, id: \.self) { month in
                    let isSelected = Calendar.current.component(.year, from: selectedMonth) == year && Calendar.current.component(.month, from: selectedMonth) == month
                    Button {
                        var components = DateComponents(year: year, month: month, day: 1)
                        components.calendar = Calendar.current
                        onSelect(Calendar.current.date(from: components) ?? Date())
                    } label: {
                        Text("\(month)月")
                            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(CounterPalette.ink)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(isSelected ? CounterPalette.yellow : CounterPalette.canvas, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(year)年\(month)月")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .padding(.top, 6)
        .background(CounterPalette.canvas.ignoresSafeArea())
    }
}

public struct CompanionOrb: View {
    let size: CGFloat
    @State private var player: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(CounterPalette.canvas)

            if let player {
                CompanionVideoSurface(player: player)
                    .scaleEffect(1.72)
            } else {
                Image("avatar")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .compositingGroup()
        .accessibilityHidden(true)
        .task {
            if let player {
                player.play()
                return
            }
            guard player == nil,
                  let url = Bundle.main.url(forResource: "CompanionLoopSilent", withExtension: "mp4") else { return }
            let source = AVURLAsset(url: url)
            // Only a video track can reach the player, even if this resource is
            // accidentally replaced with a movie containing an audio track.
            let asset = AVMutableComposition()
            do {
                guard let video = try await source.loadTracks(withMediaType: .video).first,
                      let track = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
                let duration = try await source.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
                track.preferredTransform = try await video.load(.preferredTransform)
                guard !Task.isCancelled else { return }
            } catch { return }
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = AVVideoComposition(asset: asset) { request in
                guard let keyedFrame = CompanionVideoMatte.apply(to: request.sourceImage) else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                request.finish(with: keyedFrame.cropped(to: request.sourceImage.extent), context: nil)
            }
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.volume = 0
            queuePlayer.allowsExternalPlayback = false
            queuePlayer.audiovisualBackgroundPlaybackPolicy = .pauses
            queuePlayer.actionAtItemEnd = .advance
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            player = queuePlayer
            queuePlayer.play()
        }
        .onDisappear { player?.pause() }
    }
}

private enum CompanionMenuPhase {
    case collapsed
    case expanding
    case expanded
    case collapsing
}

private enum CompanionVideoMatte {
    private static let cubeDimension = 32
    private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let cubeData = makeCubeData()

    static func apply(to image: CIImage) -> CIImage? {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData
        filter.colorSpace = colorSpace
        filter.extrapolate = false
        return filter.outputImage
    }

    private static func makeCubeData() -> Data {
        let canvas = [0.944, 0.949, 0.957].map(linearSRGB)
        let lastIndex = Float(cubeDimension - 1)
        var texels: [Float] = []
        texels.reserveCapacity(cubeDimension * cubeDimension * cubeDimension * 4)

        for blueIndex in 0..<cubeDimension {
            let blue = Float(blueIndex) / lastIndex
            for greenIndex in 0..<cubeDimension {
                let green = Float(greenIndex) / lastIndex
                for redIndex in 0..<cubeDimension {
                    let red = Float(redIndex) / lastIndex
                    let distanceFromWhite = 1 - min(red, min(green, blue))
                    let t = min(max((distanceFromWhite - 0.045) / (0.19 - 0.045), 0), 1)
                    let foreground = t * t * (3 - 2 * t)
                    texels.append(canvas[0] + (red - canvas[0]) * foreground)
                    texels.append(canvas[1] + (green - canvas[1]) * foreground)
                    texels.append(canvas[2] + (blue - canvas[2]) * foreground)
                    texels.append(1)
                }
            }
        }

        return texels.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func linearSRGB(_ value: Double) -> Float {
        let linear = value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
        return Float(linear)
    }
}

private struct CompanionVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
