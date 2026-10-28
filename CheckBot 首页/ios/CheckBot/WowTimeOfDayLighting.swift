import Foundation
import SwiftUI
import UIKit

enum DaylightPhase: String, Equatable {
    case night
    case dawn
    case morning
    case midday
    case afternoon
    case dusk
    case twilight
}

struct AmbientLightColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func mixed(with other: AmbientLightColor, amount: Double) -> AmbientLightColor {
        let t = min(max(amount, 0), 1)
        return AmbientLightColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }
}

struct AmbientLightState: Equatable {
    let phase: DaylightPhase
    let lightX: Double
    let lightY: Double
    let color: AmbientLightColor
    let intensity: Double
    let glowRadius: Double
    let sunOpacity: Double
    let moonOpacity: Double
}

enum TimeOfDayLighting {
    private struct ControlPoint {
        let minute: Double
        let phase: DaylightPhase
        let lightX: Double
        let lightY: Double
        let color: AmbientLightColor
        let intensity: Double
        let glowRadius: Double
        let sunOpacity: Double
        let moonOpacity: Double
    }

    // Daylight follows a shallow lower-right → high-center → lower-left arc.
    // Extra twilight points keep the warm-to-cool handoff continuous.
    // Intensity is deliberately stronger than the first pass; the renderer
    // still keeps the gradients soft and top-only so the cards stay clean.
    private static let controlPoints: [ControlPoint] = [
        ControlPoint(
            minute: 0,
            phase: .night,
            lightX: 0.13,
            lightY: 0.03,
            color: AmbientLightColor(red: 0.64, green: 0.77, blue: 0.98),
            intensity: 0.19,
            glowRadius: 1.16,
            sunOpacity: 0,
            moonOpacity: 0.17
        ),
        ControlPoint(
            minute: 4.5 * 60,
            phase: .night,
            lightX: 0.14,
            lightY: 0.04,
            color: AmbientLightColor(red: 0.66, green: 0.78, blue: 0.98),
            intensity: 0.18,
            glowRadius: 1.17,
            sunOpacity: 0,
            moonOpacity: 0.15
        ),
        ControlPoint(
            minute: 5 * 60,
            phase: .dawn,
            lightX: 0.94,
            lightY: 0.13,
            color: AmbientLightColor(red: 0.94, green: 0.89, blue: 0.80),
            intensity: 0.23,
            glowRadius: 1.20,
            sunOpacity: 0.045,
            moonOpacity: 0.04
        ),
        ControlPoint(
            minute: 6.5 * 60,
            phase: .dawn,
            lightX: 0.86,
            lightY: 0.07,
            color: AmbientLightColor(red: 1.00, green: 0.92, blue: 0.74),
            intensity: 0.30,
            glowRadius: 1.19,
            sunOpacity: 0.10,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 8 * 60,
            phase: .morning,
            lightX: 0.76,
            lightY: -0.04,
            color: AmbientLightColor(red: 1.00, green: 0.96, blue: 0.86),
            intensity: 0.35,
            glowRadius: 1.16,
            sunOpacity: 0.11,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 9 * 60,
            phase: .morning,
            lightX: 0.68,
            lightY: -0.10,
            color: AmbientLightColor(red: 1.00, green: 0.975, blue: 0.91),
            intensity: 0.38,
            glowRadius: 1.14,
            sunOpacity: 0.095,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 11 * 60,
            phase: .midday,
            lightX: 0.56,
            lightY: -0.18,
            color: AmbientLightColor(red: 1.00, green: 0.99, blue: 0.95),
            intensity: 0.42,
            glowRadius: 1.10,
            sunOpacity: 0.075,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 12.5 * 60,
            phase: .midday,
            lightX: 0.49,
            lightY: -0.22,
            color: AmbientLightColor(red: 1.00, green: 0.995, blue: 0.97),
            intensity: 0.44,
            glowRadius: 1.08,
            sunOpacity: 0.06,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 14 * 60,
            phase: .afternoon,
            lightX: 0.39,
            lightY: -0.17,
            color: AmbientLightColor(red: 1.00, green: 0.97, blue: 0.88),
            intensity: 0.41,
            glowRadius: 1.10,
            sunOpacity: 0.07,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 15.5 * 60,
            phase: .afternoon,
            lightX: 0.30,
            lightY: -0.10,
            color: AmbientLightColor(red: 1.00, green: 0.93, blue: 0.80),
            intensity: 0.38,
            glowRadius: 1.13,
            sunOpacity: 0.09,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 17 * 60,
            phase: .dusk,
            lightX: 0.21,
            lightY: -0.02,
            color: AmbientLightColor(red: 1.00, green: 0.86, blue: 0.69),
            intensity: 0.34,
            glowRadius: 1.16,
            sunOpacity: 0.10,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 18.5 * 60,
            phase: .dusk,
            lightX: 0.14,
            lightY: 0.07,
            color: AmbientLightColor(red: 1.00, green: 0.79, blue: 0.69),
            intensity: 0.30,
            glowRadius: 1.19,
            sunOpacity: 0.06,
            moonOpacity: 0
        ),
        ControlPoint(
            minute: 19.5 * 60,
            phase: .twilight,
            lightX: 0.11,
            lightY: 0.08,
            color: AmbientLightColor(red: 0.92, green: 0.79, blue: 0.76),
            intensity: 0.26,
            glowRadius: 1.21,
            sunOpacity: 0.015,
            moonOpacity: 0.04
        ),
        ControlPoint(
            minute: 20.5 * 60,
            phase: .twilight,
            lightX: 0.11,
            lightY: 0.06,
            color: AmbientLightColor(red: 0.76, green: 0.81, blue: 0.91),
            intensity: 0.23,
            glowRadius: 1.22,
            sunOpacity: 0,
            moonOpacity: 0.12
        ),
        ControlPoint(
            minute: 21.5 * 60,
            phase: .night,
            lightX: 0.12,
            lightY: 0.04,
            color: AmbientLightColor(red: 0.68, green: 0.80, blue: 0.99),
            intensity: 0.21,
            glowRadius: 1.21,
            sunOpacity: 0,
            moonOpacity: 0.16
        ),
        ControlPoint(
            minute: 22.5 * 60,
            phase: .night,
            lightX: 0.13,
            lightY: 0.03,
            color: AmbientLightColor(red: 0.65, green: 0.78, blue: 0.99),
            intensity: 0.20,
            glowRadius: 1.19,
            sunOpacity: 0,
            moonOpacity: 0.17
        ),
        ControlPoint(
            minute: 24 * 60,
            phase: .night,
            lightX: 0.13,
            lightY: 0.03,
            color: AmbientLightColor(red: 0.64, green: 0.77, blue: 0.98),
            intensity: 0.19,
            glowRadius: 1.16,
            sunOpacity: 0,
            moonOpacity: 0.17
        )
    ]

