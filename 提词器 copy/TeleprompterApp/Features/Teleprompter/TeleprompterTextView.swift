import CoreText
import SwiftUI
import UIKit

// Source coordinates retain the words being read across font/width changes.
struct TeleprompterReadingLayout {
    struct Line {
        let range: NSRange
        let text: NSAttributedString
        let width: CGFloat
    }

    let lines: [Line]
    let linePitch: CGFloat
    var maximumOffset: CGFloat { CGFloat(max(0, lines.count - 1)) * linePitch }

    static func columnWidth(shortEdge: CGFloat, fontSize: CGFloat, available: CGFloat) -> CGFloat {
        max(1, min(available, shortEdge * 0.76, fontSize * 9.5))
    }

    // Reuse shaped text and phrase boundaries throughout a live resize.
    final class Source {
        let text: NSString
        let font: UIFont
        let attributes: [NSAttributedString.Key: Any]
        let typesetter: CTTypesetter
        let boundaries: [Int]

        init(script: String, fontSize: CGFloat) {
            font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            attributes = [.font: font, .foregroundColor: UIColor.white]
            text = script as NSString
            typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: script, attributes: attributes))
            let punctuation = CharacterSet(charactersIn: "，。？！；：、,!?;:")
            let conjunctions: Set<String> = ["and", "but", "or", "because", "that", "which", "when", "while", "so"]
            var phraseBoundaries = Set<Int>()
            script.enumerateSubstrings(in: script.startIndex..., options: .byComposedCharacterSequences) { part, range, _, _ in
                guard let part else { return }
                if part.unicodeScalars.contains(where: { punctuation.contains($0) }) || part == "." {
                    phraseBoundaries.insert(NSMaxRange(NSRange(range, in: script)))
                }
            }
            script.enumerateSubstrings(in: script.startIndex..., options: .byWords) { word, range, _, _ in
                if let word, conjunctions.contains(word.lowercased()) {
                    phraseBoundaries.insert(NSRange(range, in: script).location)
                }
            }
            boundaries = phraseBoundaries.sorted()
        }
    }

    init(script: String, fontSize: CGFloat, width: CGFloat) {
        self.init(source: Source(script: script, fontSize: fontSize), width: width)
    }

    init(source prepared: Source, width: CGFloat) {
        linePitch = ceil(prepared.font.lineHeight + prepared.font.pointSize * 0.20)
        let source = prepared.text
        let typesetter = prepared.typesetter
        let attributes = prepared.attributes
        let boundaries = prepared.boundaries
        var boundaryIndex = 0
        var result: [Line] = []
        var start = 0
        while start < source.length {
            let cluster = source.rangeOfComposedCharacterSequence(at: start)
            if source.substring(with: cluster).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                start = NSMaxRange(cluster)
                continue
            }
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            var end = min(source.length, start + max(cluster.length, suggested))
            while boundaryIndex < boundaries.count && boundaries[boundaryIndex] <= start { boundaryIndex += 1 }
            var candidateIndex = boundaryIndex
            var preferred: Int?
            while candidateIndex < boundaries.count && boundaries[candidateIndex] <= end {
                let boundary = boundaries[candidateIndex]
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: boundary - start))
                if CTLineGetTypographicBounds(line, nil, nil, nil) >= Double(width * 0.45) {
                    preferred = boundary
                }
                candidateIndex += 1
            }
            if let preferred { end = preferred }
            let range = NSRange(location: start, length: end - start)
            let visible = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty {
                let text = NSAttributedString(string: visible, attributes: attributes)
                let line = CTLineCreateWithAttributedString(text)
                result.append(Line(range: range, text: text, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            }
            start = end
        }
        lines = result
    }

    func sourcePosition(at offset: CGFloat) -> Double {
        guard !lines.isEmpty else { return 0 }
        let linePosition = min(CGFloat(lines.count - 1), max(0, offset / linePitch))
        let index = Int(linePosition)
        let start = lines[index].range.location
        guard index + 1 < lines.count else { return Double(start) }
        return Double(start) + Double(linePosition - CGFloat(index)) * Double(lines[index + 1].range.location - start)
    }

    func offset(forSourcePosition position: Double) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if Double(lines[middle].range.location) <= position { lower = middle + 1 }
            else { upper = middle }
        }
        let index = max(0, lower - 1)
        guard index + 1 < lines.count else { return maximumOffset }
        let start = Double(lines[index].range.location)
        let length = Double(lines[index + 1].range.location) - start
        return (CGFloat(index) + CGFloat(min(1, max(0, (position - start) / length)))) * linePitch
    }

    static func verticalVisibility(top: CGFloat, lineHeight: CGFloat, height: CGFloat) -> CGFloat {
        // Fade before clipping a glyph. A one-line window should show one
        // complete line, rather than fragments of the next line at its edge.
        let space = min(top, height - top - lineHeight)
        let fade = min(8, max(2, (height - lineHeight) * 0.15))
        return min(1, max(0, space / fade))
    }

    static func opacity(distanceInLines distance: CGFloat) -> CGFloat {
        let magnitude = abs(distance)
        if magnitude <= 0.28 { return 1 }
        if distance < 0 {
            let remaining = max(0, 1 - (magnitude - 0.28) / (1.15 - 0.28))
            return remaining * remaining
        }
        // Focus is emphasis, not a cutoff for upcoming content.
        return 0.60 + 0.40 * max(0, 1 - (magnitude - 0.28) / 0.90)
    }
}

