import SwiftUI
import UniformTypeIdentifiers
import CounterTool

struct WowDashboardView: View {
    @ObservedObject var store: WowHomeStore
    let now: Date
    let openSection: (WowSection) -> Void
    let openDeleted: () -> Void
    let openModule: (WowModule) -> Void
    let connectPlanFolder: () -> Void

    @AppStorage("wow.tools.order.v1") private var savedToolOrder = ""
    @State private var draggedTool: WowModule?

    private var orderedTools: [ToolDefinition] {
        let definitions = ToolDefinition.all
        var encounteredIDs = Set<String>()
        let saved = savedToolOrder
            .split(separator: ",")
            .map(String.init)
            .compactMap { identifier -> ToolDefinition? in
                guard encounteredIDs.insert(identifier).inserted else { return nil }
                return definitions.first { $0.id == identifier }
            }
        return saved + definitions.filter { !encounteredIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(now.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                counterEntry
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 27)

            Button { openSection(.plans) } label: {
                TodayPlanCard(store: store)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open today’s plans")

            HStack(spacing: 8) {
                Button { openSection(.shopping) } label: {
                    PreviewCard(store: store, section: .shopping)
                }
                .buttonStyle(.plain)
                Button { openSection(.ideas) } label: {
                    PreviewCard(store: store, section: .ideas)
                }
                .buttonStyle(.plain)
            }

            Button(action: openDeleted) {
                HStack(spacing: 10) {
                    Text("Recently Deleted")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(store.archived.isEmpty ? "Completed items kept for 30 days" : "\(store.archived.count) item\(store.archived.count == 1 ? "" : "s") · Kept for 30 days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Text("›")
                        .font(.title2.weight(.light))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(Color.secondary.opacity(0.14)) }
            }
            .buttonStyle(.plain)

            HStack {
                Button(action: connectPlanFolder) {
                    Label(store.isConnecting ? "Connecting…" : "Connect Plan Folder", systemImage: "folder")
                }
                .disabled(store.isConnecting)
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
            .font(.caption)
            .foregroundStyle(.tint)
            .padding(.horizontal, 4)
            .padding(.top, 9)

            VStack(alignment: .leading, spacing: 17) {
                Text("Tools")
                    .font(.system(size: 24, weight: .bold))
                toolRows
            }
            .padding(.top, 6)
            .padding(.horizontal, -4)
        }
    }

    private var counterEntry: some View {
        ZStack {
            CompanionOrb(size: 49)
                .frame(width: 56, height: 56)
                .allowsHitTesting(false)

            Button { openModule(.counter) } label: {
                Circle()
                    .fill(.clear)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Counter")
            .accessibilityIdentifier("wow.counterMascot")
        }
        .frame(width: 56, height: 56)
    }

    private var toolRows: some View {
        GeometryReader { geometry in
            let bubbleWidth = max(0, geometry.size.width - ToolBubbleStyle.horizontalInset * 2)
            VStack(spacing: ToolBubbleStyle.rowSpacing) {
                ForEach(orderedTools) { tool in
                    ToolBubbleView(tool: tool, isDragging: draggedTool != nil) {
                        openModule(tool.module)
                    }
                    .frame(width: bubbleWidth)
                    .onDrag {
                        draggedTool = tool.module
                        return NSItemProvider(object: tool.module.rawValue as NSString)
                    } preview: {
                        ToolBubbleView(tool: tool, isDragging: true) {}
                            .frame(width: bubbleWidth)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: ToolReorderDropDelegate(
                            targetTool: tool.module,
                            draggedTool: draggedTool,
                            onMove: { source, target in moveDraggedTool(from: source, to: target) },
                            onDrop: { draggedTool = nil }
                        )
                    )
                }
            }
            .frame(width: geometry.size.width)
        }
        .frame(
            height: CGFloat(orderedTools.count) * ToolBubbleStyle.height
                + CGFloat(max(orderedTools.count - 1, 0)) * ToolBubbleStyle.rowSpacing
        )
    }

    private func moveDraggedTool(from source: WowModule, to target: WowModule) {
        guard source != target,
              let sourceIndex = orderedTools.firstIndex(where: { $0.module == source }),
              let targetIndex = orderedTools.firstIndex(where: { $0.module == target }),
              sourceIndex != targetIndex else { return }

        var updatedOrder = orderedTools.map(\.module)
        let movingTool = updatedOrder.remove(at: sourceIndex)
        updatedOrder.insert(movingTool, at: targetIndex)

        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.80, blendDuration: 0.12)) {
            savedToolOrder = updatedOrder.map(\.rawValue).joined(separator: ",")
        }
    }

}

private struct TodayPlanCard: View {
    @ObservedObject var store: WowHomeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today’s Plan")
                .font(.system(size: 18, weight: .semibold))
            if store.isRefreshing {
                Label("Refreshing…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let previews = store.previewPlans(at: Date())
            if previews.isEmpty {
                Text(store.planMessage())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(previews.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color(red: 0.09, green: 0.14, blue: 0.20))
                                .lineLimit(2)
                            if let timeRange = item.timeRange {
                                Text(timeRange)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !item.location.isEmpty {
                                Text(item.location)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, index == 0 ? 12 : 10)
                        .frame(maxWidth: index == 0 ? .infinity : index == 1 ? 0.8 * 400 : 0.6 * 400, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.24 - Double(index) * 0.03), Color.blue.opacity(0.05)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: index == 0 ? 11 : 10)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.12)) }
    }
}

private struct PreviewCard: View {
    @ObservedObject var store: WowHomeStore
    let section: WowSection

