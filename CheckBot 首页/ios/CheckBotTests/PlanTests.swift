import XCTest
import UserNotifications
import SQLite3
import AVFoundation
import UIKit
import SwiftUI
@testable import CounterTool
@testable import CheckBot

final class PlanTests: XCTestCase {
    var folder: URL!
    var defaults: UserDefaults!
    var suite: String!
    override func setUpWithError() throws {
        suite = "CheckBot.Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }
    func filename(_ date: Date = Date()) -> String {
        let parts = PlanFolderStore.day(date).split(separator: "-")
        return "\(parts[0])年\(Int(parts[1])!)月\(Int(parts[2])!)日.md"
    }
    func write(_ title: String, date: Date = Date()) throws {
        let text = "# \(PlanFolderStore.day(date))\n### 00:00–23:59｜\(title)\n- [ ] **Behavior：**Do the task\n"
        try text.write(to: folder.appendingPathComponent(filename(date)), atomically: true, encoding: .utf8)
    }
    func testDisconnectedAndOldNoteDoesNotCreateTodayTemplate() throws {
        let store = PlanFolderStore(defaults: defaults)
        XCTAssertEqual(try store.read()["status"] as? String, "disconnected")
        try write("Old task", date: Date(timeIntervalSince1970: 1_600_000_000))
        try store.connect(folder)
        let raw = try store.read()
        XCTAssertEqual(raw["status"] as? String, "no_today_note")
        XCTAssertEqual(raw["source"] as? String, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PlanFolderStore.filename()).path))
    }
    func testBookmarkRestoresAndRereadsWithoutWritingSource() throws {
        try write("Original")
        try PlanFolderStore(defaults: defaults).connect(folder)
        let restored = PlanFolderStore(defaults: UserDefaults(suiteName: suite)!)
        let before = try Data(contentsOf: folder.appendingPathComponent(filename()))
        XCTAssertTrue((try restored.read()["markdown"] as? String)?.contains("Original") == true)
        XCTAssertEqual(before, try Data(contentsOf: folder.appendingPathComponent(filename())))
        try write("Updated")
        XCTAssertTrue((try restored.read()["markdown"] as? String)?.contains("Updated") == true)
    }
    func testToggleChangesOnlyTheCheckboxAndCanToggleBack() throws {
        try write("Toggle")
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "lineIndex": 2,
            "line": "- [ ] **Behavior：**Do the task",
            "identity": "- [ ] **Behavior：**Do the task",
            "scheduleLineIndex": 1,
            "scheduleLine": "### 00:00–23:59｜Toggle",
            "hasBehaviorCheckbox": true
        ]
        let before = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        _ = try store.toggle(source: source)
        let completed = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertEqual(completed, before.replacingOccurrences(of: "- [ ] **Behavior：**Do the task", with: "- [x] **Behavior：**Do the task"))
        _ = try store.toggle(source: source)
        let reopened = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertEqual(reopened, before)
    }
    func testInlinePlanTogglesOriginalCheckboxLineWithoutAddingBehavior() throws {
        let inline = "- [ ] 08:30–09:00 Dev Sync"
        let untouched = "- [ ] 买牛奶"
        let text = "# \(PlanFolderStore.day(Date()))\n\(inline)\n\(untouched)\n"
        try text.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "sourceLineIndex": 1,
            "sourceRawLine": inline,
            "identity": inline,
            "scheduleLineIndex": 1,
            "scheduleLine": inline
        ]

        _ = try store.toggle(source: source)
        let completed = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertEqual(completed, text.replacingOccurrences(of: "- [ ] 08:30–09:00 Dev Sync", with: "- [x] 08:30–09:00 Dev Sync"))
        XCTAssertFalse(completed.contains("Behavior"))

        _ = try store.toggle(source: source)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8), text)
    }
    func testBoldInlinePlanTogglesOriginalCheckboxLineWithoutAddingBehavior() throws {
        let inline = "- [ ] **08:30–09:00**　在大厅完成核心训练，然后洗澡。"
        let untouched = "- [ ] 买牛奶"
        let text = "# \(PlanFolderStore.day(Date()))\n\(inline)\n\(untouched)\n"
        try text.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)

        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "sourceLineIndex": 1,
            "sourceRawLine": inline,
            "identity": inline,
            "scheduleLineIndex": 1,
            "scheduleLine": inline
        ]

        _ = try store.toggle(source: source)
        let completed = "# \(PlanFolderStore.day(Date()))\n- [x] **08:30–09:00**　在大厅完成核心训练，然后洗澡。\n\(untouched)\n"
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8), completed)
        XCTAssertFalse(completed.contains("Behavior"))

        _ = try store.toggle(source: source)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8), text)
    }

    func testFlexibleChecklistFormatImportsTheWholeDailyPlan() throws {
        let text = """
        # 明日计划｜2026年9月15日

        - [ ] 08:30 起床。
        - [ ] 10:00 左右 在房间的桌子上学习 English Tip。
        - [ ] 11:00 检查并完善自己的简历，然后在 BOSS 直聘上继续找工作。
        - [ ] 11:30 去厨房煮菜并吃饭。

        ## 下午

        - [ ] 完成今天的求职目标：投递 2 份合适的简历。
        - [ ] 15:00 左右 吃下午茶，和 17:00 的搏击训练间隔至少 1.5 小时。
        - [ ] 17:00 开始搏击训练。
        """
        let raw: [String: Any] = [
            "today": "2026-09-15",
            "source": "2026年9月15日.md",
            "markdown": text,
            "connected": true,
            "status": "ready"
        ]

        let snapshot = try WowPlanParser.snapshot(from: raw)
        XCTAssertTrue(snapshot.isToday)
        XCTAssertEqual(snapshot.plans.count, 7)
        XCTAssertEqual(snapshot.plans.map(\.startTime), ["08:30", "10:00", "11:00", "11:30", nil, "15:00", "17:00"])
        XCTAssertEqual(snapshot.plans[1].title, "在房间的桌子上学习 English Tip。")
        XCTAssertEqual(snapshot.plans[4].title, "完成今天的求职目标：投递 2 份合适的简历。")
        XCTAssertTrue(snapshot.summary.contains("imported 7"))
        XCTAssertTrue(snapshot.summary.contains("1 without a time"))
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testFlexibleChecklistSourceCanToggleWithoutAddingBehavior() throws {
        let text = "# 2026年9月15日\n- [ ] 10:00 左右 完成任务\n"
        try text.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)

        let raw: [String: Any] = [
            "today": PlanFolderStore.day(Date()),
            "source": filename(),
            "markdown": text,
            "connected": true,
            "status": "ready"
        ]
        let snapshot = try WowPlanParser.snapshot(from: raw)
        XCTAssertEqual(snapshot.plans.count, 1)
        _ = try store.toggle(source: try XCTUnwrap(snapshot.plans[0].source).dictionary)

        let updated = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertTrue(updated.contains("- [x] 10:00 左右 完成任务"))
        XCTAssertFalse(updated.contains("Behavior"))
    }

    func testShortDateTableImportsContentLocationAndTime() throws {
        let text = """
        # 9.17

        | checkbox | 时间 | 内容 | 地点 |
        | --- | --- | --- | --- |
        | [ ] | 08:30–09:00 | 晨练 | 健身房 |
        | [x] | 10:00 | 学习 English Tip | 书桌 |
        | [ ] |  | 整理房间 | 卧室 |
        """
        let raw: [String: Any] = [
            "today": "2026-09-17",
            "source": "9.17.md",
            "markdown": text,
            "connected": true,
            "status": "ready"
        ]

        let snapshot = try WowPlanParser.snapshot(from: raw)
        XCTAssertTrue(snapshot.isToday)
        XCTAssertEqual(snapshot.plans.count, 3)
        XCTAssertEqual(snapshot.plans.map(\.title), ["晨练", "学习 English Tip", "整理房间"])
        XCTAssertEqual(snapshot.plans.map(\.location), ["健身房", "书桌", "卧室"])
        XCTAssertEqual(snapshot.plans.map(\.startTime), ["08:30", "10:00", nil])
        XCTAssertEqual(snapshot.plans.map(\.endTime), ["09:00", nil, nil])
        XCTAssertEqual(snapshot.plans.map(\.completed), [false, true, false])
    }

    func testShortDateTableToggleChangesOnlyCompletionCell() throws {
        let filename = PlanFolderStore.filename()
        let text = """
        # \(PlanFolderStore.monthDay())

        | checkbox | 时间 | 内容 | 地点 |
        | --- | --- | --- | --- |
        | [ ] | 08:30–09:00 | 晨练 | 健身房 |
        | [ ] | 10:00 | 学习 | 书桌 |
        """
        try text.write(to: folder.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)

        let raw: [String: Any] = [
            "today": PlanFolderStore.day(Date()),
            "source": filename,
            "markdown": text,
            "connected": true,
            "status": "ready"
        ]
        let snapshot = try WowPlanParser.snapshot(from: raw)
        XCTAssertEqual(snapshot.plans.count, 2)
        _ = try store.toggle(source: try XCTUnwrap(snapshot.plans[0].source).dictionary)

        let updated = try String(contentsOf: folder.appendingPathComponent(filename), encoding: .utf8)
        XCTAssertTrue(updated.contains("| [x] | 08:30–09:00 | 晨练 | 健身房 |"))
        XCTAssertTrue(updated.contains("| [ ] | 10:00 | 学习 | 书桌 |"))
    }

    func testConnectDoesNotCreateShortDateTemplateAndDoesNotOverwriteExistingNote() throws {
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let note = folder.appendingPathComponent(PlanFolderStore.filename())
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))

        let custom = "# \(PlanFolderStore.monthDay())\n\ncustom\n"
        try custom.write(to: note, atomically: true, encoding: .utf8)
        try store.connect(folder)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), custom)
    }

    func testReadsISODateNoteInsideNestedFolder() throws {
        let nested = folder.appendingPathComponent("Daily")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let parts = PlanFolderStore.day(Date()).split(separator: "-")
        let isoFilename = "\(parts[0])-\(parts[1])-\(parts[2]).md"
        let note = nested.appendingPathComponent(isoFilename)
        try "# \(PlanFolderStore.day(Date()))\n- [ ] 08:30 起床\n".write(to: note, atomically: true, encoding: .utf8)

        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let raw = try store.read()
        XCTAssertEqual(raw["status"] as? String, "ready")
        XCTAssertEqual(raw["source"] as? String, "Daily/\(isoFilename)")
    }

    func testInlinePlanRefusesChangedSourceLineWithoutTouchingOtherCheckboxes() throws {
        let original = "- [ ] 08:30–09:00 Dev Sync"
        let changed = "# \(PlanFolderStore.day(Date()))\n- [ ] 08:30–09:00 Changed\n- [ ] 买牛奶\n"
        try changed.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "sourceLineIndex": 1,
            "sourceRawLine": original,
            "identity": original,
            "scheduleLineIndex": 1,
            "scheduleLine": original
        ]

        XCTAssertThrowsError(try store.toggle(source: source))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8), changed)
    }
    func testToggleRefusesAChangedTask() throws {
        try write("Original")
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "lineIndex": 2,
            "line": "- [ ] **Behavior：**Do the task",
            "identity": "- [ ] **Behavior：**Do the task",
            "scheduleLineIndex": 1,
            "scheduleLine": "### 00:00–23:59｜Original",
            "hasBehaviorCheckbox": true
        ]
        try "# \(PlanFolderStore.day(Date()))\n### 00:00–23:59｜Changed\n- [ ] **Behavior：**A different task\n".write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.toggle(source: source))
        XCTAssertTrue((try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)).contains("A different task"))
    }
    func testToggleInsertsAndRemovesBehaviorCheckboxWithoutChangingSectionContent() throws {
        let text = "# \(PlanFolderStore.day(Date()))\n### 10:30–11:20｜可选课程\n\n这里有完整课程说明\n- some other content\n"
        try text.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "lineIndex": 1,
            "line": "",
            "identity": "",
            "scheduleLineIndex": 1,
            "scheduleLine": "### 10:30–11:20｜可选课程",
            "hasBehaviorCheckbox": false
        ]
        _ = try store.toggle(source: source)
        let checked = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertEqual(checked, "# \(PlanFolderStore.day(Date()))\n### 10:30–11:20｜可选课程\n- [x] **Behavior：**\n\n这里有完整课程说明\n- some other content\n")

        _ = try store.toggle(source: source)
        let unchecked = try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8)
        XCTAssertEqual(unchecked, "# \(PlanFolderStore.day(Date()))\n### 10:30–11:20｜可选课程\n- [ ] **Behavior：**\n\n这里有完整课程说明\n- some other content\n")
    }
    func testToggleRefusesAmbiguousScheduleHeading() throws {
        let text = "# \(PlanFolderStore.day(Date()))\n### 10:30–11:20｜重复\n### 10:30–11:20｜重复\n"
        try text.write(to: folder.appendingPathComponent(filename()), atomically: true, encoding: .utf8)
        let store = PlanFolderStore(defaults: defaults)
        try store.connect(folder)
        let source: [String: Any] = [
            "filename": filename(),
            "scheduleLineIndex": 1,
            "scheduleLine": "### 10:30–11:20｜重复"
        ]
        XCTAssertThrowsError(try store.toggle(source: source))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(filename()), encoding: .utf8), text)
    }
    func testDatedNamesOnly() {
        XCTAssertEqual(PlanFolderStore.dateInFilename("2026年9月10日.md"), "2026-09-10")
        XCTAssertEqual(PlanFolderStore.dateInFilename("2026-09-10.md"), "2026-09-10")
        XCTAssertEqual(PlanFolderStore.dateInFilename(PlanFolderStore.filename()), PlanFolderStore.day(Date()))
        XCTAssertNil(PlanFolderStore.dateInFilename("Plan.md"))
        XCTAssertNil(PlanFolderStore.dateInFilename("2026年9月10日.md.backup"))
    }
    func testObsidianURIUsesTheSourceNoteAndPercentEncodesIt() {
        let url = ObsidianURI.url(notePath: "2026年9月11日.md")
        XCTAssertEqual(url?.absoluteString, "obsidian://open?vault=Plan&file=2026%E5%B9%B49%E6%9C%8811%E6%97%A5")
        XCTAssertEqual(ObsidianURI.url(notePath: "folder/My note & ideas.md")?.absoluteString, "obsidian://open?vault=Plan&file=folder%2FMy%20note%20%26%20ideas")
        XCTAssertEqual(ObsidianURI.url(notePath: "2026年9月11日.md", sourceHeading: "10:30–11:20｜可选课程")?.absoluteString, "obsidian://open?vault=Plan&file=2026%E5%B9%B49%E6%9C%8811%E6%97%A5%2310%3A30%E2%80%9311%3A20%EF%BD%9C%E5%8F%AF%E9%80%89%E8%AF%BE%E7%A8%8B")
        XCTAssertEqual(ObsidianURI.url(notePath: "2026年9月11日.md", sourceHeading: "Ignored", sourceBlockId: "course-1")?.absoluteString, "obsidian://open?vault=Plan&file=2026%E5%B9%B49%E6%9C%8811%E6%97%A5%23%5Ecourse-1")
        XCTAssertEqual(ObsidianURI.url(notePath: "2026年9月11日.md", sourceBlockId: "not valid")?.absoluteString, "obsidian://open?vault=Plan&file=2026%E5%B9%B49%E6%9C%8811%E6%97%A5")
        XCTAssertNil(ObsidianURI.url(notePath: "../outside.md"))
    }
}

