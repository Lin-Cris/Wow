import SwiftUI

private struct EditorScratchpad: Codable {
    var kind: EntryKind
    var categoryID: String
    var amount: String
    var expression: String
    var icon: String
    var note: String
    var date: Date
    var accountID: String? = nil
}

struct EntryEditorView: View {
    @Bindable var model: AppModel
    let route: EntryEditorRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("counter.entry.accountOnLeadingSide") private var accountOnLeadingSide = true
    @State private var kind: EntryKind
    @State private var categoryID: String
    @State private var amount: String
    @State private var expression = ""
    @State private var icon: String
    @State private var note: String
    @State private var date: Date
    @State private var accountID: String?
    @State private var showingDate = false
    @State private var showingAccountPicker = false
    @State private var suppressAccountTileTap = false
    @State private var error: String?
    @State private var saving = false
    @State private var newEntryID = "entry-\(UUID().uuidString.lowercased())"
    private let editingID: String?
    private let refundOriginalID: String?
    private let refundCategoryID: String?
    private let refundLimitCents: Int64?

    init(model: AppModel, route: EntryEditorRoute, initialAccountID: String? = nil) {
        self.model = model
        self.route = route
        switch route {
        case .create(let kind):
            let scratch = Self.restoreScratchpad(for: "compose.\(kind.rawValue)")
            let selectedKind = scratch?.kind ?? kind
            let first = selectedKind == .income ? model.incomeCategories.first : model.expenseCategories.first
            _kind = State(initialValue: selectedKind)
            _categoryID = State(initialValue: scratch?.categoryID ?? first?.id ?? "")
            _amount = State(initialValue: scratch?.amount ?? "")
            _expression = State(initialValue: scratch?.expression ?? "")
            _icon = State(initialValue: scratch?.icon ?? first.map { $0.id == "dining" ? "dining_rice" : $0.symbol } ?? "custom_category")
            _note = State(initialValue: scratch?.note ?? "")
            _date = State(initialValue: scratch?.date ?? Date())
            _accountID = State(initialValue: initialAccountID ?? scratch?.accountID ?? model.preferredAccountID(for: selectedKind))
            editingID = nil
            refundOriginalID = nil
            refundCategoryID = nil
            refundLimitCents = nil
        case .prefill(let request):
            let selectedKind = request.kind ?? .expense
            let first = selectedKind == .income ? model.incomeCategories.first : model.expenseCategories.first
            let scratch = Self.restoreScratchpad(for: "prefill.\(request.id)")
            _kind = State(initialValue: selectedKind)
            _categoryID = State(initialValue: scratch?.categoryID ?? first?.id ?? "")
            _amount = State(initialValue: request.amount ?? scratch?.amount ?? "")
            _expression = State(initialValue: scratch?.expression ?? "")
            _icon = State(initialValue: scratch?.icon ?? first.map { $0.id == "dining" ? "dining_rice" : $0.symbol } ?? "custom_category")
            _note = State(initialValue: request.note ?? scratch?.note ?? "")
            _date = State(initialValue: request.occurredAt ?? scratch?.date ?? Date())
            _accountID = State(initialValue: scratch?.accountID ?? model.preferredAccountID(for: selectedKind))
            editingID = nil
            refundOriginalID = nil
            refundCategoryID = nil
            refundLimitCents = nil
        case .refund(let original, let remainingCents):
            let scratch = Self.restoreScratchpad(for: "refund.\(original.id)")
            _kind = State(initialValue: .refund)
            _categoryID = State(initialValue: original.categoryID)
            _amount = State(initialValue: scratch?.amount ?? "")
            _expression = State(initialValue: scratch?.expression ?? "")
            _icon = State(initialValue: original.iconChoice)
            _note = State(initialValue: scratch?.note ?? "退款")
            _date = State(initialValue: scratch?.date ?? Date())
            _accountID = State(initialValue: scratch?.accountID ?? original.accountID)
            editingID = nil
            refundOriginalID = original.id
            refundCategoryID = original.categoryID
            refundLimitCents = remainingCents
        case .edit(let entry):
            let scratch = Self.restoreScratchpad(for: "edit.\(entry.id)")
            _kind = State(initialValue: scratch?.kind ?? entry.kind)
            _categoryID = State(initialValue: scratch?.categoryID ?? entry.categoryID)
            _amount = State(initialValue: scratch?.amount ?? Self.amountString(entry.cents))
            _expression = State(initialValue: scratch?.expression ?? "")
            _icon = State(initialValue: scratch?.icon ?? entry.iconChoice)
            _note = State(initialValue: scratch?.note ?? entry.note)
            _date = State(initialValue: scratch?.date ?? entry.occurredAt)
            _accountID = State(initialValue: scratch?.accountID ?? entry.accountID)
            editingID = entry.id
            refundOriginalID = nil
            refundCategoryID = nil
            refundLimitCents = nil
        }
    }

