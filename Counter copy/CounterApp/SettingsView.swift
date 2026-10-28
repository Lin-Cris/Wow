import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    var focusCategories = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("counter.showPrivateActivity", store: UserDefaults(suiteName: CaptureService.appGroup)) private var revealActivityDetails = false
    @State private var csvExporter = false
    @State private var backupExporter = false
    @State private var fileImporter = false
    @State private var csvDocument: CSVDocument?
    @State private var backupDocument: BackupDocument?
    @State private var backupExportFilename = "Counter-完整备份.counterbackup"
    @State private var csvPreview: CSVPreview?
    @State private var backupData: Data?
    @State private var showBackupPreview = false
    @State private var restorePreview: CounterRestorePreview?
    @State private var showReplaceConfirm = false
    @State private var batchToUndo: ImportBatch?
    @State private var batchToRetry: ImportBatch?
    @State private var recoveryToRestore: BackupRecoveryPoint?
    @State private var recoveryToDelete: BackupRecoveryPoint?
    @State private var showAddCategory = false
    @State private var newCategoryKind: EntryKind = .expense
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !focusCategories {
                    HStack { BackButton(); Spacer(); Text("管理與設定").font(.system(size: 17, weight: .semibold)); Spacer(); Color.clear.frame(width: 40, height: 40) }
                    DraftsView(model: model)
                }
                categorySection
                if !focusCategories {
                    privacySection
                    dataSection
                    importBatchSection
                    .sheet(isPresented: $showBackupPreview) {
                        if let restorePreview {
                            RestorePreviewView(preview: restorePreview,
                                               merge: { showBackupPreview = false; restore(replace: false) },
                                               replace: { showBackupPreview = false; showReplaceConfirm = true },
                                               cancel: { showBackupPreview = false; backupData = nil })
                        }
                    }
                    recoverySection
                    CounterCard(inset: 16) {
                        HStack(spacing: 11) {
                            Image(systemName: "lock.shield").foregroundStyle(CounterPalette.purple).font(.system(size: 19))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("只在本机保存").font(.system(size: 14, weight: .semibold))
                                Text("账本、截图识别和导入文件均在本机处理；不需要注册账号。")
                                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("Counter · iOS 版").font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
            }.padding(18).padding(.top, 4)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if focusCategories {
                HStack {
                    BackButton()
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .background(CounterPalette.canvas)
            }
        }
        .background(CounterPalette.canvas.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onChange(of: revealActivityDetails) { _, _ in
            Task { await model.refreshActivityPrivacy() }
        }
        .fileExporter(isPresented: $csvExporter, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: "Counter-账单.csv") { result in report(result, success: "CSV 已导出") }
        .fileExporter(isPresented: $backupExporter, document: backupDocument, contentType: .counterBackup, defaultFilename: backupExportFilename) { result in report(result, success: "完整备份已导出") }
        .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .json, .counterBackup, .image, .jpeg, .png], allowsMultipleSelection: false, onCompletion: receiveImport)
        .sheet(isPresented: Binding(get: { csvPreview != nil }, set: { if !$0 { csvPreview = nil } })) {
            if let csvPreview { CSVImportPreview(model: model, preview: csvPreview) { result in message = result; self.csvPreview = nil } }
        }
        .confirmationDialog("确认替换本地账本？", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
            Button("驗證並替換", role: .destructive) { restore(replace: true) }
            Button("取消", role: .cancel) { backupData = nil }
        } message: { Text("此操作将以所选备份替换当前记录和分类。") }
        .confirmationDialog("撤销这批导入？", isPresented: Binding(get: { batchToUndo != nil }, set: { if !$0 { batchToUndo = nil } }), titleVisibility: .visible) {
            if let batchToUndo {
                Button("撤销未修改明细", role: .destructive) {
                    Task { do { message = try await model.undoImportBatch(batchToUndo.id) } catch { message = error.localizedDescription }; self.batchToUndo = nil }
                }
            }
            Button("取消", role: .cancel) { batchToUndo = nil }
        } message: { Text("只会移除仍未修改、且没有退款关联的明细；有后续修改的记录会保留。") }
        .confirmationDialog("重试失败的导入？", isPresented: Binding(get: { batchToRetry != nil }, set: { if !$0 { batchToRetry = nil } }), titleVisibility: .visible) {
            if let batchToRetry {
                Button("继续导入") {
                    Task { do { try await model.retryImportBatch(batchToRetry.id); message = "导入已完成。" } catch { message = error.localizedDescription }; self.batchToRetry = nil }
                }
            }
            Button("取消", role: .cancel) { batchToRetry = nil }
        } message: { Text("Counter 会重新核对来源文件，并保持重复记录安全跳过。") }
        .confirmationDialog("从恢复点替换账本？", isPresented: Binding(get: { recoveryToRestore != nil }, set: { if !$0 { recoveryToRestore = nil } }), titleVisibility: .visible) {
            if let recoveryToRestore {
                Button("验证并恢复", role: .destructive) {
                    Task { do { try await model.restoreRecoveryPoint(recoveryToRestore.filename); message = "已从恢复点恢复账本。" } catch { message = error.localizedDescription }; self.recoveryToRestore = nil }
                }
            }
            Button("取消", role: .cancel) { recoveryToRestore = nil }
        } message: { Text("恢复前会自动再保存当前账本。") }
        .confirmationDialog("删除这个恢复点？", isPresented: Binding(get: { recoveryToDelete != nil }, set: { if !$0 { recoveryToDelete = nil } }), titleVisibility: .visible) {
            if let recoveryToDelete {
                Button("删除恢复点", role: .destructive) {
                    do { try model.deleteRecoveryPoint(recoveryToDelete.filename); message = "恢复点已删除。" } catch { message = error.localizedDescription }
                    self.recoveryToDelete = nil
                }
            }
            Button("取消", role: .cancel) { recoveryToDelete = nil }
        } message: { Text("删除后无法通过 Counter 找回这个恢复点。") }
        .sheet(isPresented: $showAddCategory) {
            CategoryEditorView(model: model, kind: newCategoryKind)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert("", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .task { await model.refresh(); await model.refreshImportBatches(); model.refreshRecoveryPoints() }
    }

    private var categorySection: some View {
        CounterCard(inset: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("分类").font(.system(size: 16, weight: .bold)); Spacer(); Menu {
                    Button("添加支出分类", systemImage: "plus") { newCategoryKind = .expense; showAddCategory = true }
                    Button("添加收入分类", systemImage: "plus") { newCategoryKind = .income; showAddCategory = true }
                } label: { Label("添加", systemImage: "plus.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(CounterPalette.ink) } }
                Text("关闭分类只影响后续选择，历史记录仍保留。")
                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                List {
                    ForEach(model.categories) { category in
                        HStack(spacing: 10) {
                            CounterCategoryArtwork(assetName: category.symbol, side: 27, iconPNGBase64: category.iconPNGBase64).frame(width: 30, height: 30)
                            Text(category.name).font(.system(size: 13, weight: .medium))
                            Text(category.kind == "income" ? "收入" : "支出").font(.system(size: 10)).foregroundStyle(CounterPalette.secondary)
                            Spacer()
                            Toggle(category.name, isOn: Binding(get: { category.isActive }, set: { _ in Task { await model.toggleCategory(category) } }))
                                .labelsHidden().tint(CounterPalette.yellow)
                        }
                        .frame(height: 47)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("categories.row.\(category.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if category.isUserCreated {
                                // Commit before publishing removal; a failed write keeps the row.
                                Button {
                                    Task { do { try await model.deleteCategory(category) } catch { message = error.localizedDescription } }
                                } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 47)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(model.categories.count) * 47)
            }
        }.counterShadow()
    }

    private var privacySection: some View {
        CounterCard(inset: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text("快捷与隐私").font(.system(size: 16, weight: .bold))
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("实时活动显示金额和分类").font(.system(size: 13, weight: .medium))
                        Text("关闭时，锁屏只显示“有一笔待记账”。").font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                    }
                    Spacer()
                    Toggle("显示账单详情", isOn: $revealActivityDetails).labelsHidden().tint(CounterPalette.yellow)
                }
                Label("可用 Siri 快捷指令记账或识别截图", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(CounterPalette.secondary).padding(.top, 3)
            }
        }.counterShadow()
    }

    private var dataSection: some View {
        CounterCard(inset: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("账本文件").font(.system(size: 16, weight: .bold))
                Text("CSV 适合查看和交换明细；完整备份包含分类、草稿和可用的原图。")
                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { do { csvDocument = try await model.csvDocument(); csvExporter = true } catch { message = error.localizedDescription } } } label: { settingsRow("导出 CSV 账单", icon: "tablecells") }
                Button { Task { do { backupDocument = try await model.backupDocument(); backupExportFilename = "Counter-完整备份.counterbackup"; backupExporter = true } catch { message = error.localizedDescription } } } label: { settingsRow("导出完整备份", icon: "archivebox") }
                Button { fileImporter = true } label: { settingsRow("导入账单或恢复备份", icon: "square.and.arrow.down") }
                Text("支持 CSV / 文本账单、Counter JSON 备份及截图。导入前会先预览。")
                    .font(.system(size: 10)).foregroundStyle(CounterPalette.secondary)
            }
        }.counterShadow()
    }

    private var importBatchSection: some View {
        CounterCard(inset: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("导入批次").font(.system(size: 16, weight: .bold))
                Text("每批记录来源、进度和结果；撤销只会移除尚未修改的导入记录。")
                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).fixedSize(horizontal: false, vertical: true)
                if model.importBatches.isEmpty {
                    Text("还没有导入批次。CSV 预览确认后会在这里留下记录。")
                        .font(.system(size: 12)).foregroundStyle(CounterPalette.secondary)
                } else {
                    ForEach(model.importBatches) { batch in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(importBatchState(batch.state)).font(.system(size: 10, weight: .medium)).foregroundStyle(CounterPalette.purple)
                            }
                            Text("新增 \(batch.inserted) · 重复 \(batch.duplicates) · 冲突 \(batch.conflicts) · 无效 \(batch.invalid) / 共 \(batch.inputRows) 行")
                                .font(.system(size: 10)).foregroundStyle(CounterPalette.secondary)
                            if let progress = model.importProgress[batch.id], !progress.isComplete {
                                ProgressView(value: Double(progress.cursor), total: Double(max(1, progress.inputRows)))
                                    .tint(CounterPalette.purple)
                            }
                            HStack(spacing: 16) {
                                if batch.state == "completed" || batch.state == "completedWithConflicts" {
                                    Button("撤销未修改明细") { batchToUndo = batch }
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                                } else if batch.state == "failed" {
                                    Button("重试") { batchToRetry = batch }
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.purple)
                                }
                                Spacer()
                                if !batch.sourceDigest.isEmpty {
                                    Text("来源 \(String(batch.sourceDigest.prefix(10)))")
                                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(CounterPalette.secondary)
                                }
                            }
                        }.padding(.vertical, 7)
                        if batch.id != model.importBatches.last?.id { Divider() }
                    }
                }
            }
        }.counterShadow()
    }

    private var recoverySection: some View {
        CounterCard(inset: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("本机恢复点").font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button {
                        Task { do { let name = try await model.createRecoveryPoint(); message = "恢复点已保存：\(name)" } catch { message = error.localizedDescription } }
                    } label: { Label("保存当前账本", systemImage: "plus.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.ink) }
                }
                Text("替换恢复前 Counter 会自动保存一份；你也可以随时创建、恢复或删除本机恢复点。")
                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary).fixedSize(horizontal: false, vertical: true)
                if model.recoveryPoints.isEmpty {
                    Text("尚无恢复点。导出完整备份可另存到文件中。")
                        .font(.system(size: 12)).foregroundStyle(CounterPalette.secondary)
                } else {
                    ForEach(model.recoveryPoints) { point in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(point.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(point.filename) · \(ByteCountFormatter.string(fromByteCount: point.sizeBytes, countStyle: .file))")
                                .font(.system(size: 9)).foregroundStyle(CounterPalette.secondary).lineLimit(2)
                            HStack(spacing: 16) {
                                Button("恢复") { recoveryToRestore = point }
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.purple)
                                Button("导出") {
                                    Task { do { backupDocument = try await model.recoveryPointDocument(point.filename); backupExportFilename = point.filename; backupExporter = true } catch { message = error.localizedDescription } }
                                }.font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.purple)
                                Button("删除", role: .destructive) { recoveryToDelete = point }
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }.padding(.vertical, 7)
                        if point.id != model.recoveryPoints.last?.id { Divider() }
                    }
                }
            }
        }.counterShadow()
    }

    private func importBatchState(_ state: String) -> String {
        switch state {
        case "prepared", "running": "处理中"
        case "completed": "已完成"
        case "completedWithConflicts": "已完成，部分保留"
        case "undone": "已撤销"
        case "failed": "待重试"
        default: "状态未知"
        }
    }

    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(CounterPalette.purple).frame(width: 21)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(CounterPalette.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CounterPalette.secondary)
        }.padding(.vertical, 5).contentShape(Rectangle())
    }

    private func receiveImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error): message = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let contentType = values.contentType
                let imageFile = ["jpg", "jpeg", "png", "heic", "heif"].contains(url.pathExtension.lowercased()) || contentType?.conforms(to: .image) == true
                let backupFile = ["json", "counterbackup"].contains(url.pathExtension.lowercased())
                let maximumBytes = imageFile ? 25 * 1_024 * 1_024 : (backupFile ? 256 : 30) * 1_024 * 1_024
                guard (values.fileSize ?? Int.max) <= maximumBytes else {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    message = imageFile ? "图片超过 25 MB，无法安全识别。" : (backupFile ? "备份超过 256 MB，无法安全读取。" : CounterCSVError.fileTooLarge.localizedDescription)
                    return
                }
                if imageFile {
                    Task {
                        do { _ = try await model.reviewImage(at: url) }
                        catch { message = error.localizedDescription }
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                } else {
                    let data = try Data(contentsOf: url)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    if backupFile {
                        guard let backup = try? JSONDecoder().decode(CounterBackup.self, from: data), backup.format == "counter-backup" else {
                            message = "完整备份格式无效或文件已损坏。"
                            return
                        }
                        backupData = data
                        Task {
                            do {
                                restorePreview = try await model.previewRestore(data)
                                showBackupPreview = true
                            } catch {
                                backupData = nil
                                message = error.localizedDescription
                            }
                        }
                    } else {
                        Task { do { csvPreview = try await model.previewCSV(data) } catch { message = error.localizedDescription } }
                    }
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                message = error.localizedDescription
            }
        }
    }

    private func restore(replace: Bool) {
        guard let backupData else { return }
        Task { do { try await model.restore(backupData, replace: replace); self.backupData = nil; message = replace ? "已从备份恢复本地账本。" : "已将备份合并到本地账本。" } catch { self.backupData = nil; message = error.localizedDescription } }
    }

    private func report(_ result: Result<URL, Error>, success: String) {
        switch result { case .success: message = success; case .failure(let error): message = error.localizedDescription }
    }
}