// Every drawing dimension comes from the reading surface's current bounds.
struct TeleprompterReadingViewport {
    struct Row {
        let index: Int
        let top: CGFloat
        let opacity: CGFloat
    }

    let size: CGSize
    let lineHeight: CGFloat
    let linePitch: CGFloat
    let focusY: CGFloat
    var fadeStart: CGFloat { size.height * 0.88 }

    init(size: CGSize, lineHeight: CGFloat, linePitch: CGFloat, focusAtCenter: Bool) {
        self.size = size
        self.lineHeight = lineHeight
        self.linePitch = linePitch
        focusY = focusAtCenter ? size.height / 2 : min(size.height * 0.30, linePitch * 0.72) + 12
    }

    func rows(lineCount: Int, offset: CGFloat) -> [Row] {
        guard size.height > 0, linePitch > 0, lineCount > 0 else { return [] }
        let first = max(0, Int(floor(offset / linePitch)) - 1)
        let last = min(lineCount, max(first, Int(ceil((offset + size.height - focusY + lineHeight / 2) / linePitch)) + 1))
        return (first..<last).compactMap { index in
            let distance = (CGFloat(index) * linePitch - offset) / linePitch
            let top = focusY + distance * linePitch - lineHeight / 2
            let edge = TeleprompterReadingLayout.verticalVisibility(top: top, lineHeight: lineHeight, height: size.height)
            let bottomFade = min(1, max(0, (size.height - top - lineHeight / 2) / max(1, size.height - fadeStart)))
            let opacity = TeleprompterReadingLayout.opacity(distanceInLines: distance) * edge * bottomFade
            return opacity > 0 ? Row(index: index, top: top, opacity: opacity) : nil
        }
    }
}

struct TeleprompterTextView: UIViewRepresentable {
    let script: String
    let fontSize: Double
    let focusAtCenter: Bool
    let scrollSpeed: Double
    let isScrolling: Bool
    let windowFrame: CGRect
    let canvas: CGRect
    let showsLayoutControls: Bool
    @Binding var position: Double
    let onManualScrollChanged: (Bool) -> Void
    let onReachedEnd: () -> Void
    let onFrameChanged: (CGRect) -> Void
    let onLayoutInteractionChanged: (Bool) -> Void

    func makeUIView(context: Context) -> TeleprompterFloatingSurface {
        TeleprompterFloatingSurface()
    }

    func updateUIView(_ container: TeleprompterFloatingSurface, context: Context) {
        let view = container.reading
        container.onFrameChanged = onFrameChanged
        container.onLayoutInteractionChanged = onLayoutInteractionChanged
        container.configureWindow(frame: windowFrame, canvas: canvas)
        container.setControlsPinned(showsLayoutControls)
        view.onPositionChanged = { position = $0 }
        view.onManualScrollChanged = onManualScrollChanged
        view.onReachedEnd = onReachedEnd
        view.configure(script: script, fontSize: fontSize, position: position)
        view.focusAtCenter = focusAtCenter
        view.scrollSpeed = scrollSpeed
        view.setPlaying(isScrolling)
    }