    static func state(for date: Date, calendar: Calendar = .current) -> AmbientLightState {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60

        let lower = controlPoints.last(where: { $0.minute <= minute }) ?? controlPoints[0]
        let upper = controlPoints.first(where: { $0.minute > minute }) ?? controlPoints[controlPoints.count - 1]
        let amount = (minute - lower.minute) / max(upper.minute - lower.minute, 1)

        return AmbientLightState(
            phase: lower.phase,
            lightX: interpolate(lower.lightX, upper.lightX, amount: amount),
            lightY: interpolate(lower.lightY, upper.lightY, amount: amount),
            color: lower.color.mixed(with: upper.color, amount: amount),
            intensity: interpolate(lower.intensity, upper.intensity, amount: amount),
            glowRadius: interpolate(lower.glowRadius, upper.glowRadius, amount: amount),
            sunOpacity: interpolate(lower.sunOpacity, upper.sunOpacity, amount: amount),
            moonOpacity: interpolate(lower.moonOpacity, upper.moonOpacity, amount: amount)
        )
    }

    static func nextMinuteBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        components.second = 0
        let minuteStart = calendar.date(from: components) ?? date
        return calendar.date(byAdding: .minute, value: 1, to: minuteStart)
            ?? date.addingTimeInterval(60)
    }

    static func intervalUntilNextMinute(after date: Date, calendar: Calendar = .current) -> TimeInterval {
        max(nextMinuteBoundary(after: date, calendar: calendar).timeIntervalSince(date), 0.1)
    }

    // In Debug, set WOW_AMBIENT_LIGHT_TIME to HH:mm in the Run scheme.
    // The override keeps the preview visual clock pinned to the selected checkpoint.
    static func renderingDate(for actualDate: Date, calendar: Calendar = .current) -> Date {
        #if DEBUG
        guard
            let value = ProcessInfo.processInfo.environment["WOW_AMBIENT_LIGHT_TIME"],
            let override = date(withTime: value, relativeTo: actualDate, calendar: calendar)
        else {
            return actualDate
        }
        return override
        #else
        return actualDate
        #endif
    }

    #if DEBUG
    static func date(withTime value: String, relativeTo date: Date, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            return nil
        }

        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }
    #endif

    private static func interpolate(_ from: Double, _ to: Double, amount: Double) -> Double {
        from + (to - from) * min(max(amount, 0), 1)
    }
}

