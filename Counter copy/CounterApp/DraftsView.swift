import SwiftUI

struct DraftsView: View {
    @Bindable var model: AppModel
    let initialDraftID: String?
    @State private var selected: ReviewDraft?

    init(model: AppModel, initialDraftID: String? = nil) {
        self.model = model
        self.initialDraftID = initialDraftID
    }

    var body: some View {
        VStack(spacing: 13) {
            if model.drafts.isEmpty {
                CounterCard { CounterEmptyState(title: "目前没有待确认账单", detail: "从照片或其他 App 分享截图到 Counter 后，先核对内容，再确认入账。", symbol: "checkmark.circle") }
            } else {
                ForEach(model.drafts) { draft in
                    Button { selected = draft } label: { DraftRow(draft: draft, model: model) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if draft.state == .failed { Button("重新识别", systemImage: "arrow.clockwise") { Task { await model.retry(draft) } } }
                            Button("忽略", systemImage: "trash", role: .destructive) { Task { await model.dismiss(draft) } }
                        }
                }
            }
        }
        .sheet(item: $selected) { draft in DraftReviewSheet(model: model, initialDraft: draft) }
        .task {
            await model.refresh()
            if let initialDraftID, let draft = model.drafts.first(where: { $0.id == initialDraftID }) {
                selected = draft
            }
        }
    }
}

private struct DraftRow: View {
    let draft: ReviewDraft
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 13) {
            CounterCategoryArtwork(assetName: draft.categoryID.flatMap { id in model.categories.first { $0.id == id }?.symbol } ?? "custom_category", side: 38, iconPNGBase64: draft.categoryID.flatMap { id in model.categories.first { $0.id == id }?.iconPNGBase64 })
                .frame(width: 42, height: 42).background(CounterPalette.yellow.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(draft.cents.map { CounterFormat.amount($0) } ?? "金额待核对").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(draft.state.label).font(.system(size: 10, weight: .medium)).foregroundStyle(CounterPalette.secondary)
                }
                Text(draft.note.isEmpty ? "选择以核对收支、分类和日期" : draft.note)
                    .font(.system(size: 12)).foregroundStyle(CounterPalette.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CounterPalette.secondary)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).counterShadow()
    }
}