// Reading correctness is independent of camera hardware and Photos permissions.
final class TeleprompterReadingTests: XCTestCase {
    func testFloatingLayoutRestoresWithinDifferentSafeCanvases() {
        let portrait = CGRect(x: 8, y: 8, width: 390, height: 500)
        let frame = CGRect(x: 38, y: 88, width: 240, height: 160)
        let saved = TeleprompterFloatingLayout(frame: frame, in: portrait)
        XCTAssertEqual(saved.frame(in: portrait).minX, frame.minX, accuracy: 0.001)
        XCTAssertEqual(saved.frame(in: portrait).minY, frame.minY, accuracy: 0.001)
        for canvas in [CGRect(x: 320, y: 8, width: 420, height: 310), CGRect(x: 8, y: 8, width: 160, height: 100), CGRect(x: 8, y: 8, width: 900, height: 600)] {
            let restored = saved.frame(in: canvas)
            XCTAssertTrue(canvas.contains(TeleprompterFloatingLayout.moveHandleFrame(for: restored)))
            XCTAssertGreaterThanOrEqual(restored.width, min(120, canvas.width))
            XCTAssertGreaterThanOrEqual(restored.height, min(80, canvas.height))
        }
    }

    func testFloatingLayoutCorrectsInvalidAndOutOfBoundsValues() throws {
        let canvas = CGRect(x: 8, y: 8, width: 350, height: 450)
        let invalid = try JSONDecoder().decode(TeleprompterFloatingLayout.self, from: Data("{\"x\":-100,\"y\":100,\"width\":-2,\"height\":3}".utf8))
        XCTAssertTrue(canvas.contains(TeleprompterFloatingLayout.moveHandleFrame(for: invalid.frame(in: canvas))))
        for proposed in [CGRect(x: -300, y: -500, width: 1000, height: 2000), CGRect(x: 800, y: 1000, width: 1, height: 1)] {
            XCTAssertTrue(canvas.contains(TeleprompterFloatingLayout.moveHandleFrame(for: TeleprompterFloatingLayout.clamp(proposed, to: canvas))))
        }
    }

