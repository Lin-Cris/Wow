import SwiftUI

struct MonthlyBillView: View {
    @Bindable var model: AppModel
    let month: Date
    @State private var showRanking = false

    private var monthSpending: [CategorySpend] { model.spending(in: month) }
    private var monthSummary: MonthSummary { model.summary(in: month) }
    private var positive: [CategorySpend] { monthSpending.filter { $0.cents > 0 } }
    private var top: [CategorySpend] { Array(positive.prefix(4)) }
    private var remaining: [CategorySpend] { Array(positive.dropFirst(4)) }
    private var otherTotal: Int64 { remaining.reduce(0) { $0 + $1.cents } }
    private var bubbleTotal: Int64 { top.reduce(0) { $0 + $1.cents } + otherTotal }
    private var requiresRanking: Bool { top.isEmpty && !monthSpending.isEmpty }
    private var rankingIsVisible: Bool { showRanking || requiresRanking }
    private var hasLoadedMonth: Bool { model.monthSnapshots[CounterFormat.monthKey(month)] != nil }
    private var isLoadingWithoutSnapshot: Bool { model.loadingMonths.contains(CounterFormat.monthKey(month)) && !hasLoadedMonth }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                topBar
                if isLoadingWithoutSnapshot {
                    CounterCard { ProgressView("正在读取账单…").tint(CounterPalette.purple).frame(maxWidth: .infinity).padding(30) }
                } else if let issue = model.loadError(in: month), !hasLoadedMonth {
                    CounterCard { CounterEmptyState(title: "账单暂时无法读取", detail: issue, symbol: "exclamationmark.triangle") }
                } else {
                    summary
                    if monthSpending.contains(where: { $0.cents < 0 }) {
                        Text("含退款；气泡显示正向净支出分类，排行包含退款净额。")
                            .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).padding(.horizontal, 3)
                    }
                    if rankingIsVisible {
                        ranking
                    } else if monthSpending.isEmpty {
                        CounterCard { CounterEmptyState(title: "还没有分类支出", detail: "记录第一笔支出后，这里会显示本月分类。", symbol: "circle.grid.2x2") }
                    } else {
                        bubbleCloud
                    }
                }
                Color.clear.frame(height: 18)
            }.padding(18).padding(.top, 4)
        }
        .background(CounterPalette.canvas.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .refreshable { await model.loadMonth(month) }
        .task { await model.loadMonth(month) }
    }

    private var topBar: some View {
        HStack {
            BackButton()
            Spacer()
            Text("\(Calendar.current.component(.month, from: month))月账单")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CounterPalette.ink)
            Spacer()
            if requiresRanking {
                Color.clear.frame(width: 40, height: 40)
            } else {
                Button { showRanking.toggle() } label: {
                    Image(systemName: showRanking ? "circle.grid.2x2" : "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CounterPalette.ink)
                        .frame(width: 40, height: 40)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showRanking ? "查看气泡图" : "查看账单排行")
            }
        }
        .padding(.bottom, 3)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本月支出")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CounterPalette.secondary)
            Text(CounterFormat.amount(monthSummary.netExpenses).replacingOccurrences(of: "¥", with: ""))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .tracking(-0.7)
                .foregroundStyle(CounterPalette.ink)
            HStack(spacing: 8) {
                summaryMetric("收入", monthSummary.income)
                Rectangle().fill(CounterPalette.divider).frame(width: 1, height: 14)
                summaryMetric("退款", monthSummary.refunds)
                Rectangle().fill(CounterPalette.divider).frame(width: 1, height: 14)
                summaryMetric("结余", monthSummary.netCents)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(.white, in: Capsule())
        }
        .padding(.horizontal, 3)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func summaryMetric(_ label: String, _ cents: Int64) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(CounterPalette.secondary)
            Text(CounterFormat.amount(cents).replacingOccurrences(of: "¥", with: "")).foregroundStyle(CounterPalette.ink)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    private var bubbleCloud: some View {
        GeometryReader { geo in
            let bubbles: [(String, String, Int64, String)] = top.map { item in
                (item.category.id, item.category.symbol, item.cents, item.category.name)
            } + (otherTotal > 0 ? [("__other__", "", otherTotal, "其他")] : [])
            let maximum = max(bubbles.map(\.2).max() ?? 1, 1)
            let maximumSide = geo.size.width * (bubbles.count >= 4 ? 0.50 : 0.66)
            let minimumSide = min(max(60, geo.size.width * 0.18), maximumSide)
            ZStack(alignment: .topLeading) {
                ForEach(Array(bubbles.enumerated()), id: \.element.0) { index, item in
                    let side = minimumSide + CGFloat(sqrt(Double(item.2) / Double(maximum))) * (maximumSide - minimumSide)
                    let proposed = bubbleCenter(index: index, count: bubbles.count, width: geo.size.width, height: geo.size.height)
                    let center = CGPoint(x: min(max(proposed.x, side / 2), geo.size.width - side / 2),
                                         y: min(max(proposed.y, side / 2), geo.size.height - side / 2))
                    Button { model.path.append(.category(month, item.0)) } label: {
                        VStack(spacing: side < 92 ? 1 : 4) {
                            Text(item.3)
                                .font(.system(size: side < 92 ? 10 : 12, weight: .medium))
                                .foregroundStyle(CounterPalette.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(shortAmount(item.2))
                                .font(.system(size: side < 92 ? 16 : min(29, side * 0.14), weight: .semibold, design: .rounded))
                                .foregroundStyle(CounterPalette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                            Text(String(format: "%.1f%%", Double(item.2) / Double(max(1, bubbleTotal)) * 100))
                                .font(.system(size: side < 92 ? 9 : 11, weight: .medium, design: .rounded))
                                .foregroundStyle(CounterPalette.secondary)
                        }
                        .frame(width: side, height: side)
                        .background {
                            Circle()
                                .fill(RadialGradient(stops: [
                                    .init(color: .white, location: 0.12),
                                    .init(color: .white, location: 0.55),
                                    .init(color: Color(red: 0.84, green: 0.86, blue: 0.89), location: 1)
                                ], center: UnitPoint(x: 0.35, y: 0.26), startRadius: 2, endRadius: side * 0.88))
                                .overlay(Circle().stroke(.white.opacity(0.98), lineWidth: 1.5))
                                .shadow(color: Color(red: 0.39, green: 0.43, blue: 0.49).opacity(0.13), radius: 15, x: 8, y: 13)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("\(item.3)，\(CounterFormat.amount(item.2))")
                        .position(center)
                }
            }
        }
        .frame(height: 495)
        .accessibilityIdentifier("bill.bubbles")
    }

    private func bubbleCenter(index: Int, count: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        if count == 1 { return CGPoint(x: width * 0.39, y: height * 0.53) }
        let points: [(CGFloat, CGFloat)] = [
            (0.38, 0.73), (0.30, 0.37), (0.74, 0.27),
            (0.60, 0.55), (0.86, 0.73), (0.52, 0.12)
        ]
        let point = points[min(index, points.count - 1)]
        return CGPoint(x: width * point.0, y: height * point.1)
    }

    private var ranking: some View {
        CounterCard(inset: 17) {
            VStack(spacing: 0) {
                ForEach(Array(monthSpending.enumerated()), id: \.element.id) { index, item in
                    Button { model.path.append(.category(month, item.category.id)) } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(CounterPalette.secondary).frame(width: 20)
                            CounterCategoryArtwork(assetName: item.category.symbol, side: 31, iconPNGBase64: item.category.iconPNGBase64).frame(width: 32, height: 38)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(item.category.name).font(.system(size: 14, weight: .medium)); Spacer(); Text(CounterFormat.amount(item.cents)).font(.system(size: 13, weight: .semibold, design: .rounded)) }
                                GeometryReader { proxy in ZStack(alignment: .leading) {
                                    Capsule().fill(CounterPalette.canvas)
                                    Capsule().fill(LinearGradient(colors: [CounterPalette.yellow, CounterPalette.yellow.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(3, proxy.size.width * CGFloat(max(0, item.cents)) / CGFloat(max(1, bubbleTotal))) )
                                }}.frame(height: 4)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CounterPalette.secondary.opacity(0.6))
                        }.foregroundStyle(item.cents < 0 ? Color(red: 0.65, green: 0.38, blue: 0.35) : CounterPalette.ink).padding(.vertical, 10)
                    }.buttonStyle(.plain)
                    if index != monthSpending.count - 1 { Rectangle().fill(CounterPalette.divider).frame(height: 1).padding(.leading, 64) }
                }
            }
        }.counterShadow()
    }

    private func shortAmount(_ cents: Int64) -> String {
        let yuan = Double(cents) / 100
        if yuan >= 100_000 { return String(format: "%.1f万", yuan / 10_000) }
        if yuan >= 10_000 { return String(format: "%.1f万", yuan / 10_000) }
        return CounterFormat.amount(cents).replacingOccurrences(of: "¥", with: "")
    }
}

struct CategoryDetailView: View {
    @Bindable var model: AppModel
    let month: Date
    let categoryID: String

    private var entries: [BookEntry] {
        let ids: Set<String>
        if categoryID == "__other__" { ids = Set(model.spending(in: month).filter { $0.cents > 0 }.dropFirst(4).map { $0.category.id }) }
        else { ids = [categoryID] }
        return model.entries(in: month).filter { ids.contains($0.categoryID) }.sorted { $0.occurredAt > $1.occurredAt }
    }
    private var title: String { categoryID == "__other__" ? "其他" : (model.categories(in: month).first { $0.id == categoryID }?.name ?? entries.first?.historicalCategory?.name ?? "分類明細") }
    private var hasLoadedMonth: Bool { model.monthSnapshots[CounterFormat.monthKey(month)] != nil }
    private var isLoadingWithoutSnapshot: Bool { model.loadingMonths.contains(CounterFormat.monthKey(month)) && !hasLoadedMonth }

    var body: some View {
        let entries = self.entries
        let total = LedgerMath.summary(entries).netExpenses
        let categoriesByID = Dictionary(model.categories(in: month).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView {
            VStack(spacing: 17) {
                HStack { BackButton(); Spacer(); Text(title).font(.system(size: 17, weight: .semibold)); Spacer(); Color.clear.frame(width: 40, height: 40) }
                if isLoadingWithoutSnapshot {
                    CounterCard { ProgressView("正在读取明细…").tint(CounterPalette.purple).frame(maxWidth: .infinity).padding(30) }
                } else if let issue = model.loadError(in: month), !hasLoadedMonth {
                    CounterCard { CounterEmptyState(title: "账单暂时无法读取", detail: issue, symbol: "exclamationmark.triangle") }
                } else {
                    CounterCard { VStack(alignment: .leading, spacing: 7) {
                        Text(CounterFormat.monthTitle(month)).font(.system(size: 12)).foregroundStyle(CounterPalette.secondary)
                        Text(CounterFormat.amount(total)).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("\(entries.count) 笔记录").font(.system(size: 12)).foregroundStyle(CounterPalette.secondary)
                    }}.counterShadow()
                    CounterCard(inset: 15) {
                        if entries.isEmpty { CounterEmptyState(title: "暂无记录", detail: "所选月份没有这个分类的账单。") }
                        else { VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                TransactionRow(entry: entry, category: categoriesByID[entry.categoryID], account: model.account(for: entry.accountID))
                                    .contentShape(Rectangle()).onTapGesture { model.openEditor(.edit(entry)) }
                                    .contextMenu {
                                        Button("编辑", systemImage: "pencil") { model.openEditor(.edit(entry)) }
                                        if entry.kind == .expense {
                                            Button("记一笔关联退款", systemImage: "arrow.uturn.backward") {
                                                Task { await model.openRefundEditor(for: entry) }
                                            }
                                        }
                                    }
                                if entry.id != entries.last?.id { Rectangle().fill(CounterPalette.divider).frame(height: 1).padding(.leading, 48) }
                            }
                        }}
                    }.counterShadow()
                }
            }.padding(18)
        }.background(CounterPalette.canvas.ignoresSafeArea())
            .navigationBarBackButtonHidden(true).refreshable { await model.loadMonth(month) }
            .task { await model.loadMonth(month) }
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CounterPalette.ink).frame(width: 40, height: 40).background(.white, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("返回")
    }
}