    static func dismantleUIView(_ view: TeleprompterFloatingSurface, coordinator: ()) {
        view.stop()
    }
}

final class TeleprompterFloatingSurface: UIView, UIGestureRecognizerDelegate {
    let reading = TeleprompterReadingSurface()
    var windowFrame = CGRect.zero
    var canvas = CGRect.zero
    var onFrameChanged: ((CGRect) -> Void)?
    var onLayoutInteractionChanged: ((Bool) -> Void)?

    private let handle = UIButton(type: .custom)
    private let moveHandle = UIButton(type: .custom)
    private let moveIndicator = UIView()
    private var initialFrame = CGRect.zero
    private var adjusting = false
    private var controlsPinned = false
    private var hideWork: DispatchWorkItem?
    private lazy var moveGesture = UIPanGestureRecognizer(target: self, action: #selector(moveWindow(_:)))
    private lazy var resizeGesture = UIPanGestureRecognizer(target: self, action: #selector(resize(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "teleprompterWindow"
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        addSubview(reading)
        addSubview(handle)
        addSubview(moveHandle)
        moveHandle.accessibilityIdentifier = "teleprompterMoveHandle"
        moveHandle.accessibilityLabel = "移动提词窗口"
        moveHandle.accessibilityHint = "拖动顶部柄，自由改变左右和上下位置"
        moveIndicator.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        moveIndicator.layer.cornerRadius = 1.5
        moveIndicator.isUserInteractionEnabled = false
        moveHandle.addSubview(moveIndicator)
        moveHandle.addGestureRecognizer(moveGesture)
        moveHandle.addTarget(self, action: #selector(revealControls), for: .touchUpInside)
        reading.onVisibleLineCountChanged = { [weak self] count in
            self?.moveHandle.accessibilityValue = "可读 \(count) 行"
        }
        handle.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)), for: .normal)
        handle.tintColor = UIColor.white.withAlphaComponent(0.70)
        handle.accessibilityIdentifier = "teleprompterResizeHandle"
        handle.accessibilityLabel = "调整提词区域大小"
        handle.accessibilityHint = "拖动右下角，自由调整宽度和高度"
        handle.addGestureRecognizer(resizeGesture)
        handle.addTarget(self, action: #selector(revealControls), for: .touchUpInside)
        // Three sibling hit regions: header moves, body scrolls, corner resizes.
        // No long-press or gesture failure delay in the manuscript itself.
        let tap = UITapGestureRecognizer(target: self, action: #selector(revealControls))
        tap.delegate = self
        tap.require(toFail: reading.scrollPan)
        addGestureRecognizer(tap)
        revealControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        reading.frame = bounds
        handle.frame = CGRect(x: max(0, bounds.width - 44), y: max(0, bounds.height - 44), width: 44, height: 44)
        moveHandle.frame = TeleprompterFloatingLayout.moveHandleFrame(for: bounds)
        moveIndicator.frame = CGRect(x: moveHandle.bounds.midX - 12, y: 4, width: 24, height: 3)
    }

    func setControlsPinned(_ pinned: Bool) {
        guard controlsPinned != pinned else { return }
        controlsPinned = pinned
        revealControls()
    }

    func configureWindow(frame: CGRect, canvas: CGRect) {
        if self.canvas != canvas && adjusting {
            // Rotation or changing available space cancels the old coordinate
            // gesture before applying the new, corrected relative layout.
            moveGesture.isEnabled = false
            resizeGesture.isEnabled = false
            moveGesture.isEnabled = true
            resizeGesture.isEnabled = true
        }
        windowFrame = frame
        self.canvas = canvas
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The handle's own recognizer never competes with move/tap/scroll.
        ![handle, moveHandle].contains { touch.view === $0 || touch.view?.isDescendant(of: $0) == true }
    }

    @objc private func revealControls() {
        hideWork?.cancel()
        handle.isHidden = false
        moveHandle.isHidden = false
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        guard !controlsPinned, !adjusting else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.adjusting, !self.controlsPinned else { return }
            self.handle.isHidden = true
            self.moveHandle.isHidden = true
            self.layer.borderColor = UIColor.clear.cgColor
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func beginAdjustment() {
        adjusting = true
        initialFrame = windowFrame
        reading.beginLayoutAdjustment()
        onLayoutInteractionChanged?(true)
        revealControls()
    }

    private func finishAdjustment() {
        guard adjusting else { return }
        adjusting = false
        onLayoutInteractionChanged?(false)
        revealControls()
    }

    @objc private func moveWindow(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { beginAdjustment() }
        if gesture.state == .began || gesture.state == .changed {
            let delta = gesture.translation(in: window)
            let proposed = initialFrame.offsetBy(dx: delta.x, dy: delta.y)
            onFrameChanged?(TeleprompterFloatingLayout.clamp(proposed, to: canvas))
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { finishAdjustment() }
    }

    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { beginAdjustment() }
        if gesture.state == .began || gesture.state == .changed {
            let delta = gesture.translation(in: window)
            // Keep the top-left anchor unless correction is needed to keep
            // the move handle reachable at an extreme edge.
            let width = min(canvas.width, max(min(120, canvas.width), initialFrame.width + delta.x))
            let height = min(canvas.height, max(min(80, canvas.height), initialFrame.height + delta.y))
            let proposed = CGRect(origin: initialFrame.origin, size: CGSize(width: width, height: height))
            onFrameChanged?(TeleprompterFloatingLayout.clamp(proposed, to: canvas))
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { finishAdjustment() }
    }

    func stop() {
        hideWork?.cancel()
        reading.stopDisplayLink()
    }
}

final class TeleprompterReadingSurface: UIView {
    var onPositionChanged: ((Double) -> Void)?
    var onManualScrollChanged: ((Bool) -> Void)?
    var onReachedEnd: (() -> Void)?
    var onVisibleLineCountChanged: ((Int) -> Void)?
    var scrollSpeed = 18.0
    var focusAtCenter = false {
        didSet {
            if oldValue != focusAtCenter {
                updateAccessibilityProgress()
                setNeedsDisplay()
            }
        }
    }

    private var script = ""
    private var fontSize = 34.0
    private var readingLayout: TeleprompterReadingLayout?
    private var layoutSource: TeleprompterReadingLayout.Source?
    private var layoutWidth: CGFloat = 0
    private var offset: CGFloat = 0
    private var reportedPosition = 0.0
    private var requestedPosition = 0.0
    private var dragStart: CGFloat = 0
    private var isDragging = false
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var lastReportTime: CFTimeInterval = 0
    private var reportedVisibleLineCount = -1
    private(set) lazy var scrollPan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityIdentifier = "teleprompterText"
        accessibilityLabel = "滚动台词"
        accessibilityHint = "滑动调整台词；点击显示顶部移动柄和右下角大小调节柄"
        accessibilityTraits = .allowsDirectInteraction
        addGestureRecognizer(scrollPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(script: String, fontSize: Double, position: Double) {
        if self.script != script || self.fontSize != fontSize {
            requestedPosition = readingLayout?.sourcePosition(at: offset) ?? requestedPosition
            self.script = script
            self.fontSize = fontSize
            readingLayout = nil
            layoutSource = nil
            setNeedsLayout()
        }
        if position != reportedPosition {
            requestedPosition = position
            reportedPosition = position
            if let readingLayout { offset = readingLayout.offset(forSourcePosition: position) }
            updateAccessibilityProgress()
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, bounds.width - 16)
        if readingLayout == nil || width != layoutWidth {
            let position = readingLayout?.sourcePosition(at: offset) ?? requestedPosition
            let source = layoutSource ?? TeleprompterReadingLayout.Source(script: script, fontSize: fontSize)
            layoutSource = source
            let newLayout = TeleprompterReadingLayout(source: source, width: width)
            readingLayout = newLayout
            layoutWidth = width
            offset = newLayout.offset(forSourcePosition: position)
        }
        updateAccessibilityProgress()
        setNeedsDisplay()
    }

    private var viewport: TeleprompterReadingViewport? {
        guard let readingLayout, let layoutSource else { return nil }
        return TeleprompterReadingViewport(size: bounds.size, lineHeight: layoutSource.font.lineHeight, linePitch: readingLayout.linePitch, focusAtCenter: focusAtCenter)
    }

    var visibleLineCount: Int {
        guard let viewport, let readingLayout else { return 0 }
        return viewport.rows(lineCount: readingLayout.lines.count, offset: offset).filter { $0.opacity >= 0.15 }.count
    }

    override func draw(_ rect: CGRect) {
        guard let readingLayout, let viewport, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let colors = [UIColor.black.withAlphaComponent(0.44).cgColor, UIColor.black.withAlphaComponent(0.62).cgColor, UIColor.black.withAlphaComponent(0.44).cgColor, UIColor.clear.cgColor] as CFArray
        let focusFraction = min(0.80, max(0.10, viewport.focusY / max(1, viewport.size.height)))
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, focusFraction, 0.88, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: viewport.size.width / 2, y: 0), end: CGPoint(x: viewport.size.width / 2, y: viewport.size.height), options: [])
        }
        let edgeColors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor] as CFArray
        if let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: edgeColors, locations: [0, 0.12, 0.88, 1]) {
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(fade, start: .zero, end: CGPoint(x: viewport.size.width, y: 0), options: [])
        }
        context.endTransparencyLayer()
        context.restoreGState()
        // Draw every visible row; no fixed row budget or phrase-distance cutoff.
        for row in viewport.rows(lineCount: readingLayout.lines.count, offset: offset) {
            let line = readingLayout.lines[row.index]
            context.saveGState()
            context.setAlpha(row.opacity)
            line.text.draw(at: CGPoint(x: (viewport.size.width - line.width) / 2, y: row.top))
            context.restoreGState()
        }
    }

    func setPlaying(_ playing: Bool) {
        if playing && displayLink == nil {
            let target = TeleprompterDisplayLinkTarget(surface: self)
            let link = CADisplayLink(target: target, selector: #selector(TeleprompterDisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        let paused = !playing || isDragging
        if displayLink?.isPaused != paused {
            displayLink?.isPaused = paused
            lastTimestamp = nil
        }
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    func beginLayoutAdjustment() {
        setPlaying(false)
        publishPosition()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let readingLayout, !isDragging else { lastTimestamp = nil; return }
        defer { lastTimestamp = link.timestamp }
        guard let previous = lastTimestamp else { return }
        // No catch-up leap after an interrupted frame or background transition.
        let elapsed = min(1.0 / 15.0, max(0, link.timestamp - previous))
        offset = min(readingLayout.maximumOffset, offset + scrollSpeed * elapsed)
        setNeedsDisplay()
        let atEnd = offset >= readingLayout.maximumOffset
        if atEnd || link.timestamp - lastReportTime >= 0.10 {
            publishPosition()
            lastReportTime = link.timestamp
        }
        if atEnd {
            link.isPaused = true
            onReachedEnd?()
        }
    }

    private func updateAccessibilityProgress() {
        guard let readingLayout else { return }
        accessibilityValue = "阅读进度 \(readingLayout.maximumOffset > 0 ? Int(offset / readingLayout.maximumOffset * 100) : 100)%"
        let count = visibleLineCount
        if count != reportedVisibleLineCount {
            reportedVisibleLineCount = count
            onVisibleLineCountChanged?(count)
        }
    }

    private func publishPosition() {
        guard let readingLayout else { return }
        reportedPosition = readingLayout.sourcePosition(at: offset)
        requestedPosition = reportedPosition
        updateAccessibilityProgress()
        onPositionChanged?(reportedPosition)
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let readingLayout else { return }
        if gesture.state == .began {
            dragStart = offset
            isDragging = true
            setPlaying(false)
            onManualScrollChanged?(true)
        }
        offset = min(readingLayout.maximumOffset, max(0, dragStart - gesture.translation(in: self).y))
        setNeedsDisplay()
        publishPosition()
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            isDragging = false
            onManualScrollChanged?(false)
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let readingLayout else { return false }
        let step = direction == .down ? readingLayout.linePitch : -readingLayout.linePitch
        guard direction == .up || direction == .down else { return false }
        onManualScrollChanged?(true)
        offset = min(readingLayout.maximumOffset, max(0, offset + step))
        setNeedsDisplay()
        publishPosition()
        onManualScrollChanged?(false)
        UIAccessibility.post(notification: .pageScrolled, argument: accessibilityValue)
        return true
    }
}

private final class TeleprompterDisplayLinkTarget: NSObject {
    weak var surface: TeleprompterReadingSurface?
    init(surface: TeleprompterReadingSurface) { self.surface = surface }
    @objc func tick(_ link: CADisplayLink) { surface?.tick(link) }
}