    func testFloatingPreferencesPersistFontAndIndependentOrientationLayouts() throws {
        let suite = "teleprompter.preferences-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = CGRect(x: 8, y: 8, width: 390, height: 500)
        var preferences = TeleprompterPreferences()
        preferences.fontSize = 56
        preferences.layouts["portrait"] = TeleprompterFloatingLayout(frame: CGRect(x: 50, y: 80, width: 180, height: 90), in: canvas)
        preferences.layouts["landscapeLeading"] = TeleprompterFloatingLayout(frame: CGRect(x: 20, y: 20, width: 300, height: 300), in: canvas)
        preferences.save(to: defaults)
        XCTAssertEqual(TeleprompterPreferences.load(from: defaults), preferences)
        let size = preferences.layouts["portrait"]!.frame(in: canvas).size
        preferences.fontSize = 20
        XCTAssertEqual(preferences.layouts["portrait"]!.frame(in: canvas).size, size)
        preferences.layouts.removeAll()
        preferences.save(to: defaults)
        XCTAssertEqual(TeleprompterPreferences.load(from: defaults).fontSize, 20)
        XCTAssertTrue(TeleprompterPreferences.load(from: defaults).layouts.isEmpty)
        defaults.set(Data("invalid".utf8), forKey: TeleprompterPreferences.storageKey)
        XCTAssertEqual(TeleprompterPreferences.load(from: defaults), TeleprompterPreferences())
    }