    var body: some View {
        let items = store.items(for: section).active
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 18, weight: .medium))
            if items.isEmpty {
                Text(section == .shopping ? "Nothing to buy" : "No open ideas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(items.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: section == .shopping ? "circle" : "doc.plaintext")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .padding(16)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.12)) }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private enum ToolBubbleStyle {
    static let height: CGFloat = 80
    static let rowSpacing: CGFloat = 10
    static let horizontalInset: CGFloat = 0
    static let cornerRadius: CGFloat = 40
    static let contentPadding: CGFloat = 21
    static let contentSpacing: CGFloat = 12
    static let textSpacing: CGFloat = 3
    static let iconSize: CGFloat = 50
    static let iconCornerRadius: CGFloat = 16
    static let glyphSize: CGFloat = 34
    static let chevronSize: CGFloat = 18
    static let materialOpacity = 0.14
    static let outerShadowRadius: CGFloat = 4
    static let outerShadowYOffset: CGFloat = 2

    static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    static let iconShape = RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
    static let titleFont = Font.system(size: 18, weight: .semibold)
    static let subtitleFont = Font.system(size: 14)
    static let titleColor = Color(red: 0.12, green: 0.15, blue: 0.20)
    static let subtitleColor = Color(red: 0.40, green: 0.44, blue: 0.50)
    static let glyphColor = Color(red: 0.50, green: 0.54, blue: 0.60)
    static let chevronColor = Color(red: 0.47, green: 0.51, blue: 0.57)
    static let coldTint = Color(red: 0.62, green: 0.72, blue: 0.84)
    static let edgeTint = Color(red: 0.64, green: 0.74, blue: 0.87)

    static let surfaceGradient = LinearGradient(
        stops: [
            .init(color: coldTint.opacity(0.22), location: 0),
            .init(color: coldTint.opacity(0.17), location: 0.53),
            .init(color: coldTint.opacity(0.08), location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let refractionGradient = LinearGradient(
        colors: [Color.white.opacity(0.20), edgeTint.opacity(0.28), Color.white.opacity(0.08)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let borderGradient = LinearGradient(
        colors: [Color.white.opacity(0.90), Color.white.opacity(0.46), edgeTint.opacity(0.24)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let iconGradient = LinearGradient(
        colors: [Color.white.opacity(0.72), coldTint.opacity(0.10), Color.white.opacity(0.36)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func animationDuration(for id: String) -> Double {
        let seed = id.utf8.reduce(0) { $0 + Int($1) }
        return 8.0 + Double(seed % 7) * 0.31
    }
}

private enum ToolIcon {
    case pictureRemarker
    case asset(String)
    case system(String)
}

private struct ToolDefinition: Identifiable {
    let module: WowModule
    let title: String
    let subtitle: String
    let icon: ToolIcon
    let accessibilityLabel: String?

    var id: String { module.rawValue }

    init(module: WowModule, title: String, subtitle: String, icon: ToolIcon, accessibilityLabel: String? = nil) {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
    }

    // Register new tools here; ToolBubbleView is the only visual template for this list.
    static let all = [
        ToolDefinition(
            module: .pictureRemarker,
            title: "Picture Remarker",
            subtitle: "Annotate and take notes on images",
            icon: .pictureRemarker
        ),
        ToolDefinition(
            module: .teleprompter,
            title: "Teleprompter",
            subtitle: "Read and record with confidence",
            icon: .asset("TeleprompterIcon")
        )
    ]
}

private struct ToolBubbleView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let tool: ToolDefinition
    let isDragging: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ToolBubbleStyle.contentSpacing) {
                ToolIconTile(tool: tool)

                VStack(alignment: .leading, spacing: ToolBubbleStyle.textSpacing) {
                    Text(tool.title)
                        .font(ToolBubbleStyle.titleFont)
                        .foregroundStyle(ToolBubbleStyle.titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(tool.subtitle)
                        .font(ToolBubbleStyle.subtitleFont)
                        .foregroundStyle(ToolBubbleStyle.subtitleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: ToolBubbleStyle.chevronSize, weight: .regular))
                    .foregroundStyle(ToolBubbleStyle.chevronColor.opacity(0.83))
            }
            .padding(.horizontal, ToolBubbleStyle.contentPadding)
            .frame(maxWidth: .infinity, minHeight: ToolBubbleStyle.height, maxHeight: ToolBubbleStyle.height)
            .background {
                ToolBubbleSurface(
                    toolID: tool.id,
                    motionEnabled: !accessibilityReduceMotion && !isDragging
                )
                .allowsHitTesting(false)
            }
            .contentShape(ToolBubbleStyle.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.accessibilityLabel ?? "Open \(tool.title)")
        .accessibilityIdentifier("Open \(tool.title)")
    }
}

private struct ToolIconTile: View {
    let tool: ToolDefinition

    var body: some View {
        ToolGlyph(tool: tool, color: ToolBubbleStyle.glyphColor)
            .frame(width: ToolBubbleStyle.glyphSize, height: ToolBubbleStyle.glyphSize)
            .frame(width: ToolBubbleStyle.iconSize, height: ToolBubbleStyle.iconSize)
            .background {
                ToolBubbleStyle.iconShape
                    .fill(ToolBubbleStyle.iconGradient)
                    .overlay {
                        ToolBubbleStyle.iconShape
                            .stroke(ToolBubbleStyle.edgeTint.opacity(0.30), lineWidth: 0.8)
                    }
                    .overlay {
                        ToolBubbleStyle.iconShape
                            .inset(by: 1)
                            .stroke(ToolBubbleStyle.borderGradient, lineWidth: 0.8)
                    }
            }
    }
}

private struct ToolGlyph: View {
    let tool: ToolDefinition
    let color: Color

    @ViewBuilder
    var body: some View {
        switch tool.icon {
        case .pictureRemarker:
            PictureRemarkerGlyph()
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(3)
        case .asset(let assetName):
            color
                .opacity(0.76)
                .mask {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .saturation(0)
                        .contrast(2.6)
                        .luminanceToAlpha()
                        .padding(3)
                }
        case .system(let systemName):
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(color)
        }
    }
}

private struct PictureRemarkerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.06, 0.82))
        path.addLine(to: point(0.32, 0.43))
        path.addQuadCurve(to: point(0.49, 0.62), control: point(0.39, 0.38))
        path.addLine(to: point(0.65, 0.31))
        path.addQuadCurve(to: point(0.91, 0.71), control: point(0.80, 0.34))
        path.addLine(to: point(0.65, 0.71))
        path.addQuadCurve(to: point(0.55, 0.59), control: point(0.60, 0.71))

        path.addEllipse(in: CGRect(x: point(0.60, 0.16).x, y: point(0.60, 0.16).y, width: rect.width * 0.30, height: rect.height * 0.30))
        path.move(to: point(0.68, 0.38))
        path.addLine(to: point(0.79, 0.28))
        path.addLine(to: point(0.79, 0.37))
        path.move(to: point(0.79, 0.28))
        path.addLine(to: point(0.70, 0.28))
        return path
    }
}

private struct ToolBubbleSurface: View {
    let toolID: String
    let motionEnabled: Bool

    var body: some View {
        Color.clear
            .phaseAnimator(motionEnabled ? [false, true] : [false]) { _, phase in
                surface(phase: phase)
            } animation: { _ in
                .easeInOut(duration: ToolBubbleStyle.animationDuration(for: toolID))
            }
    }

    private func surface(phase: Bool) -> some View {
        GeometryReader { geometry in
            let shape = ToolBubbleStyle.shape
            ZStack {
                shape.fill(.ultraThinMaterial)
                    .opacity(ToolBubbleStyle.materialOpacity)
                shape.fill(Color.white.opacity(0.03))
                shape.fill(ToolBubbleStyle.surfaceGradient)

                shape.fill(
                    RadialGradient(
                        colors: [ToolBubbleStyle.coldTint.opacity(0.02), .clear],
                        center: UnitPoint(x: phase ? 0.82 : 0.76, y: 0.75),
                        startRadius: 0,
                        endRadius: max(geometry.size.width * 0.32, 1)
                    )
                )

                shape.inset(by: 1.2)
                    .strokeBorder(ToolBubbleStyle.refractionGradient, lineWidth: 2.1)

                Capsule()
                    .fill(ToolBubbleStyle.coldTint.opacity(0.12))
                    .frame(width: geometry.size.width * 0.55, height: 19)
                    .blur(radius: 6)
                    .position(
                        x: geometry.size.width * (phase ? 0.38 : 0.31),
                        y: geometry.size.height * 0.14
                    )

                Capsule()
                    .fill(ToolBubbleStyle.edgeTint.opacity(0.12))
                    .frame(width: geometry.size.width * 0.52, height: 5)
                    .blur(radius: 2)
                    .position(
                        x: geometry.size.width * (phase ? 0.37 : 0.30),
                        y: geometry.size.height * 0.09
                    )

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.66), Color.white.opacity(0.13), Color.white.opacity(0.34)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.84, height: 2)
                    .blur(radius: 1.2)
                    .position(x: geometry.size.width * 0.50, y: geometry.size.height * 0.07)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.48), ToolBubbleStyle.coldTint.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.51, height: 15)
                    .rotationEffect(.degrees(-3))
                    .blur(radius: 4)
                    .position(
                        x: geometry.size.width * (phase ? 0.38 : 0.31),
                        y: geometry.size.height * 0.17
                    )

                Ellipse()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 22, height: 5)
                    .rotationEffect(.degrees(-26))
                    .blur(radius: 0.6)
                    .position(
                        x: geometry.size.width * (phase ? 0.13 : 0.10),
                        y: geometry.size.height * 0.14
                    )

                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: geometry.size.width * 0.24, height: 2.5)
                    .blur(radius: 1.5)
                    .position(x: geometry.size.width * 0.82, y: geometry.size.height * 0.91)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(ToolBubbleStyle.edgeTint.opacity(0.34), lineWidth: 1)
            }
            .overlay {
                shape.inset(by: 1)
                    .strokeBorder(ToolBubbleStyle.borderGradient, lineWidth: 1)
            }
            .shadow(
                color: ToolBubbleStyle.edgeTint.opacity(0.06),
                radius: ToolBubbleStyle.outerShadowRadius,
                x: 0,
                y: ToolBubbleStyle.outerShadowYOffset
            )
        }
    }
}

private struct ToolReorderDropDelegate: DropDelegate {
    let targetTool: WowModule
    let draggedTool: WowModule?
    let onMove: (WowModule, WowModule) -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTool else { return }
        onMove(draggedTool, targetTool)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop()
        return true
    }
}