    private var preservedCategory: BookCategory? {
        switch route {
        case .edit(let entry), .refund(let entry, _): return entry.resolvedCategory(in: model.categories)
        default: return nil
        }
    }

    private var visibleCategories: [BookCategory] {
        if kind == .refund, refundOriginalID != nil,
           let refundCategoryID,
           let originalCategory = preservedCategory, originalCategory.id == refundCategoryID {
            return [originalCategory]
        }
        let incomeOption = model.incomeCategories.filter { $0.id == BookCategory.incomeOption.id }
        let active = kind == .income && categoryID != BookCategory.incomeOption.id
            ? model.incomeCategories
            : model.expenseCategories + (kind == .refund ? [] : incomeOption)
        if editingID != nil,
           let preserved = preservedCategory, preserved.id == categoryID, preserved.kind == (kind == .income ? "income" : "expense"),
           !preserved.isActive, !active.contains(where: { $0.id == preserved.id }) {
            return (active + [preserved]).sorted { $0.sortOrder < $1.sortOrder }
        }
        return active
    }
    private var selectedCategory: BookCategory? {
        visibleCategories.first { $0.id == categoryID } ?? visibleCategories.first
    }
    private var iconChoices: [String] {
        guard let selectedCategory else { return ["custom_category"] }
        if selectedCategory.iconPNGBase64 != nil { return [selectedCategory.symbol] }
        if selectedCategory.id == "dining" {
            return ["dining_pan", "dining_pizza", "dining_rice", "dining_noodles", "dining_takeout"]
        }
        let artworkID = selectedCategory.id == BookCategory.incomeOption.id ? selectedCategory.symbol : selectedCategory.id
        let id = UIImage(named: "\(artworkID)_alt1") == nil ? "custom_category" : artworkID
        return (1...4).map { "\(id)_alt\($0)" } + [selectedCategory.symbol]
    }
    private var defaultIcon: String {
        guard let selectedCategory else { return "custom_category" }
        return selectedCategory.id == "dining" ? "dining_rice" : selectedCategory.symbol
    }
    private var displayAmount: String { expression + amount }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private var categoryViewportHeight: CGFloat {
        let rows = min(3, max(1, (visibleCategories.count + columns.count - 1) / columns.count))
        return CGFloat(rows * 78 + (rows - 1) * 9)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 9) {
                ScrollView(showsIndicators: false) {
                    categoryPicker
                }
                .frame(maxHeight: categoryViewportHeight)
                .scrollDismissesKeyboard(.interactively)
                iconPicker
            }
            .padding(.horizontal, 19)
            .padding(.top, 5)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            amountAndKeypad
        }
        .background(CounterPalette.canvas.ignoresSafeArea())
        .preferredColorScheme(.light)
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showingDate) {
            NavigationStack {
                DatePicker("发生时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).padding().tint(CounterPalette.yellow)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingDate = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingAccountPicker) {
            AccountPickerSheet(model: model, selectedAccountID: $accountID, kind: kind)
        }
        .onChange(of: kind) { _, newKind in
            if !visibleCategories.contains(where: { $0.id == categoryID && $0.kind == (newKind == .income ? "income" : "expense") }) {
                selectFirstCategory()
            }
            if newKind == .income, selectedAccount?.type.isLiability == true {
                accountID = model.preferredAccountID(for: newKind)
            }
            persistScratchpad()
        }
        .onChange(of: categoryID) { _, _ in persistScratchpad() }
        .onChange(of: amount) { _, _ in persistScratchpad() }
        .onChange(of: expression) { _, _ in persistScratchpad() }
        .onChange(of: icon) { _, _ in persistScratchpad() }
        .onChange(of: note) { _, _ in persistScratchpad() }
        .onChange(of: date) { _, _ in persistScratchpad() }
        .onChange(of: accountID) { _, _ in persistScratchpad() }
        .onChange(of: visibleCategories.map(\.id)) { _, ids in
            if !ids.contains(categoryID) { selectFirstCategory() }
        }
        .onAppear { if selectedCategory != nil && categoryID.isEmpty { selectFirstCategory() } }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CounterPalette.ink)
                    .frame(width: 40, height: 40)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Spacer()
            Menu {
                ForEach(EntryKind.allCases) { value in
                    Button(value.label) { kind = value; selectFirstCategory() }
                }
            } label: {
                Text(editingID != nil ? "编辑记录" : (refundOriginalID != nil ? "记一笔退款" : "记一笔"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CounterPalette.ink)
                    .frame(minWidth: 100, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("选择收支类型，当前\(kind.label)")
            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var categoryPicker: some View {
        VStack(spacing: 9) {
          if visibleCategories.isEmpty {
            VStack(spacing: 5) {
                Text("没有可用分类").font(.system(size: 14, weight: .semibold))
                Text("请先在管理与设置中启用或添加分类。")
                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                Button("管理分类") { model.editorRoute = nil; model.path.append(.settings) }
                    .font(.system(size: 12, weight: .semibold)).tint(CounterPalette.purple)
            }
            .frame(maxWidth: .infinity).padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          } else {
            LazyVGrid(columns: columns, spacing: 9) {
              ForEach(visibleCategories) { category in
                let selected = categoryID == category.id
                Button {
                    categoryID = category.id
                    if category.kind == "income" { kind = .income }
                    else if kind == .income { kind = .expense }
                    icon = category.id == "dining" ? "dining_rice" : category.symbol
                } label: {
                    VStack(spacing: 1) {
                        CounterCategoryArtwork(assetName: category.symbol, side: 46, iconPNGBase64: category.iconPNGBase64)
                            .overlay {
                                if selected {
                                    Ellipse().stroke(CounterPalette.yellow, lineWidth: 3)
                                        .frame(width: 57, height: 47)
                                }
                            }
                                .frame(height: 58)
                        Text(category.isActive ? category.name : "\(category.name) · 已停用")
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(CounterPalette.ink.opacity(0.82))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
              }
            }
          }
        }
        .accessibilityIdentifier("entry.categories")
    }

    private var iconPicker: some View {
        HStack(spacing: 3) {
            ForEach(iconChoices, id: \.self) { value in
                Button { icon = value } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(CounterPalette.yellow)
                            .opacity(icon == value ? 1 : 0)
                        CounterCategoryArtwork(assetName: value, side: 45, iconPNGBase64: selectedCategory?.iconPNGBase64)
                        Image(systemName: "triangle.fill")
                            .rotationEffect(.degrees(180))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(CounterPalette.yellow)
                            .opacity(icon == value ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择图标")
                .accessibilityAddTraits(icon == value ? .isSelected : [])
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white, in: Capsule())
        .counterShadow()
        .accessibilityIdentifier("entry.iconPicker")
    }

    private var amountAndKeypad: some View {
        VStack(spacing: 8) {
            if refundOriginalID != nil, let refundLimitCents {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(CounterPalette.purple)
                    Text("关联原支出 · 剩余可退 \(CounterFormat.amount(refundLimitCents))")
                        .foregroundStyle(CounterPalette.secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("entry.refundLimit")
            }
            Text(displayAmount.isEmpty ? "0.00" : displayAmount)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(CounterPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
                .frame(height: 43)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .accessibilityIdentifier("entry.amount")

            GeometryReader { geometry in
                let spacing: CGFloat = 8
                let accountWidth = max(64, (geometry.size.width - spacing) * 0.25)
                let noteWidth = max(0, geometry.size.width - spacing - accountWidth)
                let noteX = accountOnLeadingSide
                    ? accountWidth + spacing + noteWidth / 2
                    : noteWidth / 2
                ZStack(alignment: .topLeading) {
                    noteField(width: noteWidth)
                        .position(x: noteX, y: 22)

                    accountTile(width: accountWidth, isVisible: accountOnLeadingSide)
                        .position(x: accountWidth / 2, y: 22)

                    accountTile(width: accountWidth, isVisible: !accountOnLeadingSide)
                        .position(x: geometry.size.width - accountWidth / 2, y: 22)
                }
                .frame(width: geometry.size.width, height: 44)
                .animation(.spring(response: 0.40, dampingFraction: 0.88), value: accountOnLeadingSide)
            }
            .frame(height: 44)
            .accessibilityIdentifier("entry.accountNoteRow")

            keypad
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous)
                .fill(.white)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "calendar", "4", "5", "6", "＋", "7", "8", "9", "－", ".", "0", "delete.left", "checkmark"]
        return LazyVGrid(columns: columns, spacing: 7) {
            ForEach(keys, id: \.self) { key in
                Button {
                    if key == "calendar" { showingDate = true }
                    else if key == "checkmark" { Task { await save() } }
                    else { press(key) }
                } label: {
                    Group {
                        switch key {
                        case "calendar": Image(systemName: "calendar")
                        case "delete.left": Image(systemName: "delete.left")
                        case "checkmark": Image(systemName: "checkmark")
                        default: Text(key)
                        }
                    }
                    .font(.system(size: key == "checkmark" ? 22 : 21, weight: .medium, design: .rounded))
                    .foregroundStyle(CounterPalette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(key == "checkmark" ? CounterPalette.yellow : .white,
                                in: Capsule())
                    .shadow(color: CounterPalette.ink.opacity(key == "checkmark" ? 0.025 : 0.07), radius: 7, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(key == "checkmark" && (amount.isEmpty && expression.isEmpty || saving))
                .accessibilityLabel(accessibilityName(for: key))
                .accessibilityIdentifier("entry.key.\(key)")
            }
        }
        .accessibilityIdentifier("entry.keypad")
    }

    private func accountTile(width: CGFloat, isVisible: Bool) -> some View {
        Button {
            guard !suppressAccountTileTap else { return }
            showingAccountPicker = true
        } label: {
            HStack(spacing: 4) {
                AccountBrandMark(account: selectedAccount, side: 17)
                Text(selectedAccount?.displayName ?? "暂不关联")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(CounterPalette.ink)
                    .lineLimit(2).multilineTextAlignment(.leading).minimumScaleFactor(0.76)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(CounterPalette.secondary)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 44)
            .background(CounterPalette.canvas.opacity(0.75), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9)
        .simultaneousGesture(accountReorderGesture)
        .accessibilityLabel("选择账户，当前\(selectedAccount?.displayName ?? "暂不关联")。长按拖动可调整位置")
        .accessibilityIdentifier("entry.accountPicker")
        .accessibilityHidden(!isVisible)
        .allowsHitTesting(isVisible)
    }

    private func noteField(width: CGFloat) -> some View {
        TextField("备注：点击填写备注", text: $note)
            .font(.system(size: 14))
            .padding(.horizontal, 15)
            .frame(width: width, height: 44)
            .background(CounterPalette.canvas.opacity(0.72), in: Capsule())
            .submitLabel(.done)
    }

    private var accountReorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 6))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                suppressAccountTileTap = true
                let nextSide = drag.translation.width > 30 ? false : (drag.translation.width < -30 ? true : accountOnLeadingSide)
                if nextSide != accountOnLeadingSide {
                    accountOnLeadingSide = nextSide
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    suppressAccountTileTap = false
                }
            }
    }

    private func accessibilityName(for key: String) -> String {
        switch key {
        case "calendar": date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        case "delete.left": "删除一位"
        case "checkmark": "保存记录"
        case "＋": "加"
        case "－": "减"
        default: key
        }
    }

    private func selectFirstCategory() {
        if kind == .refund, let refundCategoryID,
           let originalCategory = preservedCategory, originalCategory.id == refundCategoryID {
            categoryID = originalCategory.id
            icon = originalCategory.symbol
            return
        }
        guard let first = (kind == .income ? model.incomeCategories : visibleCategories).first else { categoryID = ""; return }
        categoryID = first.id
        icon = first.id == "dining" ? "dining_rice" : first.symbol
    }

    private var scratchpadKey: String {
        if case .prefill(let request) = route { return "counter.editor.prefill.\(request.id)" }
        if let editingID { return "counter.editor.edit.\(editingID)" }
        if let refundOriginalID { return "counter.editor.refund.\(refundOriginalID)" }
        return "counter.editor.compose.\(kind.rawValue)"
    }

    private static func restoreScratchpad(for key: String) -> EditorScratchpad? {
        guard let data = UserDefaults.standard.data(forKey: "counter.editor.\(key)") else { return nil }
        return try? JSONDecoder().decode(EditorScratchpad.self, from: data)
    }

    private func persistScratchpad() {
        let value = EditorScratchpad(kind: kind, categoryID: categoryID, amount: amount,
                                     expression: expression, icon: icon, note: note, date: date,
                                     accountID: accountID)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: scratchpadKey)
    }

    private func press(_ key: String) {
        switch key {
        case "delete.left":
            if !amount.isEmpty { amount.removeLast() }
            else if !expression.isEmpty { expression.removeLast() }
        case "＋", "－":
            guard !amount.isEmpty, cents(amount) != nil, expression.count + amount.count + 1 <= 64 else { return }
            expression += amount + (key == "＋" ? "+" : "−")
            amount = ""
        case ".":
            if !amount.contains("."), expression.count + amount.count + 1 <= 64 { amount = amount.isEmpty ? "0." : amount + "." }
        default:
            guard key.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }), amount.count < 19,
                  expression.count + amount.count + 1 <= 64 else { return }
            amount += key
        }
    }

    private func evaluate(_ value: String) -> Int64? {
        let normalized = value.replacingOccurrences(of: "−", with: "-")
        let parts = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "+" || $0 == "-" })
        guard let first = parts.first, var result = cents(String(first)) else { return nil }
        var rest = String(normalized.dropFirst(first.count))
        for part in parts.dropFirst() {
            guard let next = cents(String(part)) else { return nil }
            let subtract = rest.first == "-"
            let (newValue, overflow) = subtract ? result.subtractingReportingOverflow(next) : result.addingReportingOverflow(next)
            guard !overflow else { return nil }
            result = newValue
            if !rest.isEmpty { rest.removeFirst() }
            rest = String(rest.dropFirst(part.count))
        }
        guard result >= 0 else { return nil }
        return result
    }

    private func cents(_ value: String) -> Int64? {
        CounterMoney.cents(from: value, allowZero: true)
    }

    private static func amountString(_ cents: Int64) -> String { String(format: "%lld.%02lld", cents / 100, cents % 100) }

    private func save() async {
        guard !saving else { return }
        guard let finalCents = evaluate(expression + amount), finalCents > 0,
              finalCents <= CounterMoney.maximumCents else {
            error = "请输入大于零、最多两位小数的金额。"
            return
        }
        if let refundLimitCents, kind == .refund, finalCents > refundLimitCents {
            error = "退款不能超过原支出的剩余可退金额。"
            return
        }
        if kind == .income, categoryID == BookCategory.incomeOption.id,
           selectedAccount == nil || selectedAccount?.type.isLiability == true {
            error = "请先选择一个资产账户接收收入。"
            return
        }
        guard let category = visibleCategories.first(where: { $0.id == categoryID }) ?? selectedCategory else {
            error = "请先选择一个分类。"
            return
        }
        saving = true
        defer { saving = false }
        let now = Date()
        let existing: BookEntry? = { if case .edit(let value) = route { return value }; return nil }()
        let entry = BookEntry(id: existing?.id ?? newEntryID, cents: finalCents,
                              kind: kind, occurredAt: date, categoryID: category.id, iconChoice: icon,
                              note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                              sourceID: existing?.sourceID,
                              originalEntryID: kind == .refund ? (existing?.originalEntryID ?? refundOriginalID) : nil,
                              createdAt: existing?.createdAt ?? now, updatedAt: now,
                              localDayKey: existing.flatMap { date == $0.occurredAt ? $0.localDayKey : nil },
                              accountingTimeZone: existing?.accountingTimeZone,
                              currencyCode: existing?.currencyCode,
                              recordVersion: existing?.recordVersion,
                              importBatchID: existing?.importBatchID,
                              confirmedDraftID: existing?.confirmedDraftID,
                              accountID: accountID, categorySnapshot: category.isActive ? nil : category)
        do {
            try await model.saveEntry(entry)
            UserDefaults.standard.removeObject(forKey: scratchpadKey)
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }

    private var selectedAccount: BookAccount? {
        model.accounts.first(where: { $0.id == accountID })
    }
}