private struct AmbientLightVector: VectorArithmetic {
    var lightX: Double
    var lightY: Double
    var red: Double
    var green: Double
    var blue: Double
    var intensity: Double
    var glowRadius: Double
    var sunOpacity: Double
    var moonOpacity: Double

    static let zero = AmbientLightVector(
        lightX: 0,
        lightY: 0,
        red: 0,
        green: 0,
        blue: 0,
        intensity: 0,
        glowRadius: 0,
        sunOpacity: 0,
        moonOpacity: 0
    )

    static func + (lhs: AmbientLightVector, rhs: AmbientLightVector) -> AmbientLightVector {
        var result = lhs
        result += rhs
        return result
    }

    static func - (lhs: AmbientLightVector, rhs: AmbientLightVector) -> AmbientLightVector {
        var result = lhs
        result -= rhs
        return result
    }

    static func += (lhs: inout AmbientLightVector, rhs: AmbientLightVector) {
        lhs.lightX += rhs.lightX
        lhs.lightY += rhs.lightY
        lhs.red += rhs.red
        lhs.green += rhs.green
        lhs.blue += rhs.blue
        lhs.intensity += rhs.intensity
        lhs.glowRadius += rhs.glowRadius
        lhs.sunOpacity += rhs.sunOpacity
        lhs.moonOpacity += rhs.moonOpacity
    }

    static func -= (lhs: inout AmbientLightVector, rhs: AmbientLightVector) {
        lhs.lightX -= rhs.lightX
        lhs.lightY -= rhs.lightY
        lhs.red -= rhs.red
        lhs.green -= rhs.green
        lhs.blue -= rhs.blue
        lhs.intensity -= rhs.intensity
        lhs.glowRadius -= rhs.glowRadius
        lhs.sunOpacity -= rhs.sunOpacity
        lhs.moonOpacity -= rhs.moonOpacity
    }

    mutating func scale(by rhs: Double) {
        lightX *= rhs
        lightY *= rhs
        red *= rhs
        green *= rhs
        blue *= rhs
        intensity *= rhs
        glowRadius *= rhs
        sunOpacity *= rhs
        moonOpacity *= rhs
    }

    var magnitudeSquared: Double {
        lightX * lightX
            + lightY * lightY
            + red * red
            + green * green
            + blue * blue
            + intensity * intensity
            + glowRadius * glowRadius
            + sunOpacity * sunOpacity
            + moonOpacity * moonOpacity
    }
}

struct RenderedAmbientLightState: Equatable {
    let phase: DaylightPhase
    let lightX: Double
    let lightY: Double
    let color: AmbientLightColor
    let intensity: Double
    let glowRadius: Double
    let sunOpacity: Double
    let moonOpacity: Double

    init(
        phase: DaylightPhase,
        lightX: Double,
        lightY: Double,
        color: AmbientLightColor,
        intensity: Double,
        glowRadius: Double,
        sunOpacity: Double,
        moonOpacity: Double
    ) {
        self.phase = phase
        self.lightX = lightX
        self.lightY = lightY
        self.color = color
        self.intensity = intensity
        self.glowRadius = glowRadius
        self.sunOpacity = sunOpacity
        self.moonOpacity = moonOpacity
    }

    fileprivate var vector: AmbientLightVector {
        AmbientLightVector(
            lightX: lightX,
            lightY: lightY,
            red: color.red,
            green: color.green,
            blue: color.blue,
            intensity: intensity,
            glowRadius: glowRadius,
            sunOpacity: sunOpacity,
            moonOpacity: moonOpacity
        )
    }

    fileprivate init(phase: DaylightPhase, vector: AmbientLightVector) {
        self.phase = phase
        lightX = vector.lightX
        lightY = vector.lightY
        color = AmbientLightColor(red: vector.red, green: vector.green, blue: vector.blue)
        intensity = vector.intensity
        glowRadius = vector.glowRadius
        sunOpacity = vector.sunOpacity
        moonOpacity = vector.moonOpacity
    }
}

extension AmbientLightState {
    func rendered() -> RenderedAmbientLightState {
        RenderedAmbientLightState(
            phase: phase,
            lightX: lightX,
            lightY: lightY,
            color: color,
            intensity: intensity,
            glowRadius: glowRadius,
            sunOpacity: sunOpacity,
            moonOpacity: moonOpacity
        )
    }
}