private struct CSVImportPreview: View {
    @Bindable var model: AppModel
    let preview: CSVPreview
    let completed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var issue: String?
    @State private var records: [BookEntry]
    @State private var amountTexts: [String: String]
    @State private var searchText = ""

    init(model: AppModel, preview: CSVPreview, completed: @escaping (String) -> Void) {
        self.model = model
        self.preview = preview
        self.completed = completed
        _records = State(initialValue: preview.records)
        _amountTexts = State(initialValue: Dictionary(uniqueKeysWithValues: preview.records.map { ($0.id, CounterFormat.amount($0.cents)) }))
    }

    private var visibleRecordIndices: [Int] {
        records.indices.filter { index in
            searchText.isEmpty || records[index].note.localizedCaseInsensitiveContains(searchText) ||
            records[index].id.localizedCaseInsensitiveContains(searchText) ||
            preview.categories.first(where: { $0.id == records[index].categoryID })?.name.localizedCaseInsensitiveContains(searchText) == true ||
            model.categories.first(where: { $0.id == records[index].categoryID })?.name.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var hasInvalidAmount: Bool {
        records.contains { CounterMoney.cents(from: amountTexts[$0.id] ?? CounterFormat.amount($0.cents)) == nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("识别结果") {
                    LabeledContent("可导入", value: "\(records.count) 笔")
                    LabeledContent("文件数据行", value: "\(preview.totalRows) 行")
                    LabeledContent("已存在", value: "\(preview.duplicateCount) 笔")
                    LabeledContent("来源冲突", value: "\(preview.conflictCount) 笔")
                    LabeledContent("需要核对", value: "\(preview.rejectedRows.count) 行")
                }
                Section("全部可导入明细（\(visibleRecordIndices.count)/\(records.count)）") {
                    ForEach(visibleRecordIndices, id: \.self) { index in
                        CSVImportEntryRow(entry: $records[index], amountText: Binding(
                            get: { amountTexts[records[index].id] ?? CounterFormat.amount(records[index].cents) },
                            set: { value in
                                let id = records[index].id
                                amountTexts[id] = value
                                if let cents = CounterMoney.cents(from: value) { records[index].cents = cents }
                            }),
                            categories: (model.categories + preview.categories).filter { $0.kind == (records[index].kind == .income ? "income" : "expense") })
                    }
                }
                if !preview.rejectedRows.isEmpty {
                    Section("需要人工核对（\(preview.rejectedRows.count) 行）") {
                        ForEach(Array(preview.rejectedRows.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !preview.categories.isEmpty { Section("将新增的分类") { ForEach(preview.categories) { Text($0.name) } } }
                if let issue { Section { Text(issue).foregroundStyle(.red) } }
            }
            .navigationTitle("导入预览").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索备注、分类或编号")
            .overlay(alignment: .bottom) {
                if hasInvalidAmount && !importing {
                    Text("请修正金额后再导入。")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(CounterPalette.purple, in: Capsule()).padding(.bottom, 52)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(importing ? "导入中" : "确认导入") { Task { await commit() } }.disabled(importing || preview.totalRows == 0 || hasInvalidAmount) }
            }
        }
    }

    private func commit() async {
        importing = true
        do {
            var reviewed = preview
            reviewed.records = records
            completed(try await model.importCSV(reviewed)); dismiss()
        }
        catch { importing = false; issue = error.localizedDescription }
    }
}

private struct CSVImportEntryRow: View {
    @Binding var entry: BookEntry
    @Binding var amountText: String
    let categories: [BookCategory]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                CounterCategoryArtwork(assetName: selectedCategory?.symbol ?? entry.iconChoice, side: 30, iconPNGBase64: selectedCategory?.iconPNGBase64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kind.label).font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.secondary)
                    DatePicker("交易日期", selection: $entry.occurredAt, displayedComponents: [.date])
                        .labelsHidden().datePickerStyle(.compact).onChange(of: entry.occurredAt) { _, value in entry.localDayKey = CounterFormat.localDayKey(value) }
                }
                Spacer()
                TextField("金额（元）", text: $amountText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
            }
            TextField("备注", text: $entry.note).font(.system(size: 12))
            Menu {
                ForEach(categories.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }) { category in
                    Button(category.name) { entry.categoryID = category.id; entry.iconChoice = category.symbol }
                }
            } label: {
                Label(selectedCategory?.name ?? "选择分类", systemImage: "tag")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(CounterPalette.purple)
            }
        }.padding(.vertical, 5)
    }