private struct DraftReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReviewDraft
    @State private var amountText: String
    @State private var error: String?
    @State private var committing = false
    @State private var isPersisting = false
    @State private var didFinishAction = false
    @State private var lastSavedSignature: String

    init(model: AppModel, initialDraft: ReviewDraft) {
        self.model = model
        let initialAmount = initialDraft.amountText ?? initialDraft.cents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
        _draft = State(initialValue: initialDraft)
        _amountText = State(initialValue: initialAmount)
        _lastSavedSignature = State(initialValue: Self.signature(initialDraft, amount: initialAmount))
    }

    private var categories: [BookCategory] {
        draft.kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var editSignature: String { Self.signature(draft, amount: amountText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("核对识别结果") {
                    TextField("金额（元）", text: Binding(get: { amountText }, set: { amountText = $0; markConfirmed("amount") }))
                        .keyboardType(.decimalPad)
                    if (draft.candidateConfidence?["amount"] ?? 0) < 0.35 {
                        Text("未能唯一识别金额，请手动填写。")
                            .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                    }
                    Picker("收支类型", selection: Binding(get: { draft.kind ?? .expense }, set: { value in
                        draft.kind = value
                        markConfirmed("kind")
                        if !categories.contains(where: { $0.id == draft.categoryID }) { draft.categoryID = nil; markConfirmed("categoryID") }
                    })) {
                        ForEach(EntryKind.allCases) { kind in Text(kind.label).tag(kind) }
                    }
                    Picker("分类", selection: Binding(get: { draft.categoryID ?? "" }, set: { value in
                        draft.categoryID = value.isEmpty ? nil : value
                        markConfirmed("categoryID")
                    })) {
                        Text("请选择").tag("")
                        ForEach(categories) { category in Text(category.name).tag(category.id) }
                    }
                    DatePicker("发生时间", selection: Binding(get: { draft.occurredAt }, set: { value in
                        draft.occurredAt = value
                        markConfirmed("occurredAt")
                    }), displayedComponents: [.date, .hourAndMinute])
                    if draft.candidateConfidence?["occurredAt"] == nil {
                        Text("未识别到日期，暂填当前时间，请确认。")
                            .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                    }
                    TextField("备注", text: Binding(get: { draft.note }, set: { value in
                        draft.note = value
                        markConfirmed("note")
                    }))
                    if let confidence = draft.candidateConfidence, !confidence.isEmpty {
                        Text("识别结果仅供核对；请确认金额、类型、日期和分类后入账。")
                            .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                    }
                }
                if let imagePath = draft.imagePath {
                    Section("原始截图") {
                        if let image = loadImage(at: imagePath) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 210).frame(maxWidth: .infinity)
                        } else { Text("截图当前无法读取；可重新选择图片创建新的识别任务。") }
                    }
                }
                if !draft.recognizedText.isEmpty {
                    Section("识别文字") { Text(draft.recognizedText).font(.system(size: 12)).foregroundStyle(CounterPalette.secondary).textSelection(.enabled) }
                }
                if let issue = draft.errorText { Section("识别说明") { Text(issue).foregroundStyle(.orange) } }
                Section {
                    Button("重新识别原图", systemImage: "arrow.clockwise") {
                        Task {
                            if let saved = await persistReview() { await model.retry(saved); await refreshFromModel() }
                        }
                    }.disabled(draft.imagePath == nil || committing)
                    Button("忽略这笔", role: .destructive) {
                        Task { didFinishAction = true; await model.dismiss(draft); dismiss() }
                    }
                }
            }
            .navigationTitle("待确认").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { Task { if await persistReview() != nil { didFinishAction = true; dismiss() } } }
                        .disabled(committing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(committing ? "保存中" : "确认入账") { Task { await commit() } }.disabled(committing)
                }
            }
            .alert("无法确认", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .tint(CounterPalette.ink)
        .task(id: editSignature) {
            guard !didFinishAction, !committing, editSignature != lastSavedSignature else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !didFinishAction, !committing else { return }
            _ = await persistReview()
        }
        .onDisappear {
            guard !didFinishAction else { return }
            Task { _ = await persistReview() }
        }
    }

    private func commit() async {
        guard let cents = CounterMoney.cents(from: amountText) else {
            error = "金额必须大于零，最多输入两位小数。"; return
        }
        draft.cents = cents
        draft.amountText = amountText
        guard draft.kind != nil else { error = "请选择收入、支出或退款。"; return }
        guard let categoryID = draft.categoryID, categories.contains(where: { $0.id == categoryID }) else {
            error = "请选择一个有效分类。"; return
        }
        draft.categoryID = categoryID
        committing = true
        do {
            guard let saved = await persistReview() else { throw StoreError.staleDraft }
            try await model.confirm(saved)
            didFinishAction = true
            committing = false
            dismiss()
        } catch {
            committing = false
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func persistReview() async -> ReviewDraft? {
        guard !didFinishAction else { return draft }
        while isPersisting { try? await Task.sleep(for: .milliseconds(20)) }
        if lastSavedSignature == editSignature { return draft }
        isPersisting = true
        defer { isPersisting = false }
        draft.amountText = amountText
        draft.cents = CounterMoney.cents(from: amountText)
        guard let saved = await model.update(draft) else { return nil }
        draft = saved
        lastSavedSignature = editSignature
        return saved
    }

    private func markConfirmed(_ field: String) {
        var fields = draft.userConfirmedFields ?? []
        fields.insert(field)
        draft.userConfirmedFields = fields
    }

    private func refreshFromModel() async {
        await model.refresh()
        draft = model.drafts.first { $0.id == draft.id } ?? draft
        amountText = draft.amountText ?? draft.cents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
        lastSavedSignature = editSignature
    }

    private func loadImage(at path: String) -> UIImage? { UIImage(contentsOfFile: path) }

    private static func signature(_ draft: ReviewDraft, amount: String) -> String {
        [draft.id, amount, draft.kind?.rawValue ?? "", draft.categoryID ?? "",
         String(draft.occurredAt.timeIntervalSince1970), draft.note,
         (draft.userConfirmedFields ?? []).sorted().joined(separator: ",")].joined(separator: "\u{1f}")
    }
}