struct AmbientLightLayer: View {
    private static let transitionDuration: TimeInterval = 1

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var baseState: AmbientLightState
    @State private var isApplicationActive: Bool
    @State private var isLightingVisible = false

    init() {
        let initialDate = TimeOfDayLighting.renderingDate(for: Date())
        _baseState = State(initialValue: TimeOfDayLighting.state(for: initialDate))
        _isApplicationActive = State(
            initialValue: UIApplication.shared.applicationState == .active
        )
    }

    var body: some View {
        AmbientLightRenderer(state: baseState.rendered())
            .opacity(isLightingVisible ? 1 : 0)
            .task(id: lifecycleKey) {
                await runLightingUpdates()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                isApplicationActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                isApplicationActive = false
            }
    }

    private var lifecycleKey: String {
        "\(isApplicationActive)-\(accessibilityReduceMotion)"
    }

    @MainActor
    private func runLightingUpdates() async {
        guard isApplicationActive else { return }

        updateLighting(for: Date())
        showLightingIfNeeded()

        while !Task.isCancelled {
            do {
                let delay = TimeOfDayLighting.intervalUntilNextMinute(after: Date())
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break
            }

            guard isApplicationActive else { break }
            updateLighting(for: Date())
        }
    }

    @MainActor
    private func updateLighting(for actualDate: Date) {
        let date = TimeOfDayLighting.renderingDate(for: actualDate)
        if accessibilityReduceMotion {
            setBaseStateImmediately(for: date)
        } else {
            withAnimation(.easeInOut(duration: Self.transitionDuration)) {
                baseState = TimeOfDayLighting.state(for: date)
            }
        }
    }

    @MainActor
    private func showLightingIfNeeded() {
        guard !isLightingVisible else { return }
        if accessibilityReduceMotion {
            isLightingVisible = true
        } else {
            withAnimation(.easeInOut(duration: Self.transitionDuration)) {
                isLightingVisible = true
            }
        }
    }

    @MainActor
    private func setBaseStateImmediately(for date: Date) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            baseState = TimeOfDayLighting.state(for: date)
        }
    }
}

private struct AmbientLightRenderer: View, Animatable {
    var state: RenderedAmbientLightState

    var animatableData: AmbientLightVector {
        get { state.vector }
        set { state = RenderedAmbientLightState(phase: state.phase, vector: newValue) }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let radius = width * CGFloat(state.glowRadius) * 0.95
            let center = UnitPoint(x: CGFloat(state.lightX), y: CGFloat(state.lightY))
            let ambientIntensity = min(state.intensity * 1.70, 0.68)
            let celestialY = min(max(74 + state.lightY * 150, 26), 112)
            let sunVisualOpacity = min(state.sunOpacity * 1.90, 0.17)
            let moonVisualOpacity = min(state.moonOpacity * 1.70, 0.20)

            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: state.color.color.opacity(ambientIntensity), location: 0),
                        .init(color: state.color.color.opacity(ambientIntensity * 0.62), location: 0.34),
                        .init(color: state.color.color.opacity(ambientIntensity * 0.22), location: 0.70),
                        .init(color: .clear, location: 1)
                    ],
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
                .blur(radius: 15)

                RadialGradient(
                    colors: [
                        .white.opacity(ambientIntensity * 0.24),
                        .clear
                    ],
                    center: center,
                    startRadius: 0,
                    endRadius: radius * 0.48
                )

                if state.sunOpacity > 0.005 {
                    Circle()
                        .fill(Color(red: 1.00, green: 0.74, blue: 0.38).opacity(sunVisualOpacity * 0.72))
                        .frame(width: 18, height: 18)
                        .blur(radius: 0.8)
                        .shadow(
                            color: Color(red: 1.00, green: 0.68, blue: 0.28).opacity(sunVisualOpacity * 0.72),
                            radius: 16
                        )
                        .position(
                            x: width * CGFloat(state.lightX),
                            y: celestialY
                        )
                        .accessibilityHidden(true)
                }

                if state.moonOpacity > 0.01 {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 23, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(moonVisualOpacity))
                        .shadow(color: state.color.color.opacity(moonVisualOpacity * 0.55), radius: 12)
                        .position(
                            x: width * CGFloat(state.lightX),
                            y: celestialY
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.48),
                    .init(color: .black.opacity(0.38), location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
