import SwiftUI
import UIKit
import ImageIO

enum CounterIconCache {
    private static let images: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func image(data: Data?) -> UIImage? {
        guard let data, data.count <= AccountCardArtwork.maximumBytes else { return nil }
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 192,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        images.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }

    static func image(base64: String?) -> UIImage? {
        guard let base64, base64.utf8.count <= ((AccountCardArtwork.maximumBytes + 2) / 3) * 4 + 4 else { return nil }
        return image(data: Data(base64Encoded: base64))
    }
}

enum CounterPalette {
    static let canvas = Color(red: 0.944, green: 0.949, blue: 0.957)
    static let paper = Color.white
    static let yellow = Color(red: 1.0, green: 0.81, blue: 0.0)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let secondary = Color(red: 0.54, green: 0.57, blue: 0.61)
    static let divider = Color(red: 0.91, green: 0.92, blue: 0.94)
    static let purple = Color(red: 0.56, green: 0.42, blue: 0.98)
}

/// Account management uses semantic system surfaces in both appearances.
enum AccountPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let paper = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let divider = Color(uiColor: .separator)
    static let accent = Color.accentColor
    static let purple = accent
    static let yellow = accent.opacity(0.12)
}

struct AccountSurface<Content: View>: View {
    var inset: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(AccountPalette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CounterCard<Content: View>: View {
    var inset: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CounterPalette.paper, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct CounterCategoryArtwork: View {
    let assetName: String
    var side: CGFloat = 38
    var iconPNGBase64: String? = nil
    var body: some View {
        Group {
            if let image = CounterIconCache.image(base64: iconPNGBase64) ?? UIImage(named: assetName) ?? UIImage(named: "custom_category") {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "tag.fill").resizable().scaledToFit().foregroundStyle(CounterPalette.purple)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct AccountBrandMark: View {
    let account: BookAccount?
    var side: CGFloat = 18

    var body: some View {
        AccountIconArtwork(assetName: account?.brandIcon, icon: account?.displayCardIcon ?? .wallet,
                           pngBase64: account?.cardIconPNGBase64, side: side)
            .foregroundStyle(CounterPalette.purple)
            .accessibilityHidden(true)
    }
}

/// Shared rendering order for wallet, editor, entry picker and transfers.
struct AccountIconArtwork: View {
    var assetName: String? = nil
    var icon: AccountCardIcon
    var pngBase64: String? = nil
    var pngData: Data? = nil
    var side: CGFloat = 38

    var body: some View {
        Group {
            if let image = CounterIconCache.image(base64: pngBase64) ?? CounterIconCache.image(data: pngData) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let assetName, let image = UIImage(named: assetName) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: icon.symbol).resizable().scaledToFit().padding(side * 0.12)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct CounterEmptyState: View {
    var title: String
    var detail: String
    var symbol: String = "tray"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(CounterPalette.secondary.opacity(0.65))
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(CounterPalette.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(CounterPalette.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34)
        .accessibilityElement(children: .combine)
    }
}

struct BubbleFlowLayout: Layout {
    var spacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x + (size.width < bounds.width ? 0 : 0), y: y + (rowHeight == 0 ? 0 : (rowHeight - size.height) / 2)), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    func counterShadow() -> some View {
        shadow(color: Color(red: 0.18, green: 0.23, blue: 0.30).opacity(0.065), radius: 18, x: 0, y: 7)
    }
}