    func testSmallWindowKeepsCurrentGlyphsWholeAndHidesClippedNeighbours() {
        for size in [12.0, 20.0, 34.0, 56.0] {
            let font = UIFont.systemFont(ofSize: size, weight: .semibold)
            let layout = TeleprompterReadingLayout(script: "One phrase\nNext phrase", fontSize: size, width: 104)
            let focus = min(80 * 0.30, layout.linePitch * 0.72) + 12
            let top = focus - font.lineHeight / 2
            XCTAssertEqual(TeleprompterReadingLayout.verticalVisibility(top: top, lineHeight: font.lineHeight, height: 80), 1)
            let nextTop = top + layout.linePitch
            let nextVisibility = TeleprompterReadingLayout.verticalVisibility(top: nextTop, lineHeight: font.lineHeight, height: 80)
            if nextTop + font.lineHeight > 80 {
                XCTAssertEqual(nextVisibility, 0)
            } else {
                // At 20 pt two whole lines fit in the minimum-height window.
                XCTAssertGreaterThan(nextVisibility, 0)
            }
            let previous = TeleprompterReadingLayout.verticalVisibility(top: top - layout.linePitch, lineHeight: font.lineHeight, height: 80)
            XCTAssertLessThan(previous * TeleprompterReadingLayout.opacity(distanceInLines: -1), 0.15)
        }
    }

    func testResizingUsesActualWidthAndRetainsWordsAtTheFocus() {
        let script = String(repeating: "Keep your eyes near the lens, and speak naturally. 我们自然地表达，不要追着文字跑。\n", count: 12)
        let source = TeleprompterReadingLayout.Source(script: script, fontSize: 56)
        let narrow = TeleprompterReadingLayout(source: source, width: 124)
        let wide = TeleprompterReadingLayout(source: source, width: 500)
        XCTAssertGreaterThan(narrow.lines.count, wide.lines.count)
        let anchor = narrow.sourcePosition(at: narrow.maximumOffset * 0.42)
        for width: CGFloat in [124, 180, 250, 350, 500, 180] {
            let layout = TeleprompterReadingLayout(source: source, width: width)
            XCTAssertEqual(layout.sourcePosition(at: layout.offset(forSourcePosition: anchor)), anchor, accuracy: 0.001)
            XCTAssertTrue(layout.lines.allSatisfy { $0.width <= width + 0.5 })
        }
        XCTAssertGreaterThan(TeleprompterReadingLayout.opacity(distanceInLines: 8), 0.5)
    }

