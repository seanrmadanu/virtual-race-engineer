import SwiftUI

/// One marker and one animation state. Display ticks update state outside body
/// evaluation; normal SwiftUI invalidations cannot advance the spring twice.
struct SteeringWheelTargetView: View {
    let targetDegrees: Double?
    let sourceSessionID: Int
    let accent: Color
    let diameter: CGFloat
    var rotationOverride: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = SteeringWheelMotion()
    @State private var rotation = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isSettled)) { context in
            SteeringWheelArtwork(rotation: rotationOverride ?? rotation, accent: accent,
                                 diameter: diameter, isAvailable: targetDegrees != nil || rotationOverride != nil)
                .onChange(of: context.date, initial: true) { _, _ in
                    rotation = motion.advance(toward: targetDegrees,
                        at: ProcessInfo.processInfo.systemUptime, reduceMotion: reduceMotion,
                        session: sourceSessionID)
                }
        }
        // The integrator owns rotation. Do not inherit opacity/layout animations.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustrative steering direction")
        .accessibilityValue(accessibilityValue)
    }

    private var isSettled: Bool {
        rotationOverride != nil || (targetDegrees.map { $0 == rotation } ?? (rotation == 0))
    }

    private var accessibilityValue: String {
        guard let target = rotationOverride ?? targetDegrees else { return "Unavailable" }
        if abs(target) < 1 { return "Centered" }
        return target < 0 ? "Turn left" : "Turn right"
    }
}

/// Pure rendering, shared by the animated HUD and off-screen visual checks.
struct SteeringWheelArtwork: View {
    let rotation: Double
    let accent: Color
    let diameter: CGFloat
    let isAvailable: Bool

    var body: some View {
        ZStack {
            ForEach([-90.0, -45, 45, 90], id: \.self) { degrees in
                Circle().fill(Color.white.opacity(0.28))
                    .frame(width: 4, height: 4)
                    .offset(x: sin(degrees * .pi / 180) * diameter * 0.54,
                            y: -cos(degrees * .pi / 180) * diameter * 0.54)
            }
            Rectangle().fill(Color.white.opacity(0.55))
                .frame(width: 2, height: diameter * 0.03)
                .offset(y: -diameter * 0.535)
            SteeringWheelShape(diameter: diameter, accent: accent, rotation: rotation)
                .opacity(isAvailable ? 0.95 : 0.35)
        }
        .frame(width: diameter * 1.3, height: diameter * 1.3)
    }
}

/// The wheel artwork (`SteeringWheel` in the asset catalog), rotated about its
/// hub. The PNG's hub sits below the image centre and its rim does not reach
/// the image edges, so both are corrected here to keep the rim at `diameter`.
struct SteeringWheelShape: View {
    let diameter: CGFloat
    let accent: Color
    let rotation: Double

    /// Measured on the 1254 px source: rim spans x 47...1205, hub at y 678.
    private static let rimFraction: CGFloat = 1158.0 / 1254.0

    /// Hub-to-rim-top distance and the farthest opaque pixel from the hub,
    /// both as fractions of the rim diameter.
    static let hubToRimTop: CGFloat = 629.0 / 1158.0
    static let turningRadius: CGFloat = 640.0 / 1158.0
    private static let hubAnchor = UnitPoint(x: 0.5, y: 678.0 / 1254.0)
    private static let rimTopFraction: CGFloat = 95.0 / 1254.0

    var body: some View {
        let size = diameter / Self.rimFraction

        Image("SteeringWheel")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .top) {
                // Top-dead-center marker
                RoundedRectangle(cornerRadius: size * 0.006, style: .continuous)
                    .fill(accent)
                    .frame(width: size * 0.022, height: size * 0.06)
                    .shadow(color: accent.opacity(0.8), radius: size * 0.018)
                    .offset(y: size * Self.rimTopFraction - size * 0.03)
            }
            .shadow(color: .black.opacity(0.55), radius: diameter * 0.03, y: diameter * 0.015)
            .rotationEffect(.degrees(rotation), anchor: Self.hubAnchor)
            // Centre the hub, not the image, in the layout frame.
            .offset(y: -(Self.hubAnchor.y - 0.5) * size)
            .frame(width: diameter, height: diameter)
    }
}

