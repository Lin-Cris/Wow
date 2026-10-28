import SwiftUI

enum AppTheme {
    static let accent = Color(
        light: UIColor(red: 0.96, green: 0.44, blue: 0.32, alpha: 1),
        dark: UIColor(red: 0.98, green: 0.50, blue: 0.38, alpha: 1)
    )
    static let accentDeep = Color(
        light: UIColor(red: 0.93, green: 0.39, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.93, green: 0.43, blue: 0.32, alpha: 1)
    )
    static let accentSoft = Color(
        light: UIColor(red: 0.99, green: 0.91, blue: 0.86, alpha: 1),
        dark: UIColor(red: 0.28, green: 0.18, blue: 0.14, alpha: 1)
    )
    static let background = Color(
        light: UIColor(red: 0.984, green: 0.973, blue: 0.953, alpha: 1),
        dark: UIColor(red: 0.095, green: 0.078, blue: 0.065, alpha: 1)
    )
    static let secondaryBackground = Color(
        light: UIColor(red: 0.973, green: 0.953, blue: 0.925, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.108, blue: 0.09, alpha: 1)
    )
    static let surface = Color(
        light: UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1),
        dark: UIColor(red: 0.16, green: 0.135, blue: 0.115, alpha: 1)
    )
    static let elevatedSurface = Color(
        light: UIColor(red: 1.0, green: 0.997, blue: 0.99, alpha: 0.94),
        dark: UIColor(red: 0.19, green: 0.16, blue: 0.135, alpha: 0.94)
    )
    static let primaryText = Color(
        light: UIColor(red: 0.18, green: 0.125, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.92, blue: 0.87, alpha: 1)
    )
    static let secondaryText = Color(
        light: UIColor(red: 0.52, green: 0.46, blue: 0.41, alpha: 1),
        dark: UIColor(red: 0.72, green: 0.66, blue: 0.60, alpha: 1)
    )
    static let tertiaryText = Color(
        light: UIColor(red: 0.67, green: 0.61, blue: 0.56, alpha: 1),
        dark: UIColor(red: 0.57, green: 0.51, blue: 0.46, alpha: 1)
    )
    static let border = Color(
        light: UIColor(red: 0.91, green: 0.86, blue: 0.81, alpha: 1),
        dark: UIColor(red: 0.29, green: 0.25, blue: 0.21, alpha: 1)
    )
    static let decoration = Color(
        light: UIColor(red: 0.88, green: 0.70, blue: 0.56, alpha: 1),
        dark: UIColor(red: 0.70, green: 0.48, blue: 0.36, alpha: 1)
    )

    static let cardCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 18

    static var buttonGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.98), accentDeep.opacity(0.98)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}

struct WarmPageBackground: View {
    var body: some View {
        ZStack {
            AppTheme.background

            RadialGradient(
                colors: [
                    AppTheme.accentSoft.opacity(0.22),
                    .clear
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 330
            )

            RadialGradient(
                colors: [
                    AppTheme.surface.opacity(0.52),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 290
            )
        }
        .ignoresSafeArea()
    }
}

struct WarmPrimaryButtonLabel: View {
    let title: String
    let systemImage: String?
    var maxWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
            }

            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: maxWidth ?? .infinity)
        .frame(height: 52)
        .background(AppTheme.buttonGradient)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.controlCornerRadius,
                style: .continuous
            )
        )
        .shadow(color: AppTheme.accent.opacity(0.16), radius: 10, y: 5)
    }
}

struct WarmNavigationIcon: View {
    let systemName: String
    var isEmphasized = false
    var isEnabled = true
    var tint: Color? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(
                isEmphasized
                    ? Color.white
                    : (tint ?? AppTheme.primaryText)
            )
            .frame(width: 31, height: 31)
            .background(
                isEmphasized
                    ? AnyShapeStyle(AppTheme.buttonGradient)
                    : AnyShapeStyle(AppTheme.elevatedSurface)
            )
            .clipShape(Circle())
            .overlay {
                if !isEmphasized {
                    Circle()
                        .stroke(AppTheme.border.opacity(0.55), lineWidth: 0.7)
                }
            }
            .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
            .opacity(isEnabled ? 1 : 0.36)
    }
}

extension View {
    func warmCard(cornerRadius: CGFloat = AppTheme.cardCornerRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.52), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.035), radius: 14, y: 6)
    }
}