    @MainActor
    func testNativeViewportHeightGrowthActuallyRendersMoreReadableLines() {
        let surface = TeleprompterReadingSurface(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        surface.configure(script: String(repeating: "This is the next phrase. 我们继续自然地交流。\n", count: 40), fontSize: 12, position: 0)
        surface.layoutIfNeeded()
        let original = surface.visibleLineCount
        XCTAssertGreaterThan(original, 8, "Small font must not inherit the old eight-line draw limit")
        surface.frame.size.height = 450
        surface.layoutIfNeeded()
        XCTAssertEqual(surface.bounds.height, 450)
        XCTAssertGreaterThanOrEqual(Double(surface.visibleLineCount), Double(original) * 1.4, "50% more height must yield substantially more real readable rows")
        let viewport = TeleprompterReadingViewport(size: surface.bounds.size, lineHeight: UIFont.systemFont(ofSize: 12, weight: .semibold).lineHeight, linePitch: 17, focusAtCenter: false)
        XCTAssertEqual(viewport.fadeStart, 396, accuracy: 0.001)
        XCTAssertGreaterThan(TeleprompterReadingLayout.opacity(distanceInLines: 15), 0.5)
        let progress = surface.accessibilityValue
        XCTAssertTrue(surface.accessibilityScroll(.down))
        XCTAssertNotEqual(surface.accessibilityValue, progress)
    }

    func testLegacyLayoutAndNewTwoDimensionalEdgePositionsRoundTrip() throws {
        let canvas = CGRect(x: 8, y: 8, width: 390, height: 500)
        let legacy = try JSONDecoder().decode(TeleprompterFloatingLayout.self, from: Data("{\"x\":0.3,\"y\":0.4,\"width\":0.6,\"height\":0.4}".utf8))
        let restored = legacy.frame(in: canvas)
        XCTAssertEqual(restored.minX, canvas.minX + (canvas.width - restored.width) * 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.minY, canvas.minY + (canvas.height - restored.height) * 0.4, accuracy: 0.001)
        for point in [CGPoint(x: -200, y: 8), CGPoint(x: 300, y: 430)] {
            let frame = TeleprompterFloatingLayout.clamp(CGRect(origin: point, size: CGSize(width: 320, height: 200)), to: canvas)
            let saved = TeleprompterFloatingLayout(frame: frame, in: canvas)
            let decoded = try JSONDecoder().decode(TeleprompterFloatingLayout.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(decoded.frame(in: canvas).minX, frame.minX, accuracy: 0.001)
            XCTAssertEqual(decoded.frame(in: canvas).minY, frame.minY, accuracy: 0.001)
            XCTAssertTrue(canvas.contains(TeleprompterFloatingLayout.moveHandleFrame(for: frame)))
        }
        var preferences = TeleprompterPreferences()
        let suite = "teleprompter.small-font-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.fontSize = 12
        preferences.save(to: defaults)
        XCTAssertEqual(TeleprompterPreferences.load(from: defaults).fontSize, 12)
    }

    @MainActor
    func testScreenAwakeRestoresAutomaticLockAfterRepeatedUpdates() {
        let application = UIApplication.shared
        let original = application.isIdleTimerDisabled
        defer { application.isIdleTimerDisabled = original }
        application.isIdleTimerDisabled = false
        var screenAwake = TeleprompterScreenAwake()
        screenAwake.setEnabled(true)
        screenAwake.setEnabled(true)
        XCTAssertTrue(application.isIdleTimerDisabled)
        screenAwake.setEnabled(false)
        XCTAssertFalse(application.isIdleTimerDisabled)
        screenAwake.setEnabled(true)
        XCTAssertTrue(application.isIdleTimerDisabled)
        screenAwake.setEnabled(false)
        XCTAssertFalse(application.isIdleTimerDisabled)
    }

    @MainActor
    func testScreenAwakePreservesAnotherFeaturesExistingOverride() {
        let application = UIApplication.shared
        let original = application.isIdleTimerDisabled
        defer { application.isIdleTimerDisabled = original }
        application.isIdleTimerDisabled = true
        var screenAwake = TeleprompterScreenAwake()
        screenAwake.setEnabled(true)
        screenAwake.setEnabled(false)
        XCTAssertTrue(application.isIdleTimerDisabled)
    }

    @MainActor
    func testInactiveScreenAwakeDoesNotChangeUnownedIdleTimer() {
        let application = UIApplication.shared
        let original = application.isIdleTimerDisabled
        defer { application.isIdleTimerDisabled = original }
        application.isIdleTimerDisabled = true
        var screenAwake = TeleprompterScreenAwake()
        screenAwake.setEnabled(false)
        XCTAssertTrue(application.isIdleTimerDisabled)
    }

    func testCompanionVideoHasNoAudioAndNoMicrophonePermission() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "CompanionLoopSilent", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(video.count, 1)
        XCTAssertTrue(audio.isEmpty, "The animation must have no audio track, not merely muted samples")
        XCTAssertEqual(duration.seconds, 10, accuracy: 0.05)
        let track = try XCTUnwrap(video.first)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(fps, 24, accuracy: 0.01)
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
        XCTAssertNil(Bundle.main.url(forResource: "CompanionLoop", withExtension: "mp4"))
    }

    func testCameraDoesNotAutomaticallyConfigureApplicationAudio() {
        let camera = CameraService()
        XCTAssertFalse(camera.session.automaticallyConfiguresApplicationAudioSession)
        XCTAssertTrue(camera.session.inputs.isEmpty)
    }

    func testCameraOrientationSupportsLegacyWindowAndSceneApps() {
        XCTAssertEqual(TeleprompterCameraOrientation.rotationAngle(interfaceOrientation: nil, deviceOrientation: .landscapeLeft), 180)
        XCTAssertEqual(TeleprompterCameraOrientation.rotationAngle(interfaceOrientation: nil, deviceOrientation: .landscapeRight), 0)
        XCTAssertEqual(TeleprompterCameraOrientation.rotationAngle(interfaceOrientation: .portrait, deviceOrientation: .landscapeLeft), 90)
        XCTAssertEqual(TeleprompterCameraOrientation.rotationAngle(interfaceOrientation: .landscapeLeft, deviceOrientation: .faceUp), 0)
        XCTAssertEqual(TeleprompterCameraOrientation.rotationAngle(interfaceOrientation: .unknown, deviceOrientation: .faceUp), 90)
    }

    func testNarrowColumnScalesWithDeviceAndFont() {
        XCTAssertEqual(TeleprompterReadingLayout.columnWidth(shortEdge: 390, fontSize: 34, available: 390), 296.4, accuracy: 0.001)
        XCTAssertEqual(TeleprompterReadingLayout.columnWidth(shortEdge: 1024, fontSize: 34, available: 1024), 323, accuracy: 0.001)
        XCTAssertEqual(TeleprompterReadingLayout.columnWidth(shortEdge: 390, fontSize: 20, available: 390), 190)
        XCTAssertLessThanOrEqual(TeleprompterReadingLayout.columnWidth(shortEdge: 390, fontSize: 56, available: 180), 180)
    }

    func testMixedScriptNeverLosesOrDuplicatesVisibleCharacters() {
        let script = "今天，我想分享一个改变。\n\nToday I want to show you something that completely changed the way I use my phone. 👨‍👩‍👧‍👦 café e\u{301}，继续说下去！ Supercalifragilisticexpialidocious 2026.09.30"
        for size: CGFloat in [20, 34, 56] {
            let width = TeleprompterReadingLayout.columnWidth(shortEdge: 320, fontSize: size, available: 280)
            let layout = TeleprompterReadingLayout(script: script, fontSize: size, width: width)
            let rendered = layout.lines.map { $0.text.string }.joined()
            func visible(_ text: String) -> String { text.filter { !$0.isWhitespace } }
            XCTAssertEqual(visible(rendered), visible(script))
            for line in layout.lines {
                XCTAssertLessThanOrEqual(line.width, width + 0.5, line.text.string)
                XCTAssertNotNil(Range(line.range, in: script), "A line must not split an emoji or combining character")
            }
        }
    }

    func testPunctuationAndConjunctionPreferredOverFillingWidth() {
        let chinese = TeleprompterReadingLayout(script: "今天聊手机，然后介绍新功能。", fontSize: 30, width: 240)
        XCTAssertEqual(chinese.lines.first?.text.string, "今天聊手机，")
        let english = TeleprompterReadingLayout(script: "Here is a tip that makes recording easier.", fontSize: 30, width: 230)
        XCTAssertEqual(english.lines.first?.text.string, "Here is a tip")
        XCTAssertTrue(english.lines[1].text.string.hasPrefix("that"))
    }

    func testExplicitNewlinesRemainBreaks() {
        let layout = TeleprompterReadingLayout(script: "First\n\nSecond\r\nThird", fontSize: 34, width: 240)
        XCTAssertEqual(layout.lines.map { $0.text.string }, ["First", "Second", "Third"])
    }

    func testReflowRetainsSourcePositionAndSavedStart() {
        let script = String(repeating: "你好，这是一次自然的交流。Today we talk about something new, and share it with you.\n", count: 20)
        let old = TeleprompterReadingLayout(script: script, fontSize: 34, width: 234)
        let saved = old.sourcePosition(at: old.maximumOffset * 0.47)
        for (size, width): (CGFloat, CGFloat) in [(20, 144), (56, 192), (34, 180)] {
            let new = TeleprompterReadingLayout(script: script, fontSize: size, width: width)
            let offset = new.offset(forSourcePosition: saved)
            XCTAssertEqual(new.sourcePosition(at: offset), saved, accuracy: 0.001)
            XCTAssertGreaterThan(offset, 0)
            XCTAssertLessThan(offset, new.maximumOffset)
        }
    }

    func testFinalLineStopsInsideFocusAndShortScriptIsReadable() {
        let single = TeleprompterReadingLayout(script: "你好", fontSize: 34, width: 240)
        XCTAssertEqual(single.lines.count, 1)
        XCTAssertEqual(single.maximumOffset, 0)
        let layout = TeleprompterReadingLayout(script: "第一句\n最后一句", fontSize: 34, width: 240)
        XCTAssertEqual(layout.maximumOffset, layout.linePitch)
        XCTAssertEqual(layout.offset(forSourcePosition: 1_000_000), layout.maximumOffset)
        XCTAssertEqual(layout.sourcePosition(at: layout.maximumOffset), Double(layout.lines.last!.range.location))
        XCTAssertEqual(TeleprompterReadingLayout.opacity(distanceInLines: 0), 1)
    }

    func testFocusEmphasizesCurrentLineWithoutHidingUpcomingContent() {
        XCTAssertEqual(TeleprompterReadingLayout.opacity(distanceInLines: 0), 1)
        XCTAssertGreaterThan(TeleprompterReadingLayout.opacity(distanceInLines: 1), TeleprompterReadingLayout.opacity(distanceInLines: -1))
        XCTAssertLessThan(TeleprompterReadingLayout.opacity(distanceInLines: 1), 1)
        XCTAssertGreaterThan(TeleprompterReadingLayout.opacity(distanceInLines: 3), 0.5)
        XCTAssertGreaterThan(TeleprompterReadingLayout.opacity(distanceInLines: 20), 0.5)
        XCTAssertEqual(TeleprompterReadingLayout.opacity(distanceInLines: -2), 0)
    }

    func testEmptyAndWhitespaceOnlyScriptIsSafe() {
        for script in ["", " \n\r\n\t"] {
            let layout = TeleprompterReadingLayout(script: script, fontSize: 34, width: 240)
            XCTAssertTrue(layout.lines.isEmpty)
            XCTAssertEqual(layout.maximumOffset, 0)
            XCTAssertEqual(layout.sourcePosition(at: 100), 0)
            XCTAssertEqual(layout.offset(forSourcePosition: 100), 0)
        }
    }
}


@MainActor
private final class TestReminderClient: ReminderNotificationClient {
    var status: UNAuthorizationStatus = .authorized
    var prompts = 0
    var grant = true
    var requests: [String: UNNotificationRequest] = [:]
    var removed: [String] = []
    var failAdds = false
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        prompts += 1
        status = grant ? .authorized : .denied
        return grant
    }
    func pendingRequests() async -> [UNNotificationRequest] { Array(requests.values) }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: UNNotificationRequest) async throws {
        if failAdds { throw NSError(domain: "Test", code: 1) }
        requests[request.identifier] = request
    }
    func removePending(_ identifiers: [String]) {
        removed += identifiers
        for id in identifiers { requests[id] = nil }
    }
    func removeDelivered(_ identifiers: [String]) {}
}