    private var selectedCategory: BookCategory? { categories.first(where: { $0.id == entry.categoryID }) }
}

private struct RestorePreviewView: View {
    let preview: CounterRestorePreview
    let merge: () -> Void
    let replace: () -> Void
    let cancel: () -> Void

    private var conflictCount: Int {
        preview.conflictingEntries + preview.conflictingDrafts + preview.conflictingCategories + preview.conflictingBatches + preview.conflictingAccounts + preview.conflictingTransfers
    }

    var body: some View {
        NavigationStack {
            List {
                Section("备份内容") {
                    LabeledContent("新增账单", value: "\(preview.newEntries) 笔")
                    LabeledContent("完全相同", value: "\(preview.exactEntries) 笔")
                    LabeledContent("待记账草稿", value: "\(preview.newDrafts) 笔（相同 \(preview.exactDrafts)）")
                    LabeledContent("新增分类", value: "\(preview.newCategories) 个")
                    LabeledContent("新增账户", value: "\(preview.newAccounts) 个")
                    LabeledContent("新增转账 / 还款", value: "\(preview.newTransfers) 笔")
                    LabeledContent("原图附件", value: "\(preview.imageCount) 张 · \(ByteCountFormatter.string(fromByteCount: Int64(preview.imageBytes), countStyle: .file))")
                }
                Section("合并冲突") {
                    if conflictCount == 0 {
                        Label("没有与本机账本冲突", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("发现 \(conflictCount) 项冲突。合并会被暂停，以免覆盖现有账单、账户、分类或草稿。你可以取消，或明确选择用备份替换当前账本。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, conflict in
                            Text(conflict).font(.system(size: 11)).foregroundStyle(.red)
                        }
                        if conflictCount > preview.conflicts.count {
                            Text("此处显示前 \(preview.conflicts.count) 项；其余冲突计入上方总数。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("完整备份已完成格式、金额、日期、关联和附件校验。替换前还会自动保存当前账本恢复点。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("恢复方案预览").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("合并", action: merge).disabled(!preview.canMerge)
                    Button("替换", role: .destructive, action: replace)
                }
            }
        }
    }
}


private struct CategoryEditorView: View {
    let model: AppModel
    let kind: EntryKind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var iconPNGBase64: String?
    @State private var importingIcon = false
    @State private var isProcessingIcon = false
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CounterCard(inset: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("分类名称").font(.system(size: 12, weight: .medium)).foregroundStyle(CounterPalette.secondary)
                            TextField("Category Name", text: $name)
                                .font(.system(size: 15)).textInputAutocapitalization(.words)
                                .focused($nameFocused).submitLabel(.done)
                                .onSubmit { nameFocused = false }
                                .accessibilityIdentifier("category.name")
                        }
                    }
                    CounterCard(inset: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("分类图标").font(.system(size: 12, weight: .medium)).foregroundStyle(CounterPalette.secondary)
                            Button { nameFocused = false; importingIcon = true } label: {
                                HStack(spacing: 12) {
                                    CounterCategoryArtwork(assetName: "custom_category", side: 38, iconPNGBase64: iconPNGBase64)
                                        .accessibilityIdentifier("category.iconPreview")
                                    Text(isProcessingIcon ? "正在处理 PNG…" : (iconPNGBase64 == nil ? "选择 PNG 图标" : "更换 PNG 图标"))
                                        .font(.system(size: 14, weight: .medium)).foregroundStyle(CounterPalette.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                                }
                                .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(isProcessingIcon || isSaving)
                            .accessibilityIdentifier("category.chooseIcon")
                            if iconPNGBase64 != nil {
                                Button("恢复默认图标") { iconPNGBase64 = nil }
                                    .font(.system(size: 11)).foregroundStyle(CounterPalette.secondary)
                            }
                        }
                    }
                }.padding(18)
            }
            .background(CounterPalette.canvas)
            .navigationTitle(kind == .income ? "添加收入分类" : "添加支出分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            do { try await model.addCategory(name, kind: kind, iconPNGBase64: iconPNGBase64); dismiss() }
                            catch { self.error = error.localizedDescription; isSaving = false }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingIcon || isSaving)
                    .accessibilityIdentifier("category.save")
                }
            }
            .fileImporter(isPresented: $importingIcon, allowedContentTypes: [.png]) { result in
                switch result {
                case .failure(let error): self.error = error.localizedDescription
                case .success(let url):
                    isProcessingIcon = true
                    Task {
                        defer { isProcessingIcon = false }
                        do {
                            let encoded = try await Task.detached(priority: .userInitiated) {
                                try CategoryIconArtwork.preparePNG(at: url)
                            }.value
                            iconPNGBase64 = encoded
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("无法保存分类", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