@MainActor
final class ReminderTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func account(_ day: Int, enabled: Bool = true, active: Bool = true) -> BookAccount {
        BookAccount(id: "cmb", name: "信用卡", type: .creditCard, openingBalanceCents: 951205,
            providerName: "招商银行", dueAmountCents: 951205, repaymentDay: day,
            repaymentReminderEnabled: enabled, isActive: active)
    }

    func testPlanScheduleEditCancelAndNamespaces() async throws {
        let client = TestReminderClient()
        let scheduler = ReminderNotifications(client: client)
        let first = Date().addingTimeInterval(120)
        let plan = try XCTUnwrap(ReminderNotifications.planRequest(id: "test", title: "Test Plan", date: first))
        let debts = ReminderNotifications.repaymentRequests(accounts: [account(7)])
        let debtOK = await scheduler.replace(prefix: "repayment-reminder-", requests: debts)
        XCTAssertTrue(debtOK)
        let planOK = await scheduler.replace(prefix: "plan-reminder-", requests: [plan])
        XCTAssertTrue(planOK)
        let changed = try XCTUnwrap(ReminderNotifications.planRequest(id: "test", title: "Test Plan", date: first.addingTimeInterval(180)))
        _ = await scheduler.replace(prefix: "plan-reminder-", requests: [changed])
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.removed.contains("plan-reminder-test"))
        let trigger = try XCTUnwrap(client.requests["plan-reminder-test"]?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.minute, Calendar.current.component(.minute, from: first.addingTimeInterval(180)))
        _ = await scheduler.replace(prefix: "plan-reminder-", requests: [])
        XCTAssertNil(client.requests["plan-reminder-test"])
        XCTAssertNotNil(client.requests["repayment-reminder-cmb"])
    }

    func testRepaymentEditDisableArchiveAndDeletionCancel() async throws {
        let client = TestReminderClient()
        let scheduler = ReminderNotifications(client: client)
        _ = await ReminderNotifications.synchronizeRepayments([account(7)], scheduler: scheduler)
        var trigger = try XCTUnwrap(client.requests["repayment-reminder-cmb"]?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.day, 7)
        XCTAssertEqual(trigger.dateComponents.hour, 9)
        XCTAssertEqual(client.requests["repayment-reminder-cmb"]?.content.body, "招商银行信用卡今天是还款日")
        _ = await ReminderNotifications.synchronizeRepayments([account(10)], scheduler: scheduler)
        trigger = try XCTUnwrap(client.requests["repayment-reminder-cmb"]?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.day, 10)
        _ = await ReminderNotifications.synchronizeRepayments([account(10, enabled: false)], scheduler: scheduler)
        XCTAssertTrue(client.requests.isEmpty)
        _ = await ReminderNotifications.synchronizeRepayments([account(31)], scheduler: scheduler)
        XCTAssertEqual(client.requests.count, 15)
        _ = await ReminderNotifications.synchronizeRepayments([account(31, active: false)], scheduler: scheduler)
        XCTAssertTrue(client.requests.isEmpty)
        _ = await ReminderNotifications.synchronizeRepayments([account(31)], scheduler: scheduler)
        _ = await ReminderNotifications.synchronizeRepayments([], scheduler: scheduler)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testMonthEndCalendarTriggersAndLeapYears() throws {
        for day in 29...31 {
            let requests = ReminderNotifications.repaymentRequests(accounts: [account(day)], now: date(2027, 1, 1))
            XCTAssertEqual(requests.count, 15)
            let april = try XCTUnwrap(requests.first { $0.identifier.hasSuffix("month-4") }?.trigger as? UNCalendarNotificationTrigger)
            XCTAssertEqual(april.dateComponents.day, min(day, 30))
            XCTAssertTrue(april.repeats)
            let february = requests.filter { $0.identifier.contains("february") }.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
            XCTAssertEqual(february.count, 4)
            XCTAssertEqual(february.map { $0.dateComponents.day! }, [28, 29, 28, 28])
            for trigger in february { XCTAssertNotNil(trigger.nextTriggerDate()) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let next = try XCTUnwrap(MonthlyRepaymentDate.next(day: day, after: date(2026, 2, 1), calendar: calendar))
            XCTAssertEqual(calendar.component(.day, from: next), 28)
            let leap = try XCTUnwrap(MonthlyRepaymentDate.next(day: day, after: date(2028, 2, 1), calendar: calendar))
            XCTAssertEqual(calendar.component(.day, from: leap), 29)
        }
    }

    func testPermissionDeniedDoesNotPromptRepeatedlyOrSchedule() async {
        let client = TestReminderClient()
        client.status = .notDetermined
        client.grant = false
        let scheduler = ReminderNotifications(client: client)
        let passive = await scheduler.checkPermission()
        XCTAssertFalse(passive)
        XCTAssertEqual(client.prompts, 0)
        let first = await scheduler.checkPermission(requestIfNeeded: true)
        let second = await scheduler.checkPermission(requestIfNeeded: true)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(client.prompts, 1)
        let result = await scheduler.replace(prefix: "repayment-reminder-", requests: ReminderNotifications.repaymentRequests(accounts: [account(7)]))
        XCTAssertFalse(result)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(scheduler.message.isEmpty)
    }

    func testCapacityAndNativeFailureLeaveNoOldSchedule() async {
        let client = TestReminderClient()
        let scheduler = ReminderNotifications(client: client)
        _ = await ReminderNotifications.synchronizeRepayments([account(7)], scheduler: scheduler)
        client.failAdds = true
        let result = await ReminderNotifications.synchronizeRepayments([account(10)], scheduler: scheduler)
        XCTAssertFalse(result)
        XCTAssertTrue(client.requests.isEmpty)
        client.failAdds = false
        for number in 0..<64 {
            let request = ReminderNotifications.planRequest(id: "\(number)", title: "Plan", date: Date().addingTimeInterval(600))!
            client.requests[request.identifier] = request
        }
        let capacity = await ReminderNotifications.synchronizeRepayments([account(7)], scheduler: scheduler)
        XCTAssertFalse(capacity)
        XCTAssertEqual(client.requests.count, 64)
    }

    func testPlanPersistenceRestartCompletionDeletionAndImportedIdentity() async throws {
        let suite = "Wow.ReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = TestReminderClient()
        let scheduler = ReminderNotifications(client: client)
        let persistence = WowPersistence(defaults: defaults)
        let item = WowItem(id: "test-plan", title: "Test Plan")
        let state = WowLocalState(plans: [item], shopping: [], ideas: [])
        persistence.save(state: state, archived: [])
        let service = WowPlanService(store: PlanFolderStore(defaults: defaults))
        let store = WowHomeStore(state: state, archived: [], persistence: persistence, planService: service, notifications: scheduler)
        let reminder = Date().addingTimeInterval(120)
        let saved = await store.setPlanReminder(item, date: reminder)
        XCTAssertTrue(saved)
        let restored = WowHomeStore(state: persistence.loadState(), archived: [], persistence: persistence, planService: service, notifications: scheduler)
        XCTAssertEqual(restored.planReminders[item.id], reminder)
        _ = await restored.synchronizePlanReminders()
        XCTAssertEqual(client.requests.count, 1)
        restored.toggleLocal(section: .plans, item: item)
        _ = await restored.synchronizePlanReminders(prune: true)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertNil(persistence.loadPlanReminders()[item.id])
        restored.toggleLocal(section: .plans, item: item)
        _ = await restored.setPlanReminder(item, date: reminder)
        restored.remove(section: .plans, item: item)
        _ = await restored.synchronizePlanReminders(prune: true)
        XCTAssertTrue(client.requests.isEmpty)

        let today = PlanFolderStore.day(Date())
        func parse(_ markdown: String) throws -> [WowItem] {
            try WowPlanParser.snapshot(from: ["today": today, "source": "\(today).md", "markdown": "# \(today)\n" + markdown, "connected": true, "status": "ready"]).plans
        }
        let before = try parse("- [ ] 10:00 Application\n")
        let moved = try parse("A new paragraph\n- [ ] 10:00 Application\n")
        let completed = try parse("- [x] 10:00 Application\n")
        XCTAssertEqual(before.first?.id, moved.first?.id)
        XCTAssertEqual(before.first?.id, completed.first?.id)
    }

    func testNativeCenterScheduleEditRemoveAndRepaymentCalendar() async throws {
        let client = NativeReminderNotificationClient()
        let status = await client.authorizationStatus()
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            throw XCTSkip("Enable notification permission using the UI acceptance test before this native integration check.")
        }
        let scheduler = ReminderNotifications(client: client)
        let id = "qa-" + UUID().uuidString
        let prefix = "plan-reminder-" + id
        let initial = ReminderNotifications.planRequest(id: id, title: "Native QA", date: Date().addingTimeInterval(120))!
        let scheduled = await scheduler.replace(prefix: prefix, requests: [initial])
        XCTAssertTrue(scheduled)
        var pending = await client.pendingRequests().filter { $0.identifier == prefix }
        XCTAssertEqual(pending.count, 1)
        let updated = ReminderNotifications.planRequest(id: id, title: "Native QA", date: Date().addingTimeInterval(240))!
        let rescheduled = await scheduler.replace(prefix: prefix, requests: [updated])
        XCTAssertTrue(rescheduled)
        pending = await client.pendingRequests().filter { $0.identifier == prefix }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual((pending.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents,
            (updated.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        _ = await scheduler.replace(prefix: prefix, requests: [])
        pending = await client.pendingRequests().filter { $0.identifier == prefix }
        XCTAssertTrue(pending.isEmpty)

        var card = account(7)
        card.id = id
        let debtPrefix = "repayment-reminder-" + id
        _ = await scheduler.replace(prefix: debtPrefix, requests: ReminderNotifications.repaymentRequests(accounts: [card]))
        var nativeMonthly = await client.pendingRequests().filter { $0.identifier.hasPrefix(debtPrefix) }
        XCTAssertEqual(nativeMonthly.count, 1)
        XCTAssertEqual((nativeMonthly.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents.day, 7)
        card.repaymentDay = 10
        _ = await scheduler.replace(prefix: debtPrefix, requests: ReminderNotifications.repaymentRequests(accounts: [card]))
        nativeMonthly = await client.pendingRequests().filter { $0.identifier.hasPrefix(debtPrefix) }
        XCTAssertEqual(nativeMonthly.count, 1)
        XCTAssertEqual((nativeMonthly.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents.day, 10)
        card.repaymentDay = 31
        let debts = ReminderNotifications.repaymentRequests(accounts: [card])
        let debtScheduled = await scheduler.replace(prefix: debtPrefix, requests: debts)
        XCTAssertTrue(debtScheduled)
        let nativeDebts = await client.pendingRequests().filter { $0.identifier.hasPrefix(debtPrefix) }
        XCTAssertEqual(nativeDebts.count, 15)
        XCTAssertTrue(nativeDebts.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() != nil })
        _ = await scheduler.replace(prefix: debtPrefix, requests: [])
        let remaining = await client.pendingRequests().filter { $0.identifier.hasPrefix(debtPrefix) }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacySQLiteMigrationAndBackupRoundTripPreserveAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("counter.sqlite")
        let original = try LocalStore(databaseURL: url)
        let oldDate = date(2026, 10, 7)
        let legacy = BookAccount(id: "legacy-card", name: "招商银行信用卡", type: .creditCard,
            openingBalanceCents: 951205, nextDueDate: oldDate)
        try await original.save(legacy)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "ALTER TABLE accounts DROP COLUMN repayment_day; ALTER TABLE accounts DROP COLUMN repayment_reminder_enabled; PRAGMA user_version=13;", nil, nil, nil), SQLITE_OK)
        let migrated = try LocalStore(databaseURL: url)
        let result = try await migrated.account(id: legacy.id)
        XCTAssertEqual(result?.repaymentDay, 7)
        XCTAssertTrue(result?.repaymentReminderIsEnabled == true)
        XCTAssertEqual(result?.openingBalanceCents, 951205)
        XCTAssertEqual(result?.nextDueDate, oldDate)
        XCTAssertEqual(result!.createdAt.timeIntervalSince1970, legacy.createdAt.timeIntervalSince1970, accuracy: 0.000001)
        var edited = try XCTUnwrap(result)
        edited.nextDueDate = nil
        edited.repaymentDay = 31
        edited.repaymentReminderEnabled = false
        try await migrated.save(edited)
        let reopened = try LocalStore(databaseURL: url)
        let reopenedAccount = try await reopened.account(id: legacy.id)
        XCTAssertEqual(reopenedAccount?.repaymentDay, 31)
        XCTAssertFalse(reopenedAccount?.repaymentReminderIsEnabled ?? true)
        let backup = try await reopened.backup()
        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(CounterBackup.self, from: data)
        XCTAssertEqual(decoded.accounts?.first?.repaymentDay, 31)
        XCTAssertEqual(decoded.accounts?.first?.openingBalanceCents, 951205)
        let restored = try LocalStore(databaseURL: directory.appendingPathComponent("restored.sqlite"))
        try await restored.restore(decoded, replace: true)
        let restoredAccount = try await restored.account(id: legacy.id)
        XCTAssertEqual(restoredAccount?.repaymentDay, 31)
        XCTAssertFalse(restoredAccount?.repaymentReminderIsEnabled ?? true)
    }
}

extension PlanTests {
    @MainActor
    func testPictureCanvasZoomKeepsImageCoordinatesAndResetsViewport() {
        let controller = ImageCanvasZoomController(content: Color.clear)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
        controller.viewDidLayoutSubviews()
        let scroll = controller.scrollView
        XCTAssertEqual(scroll.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(scroll.maximumZoomScale, 8)
        scroll.setZoomScale(3, animated: false)
        scroll.setContentOffset(CGPoint(x: 120, y: 180), animated: false)
        let original = CGPoint(x: 100, y: 140)
        let screen = controller.host.view.convert(original, to: controller.view)
        XCTAssertEqual(screen.x, 180, accuracy: 0.1)
        XCTAssertEqual(screen.y, 240, accuracy: 0.1)
        let restored = controller.host.view.convert(screen, from: controller.view)
        XCTAssertEqual(restored.x, original.x, accuracy: 0.1)
        XCTAssertEqual(restored.y, original.y, accuracy: 0.1)
        // Normal content updates must not reset the user's zoom/pan position.
        controller.host.rootView = Color.red
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(scroll.zoomScale, 3)
        XCTAssertEqual(scroll.contentOffset.x, 120, accuracy: 0.1)
        controller.resetZoom()
        XCTAssertEqual(scroll.zoomScale, 1)
        XCTAssertEqual(scroll.contentOffset, .zero)
    }
}
