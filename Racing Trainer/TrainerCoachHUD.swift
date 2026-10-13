import SwiftUI
import AppKit

// MARK: - Layout Preferences

/// Where the fitted video sits when the preview is taller than the feed.
/// Pinning it to the top leaves the spare space below for the HUD.
enum VideoPlacement: String, CaseIterable, Identifiable {
    case top
    case center
    case bottom

    static let storageKey = "video.placement"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        }
    }

    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }
}

/// Camera profile controls the image region searched for white road markings.
/// Whether the highlight shows at all is in the View menu.
enum PathRibbon: String, CaseIterable, Identifiable {
    case chase
    case cockpit

    static let storageKey = "hud.pathRibbonCamera"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chase: return "Chase Camera"
        case .cockpit: return "Cockpit Camera"
        }
    }

}

/// Visibility of every overlay, keyed in UserDefaults so the View menu,
/// the HUD and the preview all read the same switches.
enum OverlayVisibility {
    static let navigationCard = "view.navigationCard"
    static let sessionPanel = "view.sessionPanel"
    static let steeringWheel = "view.steeringWheel"
    static let speed = "view.speed"
    static let pedalAction = "view.pedalAction"
    static let pathHighlight = "view.pathHighlight"
    static let analyzer = "preview.showsAnalyzerOverlay"
    static let hudRegions = "preview.showsHUDRegions"
    static let highlightItems = "view.highlightItems"
}

/// Coaching overlays that can be highlighted on screen. Each has its own
/// colour, used for the on-screen outline and the dot in the View menu.
/// The palette avoids the action colours (red, amber, green) and the cyan
/// player marker so a highlight is never mistaken for guidance.
enum OverlayItem: CaseIterable {
    case navigationCard
    case sessionPanel
    case steeringWheel
    case speed
    case pedalAction
    case pathHighlight

    var title: String {
        switch self {
        case .navigationCard: return "Navigation Card"
        case .sessionPanel: return "Session Timer"
        case .steeringWheel: return "Steering Wheel"
        case .speed: return "Speed"
        case .pedalAction: return "Pedal Action"
        case .pathHighlight: return "Path Highlight"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .navigationCard: return NSColor(srgbRed: 0.56, green: 0.66, blue: 1.00, alpha: 1) // periwinkle
        case .sessionPanel: return NSColor(srgbRed: 0.79, green: 0.64, blue: 1.00, alpha: 1)   // lilac
        case .steeringWheel: return NSColor(srgbRed: 0.37, green: 0.92, blue: 0.83, alpha: 1)  // teal
        case .speed: return NSColor(srgbRed: 1.00, green: 0.56, blue: 0.69, alpha: 1)          // rose
        case .pedalAction: return NSColor(srgbRed: 0.91, green: 0.84, blue: 0.63, alpha: 1)    // sand
        case .pathHighlight: return NSColor(srgbRed: 0.85, green: 0.90, blue: 0.54, alpha: 1)  // chartreuse
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Coloured dot for the menu. Non-template so the menu keeps its colour.
    var menuDot: NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Outline and name tag drawn around an overlay while Highlight Items is on.
private struct OverlayHighlight: ViewModifier {
    let item: OverlayItem
    let isOn: Bool
    var cornerRadius: CGFloat = 18
    var isCircle = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isOn {
                    Group {
                        if isCircle {
                            Circle().strokeBorder(item.color, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius + 5, style: .continuous)
                                .strokeBorder(item.color, lineWidth: 2)
                        }
                    }
                    .padding(-5)
                    .shadow(color: item.color.opacity(0.6), radius: 6)
                }
            }
            .overlay(alignment: isCircle ? .top : .topLeading) {
                if isOn {
                    OverlayHighlightTag(item: item)
                        .fixedSize()
                        .offset(x: isCircle ? 0 : -5, y: -34)
                }
            }
    }
}

private struct OverlayHighlightTag: View {
    let item: OverlayItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(item.color.opacity(0.7), lineWidth: 1))
    }
}

private extension View {
    func overlayHighlight(
        _ item: OverlayItem,
        _ isOn: Bool,
        cornerRadius: CGFloat = 18,
        isCircle: Bool = false
    ) -> some View {
        modifier(OverlayHighlight(item: item, isOn: isOn, cornerRadius: cornerRadius, isCircle: isCircle))
    }
}

/// One menu for every overlay, with a single Show All / Hide All at the top.
struct OverlayViewMenu<MenuLabel: View>: View {
    @AppStorage(OverlayVisibility.navigationCard) private var navigationCard = true
    @AppStorage(OverlayVisibility.sessionPanel) private var sessionPanel = true
    @AppStorage(OverlayVisibility.steeringWheel) private var steeringWheel = true
    @AppStorage(OverlayVisibility.speed) private var speed = true
    @AppStorage(OverlayVisibility.pedalAction) private var pedalAction = true
    @AppStorage(OverlayVisibility.pathHighlight) private var pathHighlight = true
    @AppStorage(OverlayVisibility.analyzer) private var analyzer = false
    @AppStorage(OverlayVisibility.hudRegions) private var hudRegions = false
    @AppStorage(OverlayVisibility.highlightItems) private var highlightItems = false

    @ViewBuilder let label: () -> MenuLabel

    private var switches: [Binding<Bool>] {
        [$navigationCard, $sessionPanel, $steeringWheel, $speed,
         $pedalAction, $pathHighlight, $analyzer, $hudRegions]
    }

    private var allVisible: Bool {
        switches.allSatisfy(\.wrappedValue)
    }

    var body: some View {
        Menu {
            Button(allVisible ? "Hide All" : "Show All") {
                let visible = !allVisible
                switches.forEach { $0.wrappedValue = visible }
            }

            Toggle("Highlight Items", isOn: $highlightItems)

            Divider()

            Section("Coaching") {
                itemToggle(.navigationCard, $navigationCard)
                itemToggle(.sessionPanel, $sessionPanel)
                itemToggle(.steeringWheel, $steeringWheel)
                itemToggle(.speed, $speed)
                itemToggle(.pedalAction, $pedalAction)
                itemToggle(.pathHighlight, $pathHighlight)
            }

            Section("Debug") {
                Toggle("Analyzer Overlay", isOn: $analyzer)
                Toggle("HUD Region Boxes", isOn: $hudRegions)
            }
        } label: {
            label()
        }
        .help("Show or Hide Overlays")
    }

    private func itemToggle(_ item: OverlayItem, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(item.title)
            } icon: {
                Image(nsImage: item.menuDot)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

/// Session-only state for the on-screen wheel editor.
@Observable
final class HUDLayoutEditor {
    static let shared = HUDLayoutEditor()

    var isAdjustingWheel = false
    /// Rotation shown while adjusting, to check a full turn stays on screen.
    var testRotation = 0.0
}

/// Stored wheel placement, as fractions of the preview: hub position
/// (x of width, y of height) and rim diameter (of height).
enum WheelPlacement {
    static let centerXKey = "hud.wheel.centerX"
    static let hubYKey = "hud.wheel.hubY"
    static let sizeKey = "hud.wheel.size"

    static let defaultCenterX = 0.5
    static let defaultSize = 0.3325
    static let defaultHubY = 0.8012

    static let sizeRange = 0.12...0.9
}

/// Video position and wheel adjustment, shared by the window toolbar and
/// the full-screen control row.
struct HUDLayoutMenu<MenuLabel: View>: View {
    @AppStorage(VideoPlacement.storageKey)
    private var placement = VideoPlacement.center

    @AppStorage(PathRibbon.storageKey)
    private var pathRibbon = PathRibbon.chase

    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        let editor = HUDLayoutEditor.shared

        Menu {
            Picker("Video Position", selection: $placement) {
                ForEach(VideoPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Path Highlight Camera", selection: $pathRibbon) {
                ForEach(PathRibbon.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(editor.isAdjustingWheel ? "Finish Adjusting Wheel" : "Adjust Steering Wheel…") {
                editor.isAdjustingWheel.toggle()
                editor.testRotation = 0
            }
        } label: {
            label()
        }
        .help("Video Position and Steering Wheel Layout")
    }
}

// MARK: - Coach HUD

/// Full-preview coaching overlay: turn banner (top), session panel
/// (top right), steering wheel target (bottom center), speed (bottom
/// left) and pedal action (bottom right). Every value comes from the live
/// `MinimapCoachSnapshot`; nothing here makes its own driving decisions.
struct TrainerCoachHUD: View {
    @ObservedObject var analyzer: FrameAnalyzer

    let containerSize: CGSize
    /// Where the video sits in the container. The wheel is clipped to it so
    /// nothing of the wheel shows in the letterbox strip.
    let videoRect: CGRect

    @State private var sessionStart = Date()

    @AppStorage(WheelPlacement.centerXKey) private var wheelCenterX = WheelPlacement.defaultCenterX
    @AppStorage(WheelPlacement.hubYKey) private var wheelHubY = WheelPlacement.defaultHubY
    @AppStorage(WheelPlacement.sizeKey) private var wheelSize = WheelPlacement.defaultSize
    @AppStorage(PathRibbon.storageKey) private var pathRibbon = PathRibbon.chase
    @AppStorage(OverlayVisibility.navigationCard) private var showsNavigationCard = true
    @AppStorage(OverlayVisibility.sessionPanel) private var showsSessionPanel = true
    @AppStorage(OverlayVisibility.steeringWheel) private var showsSteeringWheel = true
    @AppStorage(OverlayVisibility.speed) private var showsSpeed = true
    @AppStorage(OverlayVisibility.pedalAction) private var showsPedalAction = true
    @AppStorage(OverlayVisibility.pathHighlight) private var showsPathHighlight = true
    @AppStorage(OverlayVisibility.highlightItems) private var highlightsItems = false

    /// Layout is authored against a 1440×810 canvas and scaled to the preview.
    static let referenceSize = CGSize(width: 1440, height: 810)
    static let bannerTopInset: CGFloat = 36
    static let bannerHeight: CGFloat = 80

    static func layoutScale(for size: CGSize) -> CGFloat {
        let scale = min(
            size.width / referenceSize.width,
            size.height / referenceSize.height
        )
        return min(max(scale, 0.45), 1.4)
    }

    /// Y coordinate just below the turn banner, for stacking extra badges.
    static func bannerBottom(for size: CGSize) -> CGFloat {
        (bannerTopInset + bannerHeight) * layoutScale(for: size)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.10)) { context in
            content(
                currentUptime: ProcessInfo.processInfo.systemUptime,
                now: context.date
            )
        }
    }

    @ViewBuilder
    private func content(currentUptime: TimeInterval, now: Date) -> some View {
        let liveTurn = analyzer.turnGuidance
        let turnIsFresh = liveTurn.isFresh(at: currentUptime)
        let scale = Self.layoutScale(for: containerSize)
        let width = containerSize.width
        let height = containerSize.height
        let editor = HUDLayoutEditor.shared
        let wheelDiameter = height * wheelSize
        let wheelHub = CGPoint(x: width * wheelCenterX, y: height * wheelHubY)

        ZStack {
            if showsPathHighlight {
                RoadLineOverlay(observation: analyzer.roadLines, time: currentUptime, videoRect: videoRect)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .offset(x: videoRect.minX, y: videoRect.minY)
                }
                .allowsHitTesting(false)
            }

            if showsSteeringWheel || editor.isAdjustingWheel {
                SteeringWheelTargetView(
                    steering: liveTurn.steering(at: currentUptime),
                    accent: turnIsFresh && liveTurn.cue.stage != .unavailable ? HUDPalette.amber : HUDPalette.inactive,
                    diameter: wheelDiameter,
                    rotationOverride: editor.isAdjustingWheel ? editor.testRotation : nil
                )
                .overlay {
                    if highlightsItems {
                        Color.clear
                            .frame(width: wheelDiameter * 1.12, height: wheelDiameter * 1.12)
                            .overlayHighlight(.steeringWheel, true, isCircle: true)
                    }
                }
                .position(wheelHub)
                .frame(width: width, height: height)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .offset(x: videoRect.minX, y: videoRect.minY)
                }
                .allowsHitTesting(false)
            }

            if showsNavigationCard {
                NavigationCardView(turnCue: turnIsFresh ? liveTurn.cue : nil)
                    .fixedSize()
                    .overlayHighlight(.navigationCard, highlightsItems)
                    .scaleEffect(scale, anchor: .top)
                    .padding(.top, Self.bannerTopInset * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            if showsSessionPanel {
                SessionPanelView(elapsed: now.timeIntervalSince(sessionStart))
                .fixedSize()
                .overlayHighlight(.sessionPanel, highlightsItems, cornerRadius: 24)
                .scaleEffect(scale, anchor: .topTrailing)
                .padding(.top, Self.bannerTopInset * scale)
                .padding(.trailing, 34 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            }

            if showsSpeed {
                SpeedCardView(speed: analyzer.detectedSpeed, unit: analyzer.detectedSpeedUnit)
                    .fixedSize()
                    .overlayHighlight(.speed, highlightsItems)
                    .scaleEffect(scale, anchor: .bottomLeading)
                    .padding(.leading, width * 0.138)
                    .padding(.bottom, bottomInset(scale: scale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }

            if showsPedalAction {
                PedalActionCardView(action: .unavailable, timingOnly: true)
                    .fixedSize()
                    .overlayHighlight(.pedalAction, highlightsItems)
                    .scaleEffect(scale, anchor: .bottomTrailing)
                    .padding(.trailing, width * 0.138)
                    .padding(.bottom, bottomInset(scale: scale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }

            if editor.isAdjustingWheel {
                WheelAdjustOverlay(
                    containerSize: containerSize,
                    videoRect: videoRect,
                    centerX: $wheelCenterX,
                    hubY: $wheelHubY,
                    size: $wheelSize
                )
            }
        }
        .frame(width: width, height: height)
    }

    /// Keeps the bottom cards clear of the preview's control button row.
    private func bottomInset(scale: CGFloat) -> CGFloat {
        max(40 * scale, 62)
    }
}

// MARK: - Palette

private enum HUDPalette {
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.08).opacity(0.90)
    static let tile = Color(white: 0.13)
    static let stroke = Color.white.opacity(0.09)
    static let label = Color.white.opacity(0.66)
    static let faint = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.10)
    static let amber = Color(red: 0.98, green: 0.66, blue: 0.10)
    static let green = Color(red: 0.24, green: 0.84, blue: 0.40)
    static let red = Color(red: 1.00, green: 0.30, blue: 0.25)
    static let blue = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let cyan = Color(red: 0.25, green: 0.78, blue: 1.00)
    static let inactive = Color.white.opacity(0.35)

    static func status(_ state: MinimapCoachState) -> Color {
        switch state {
        case .ready: return green
        case .noWaypoint: return .orange
        case .routeUncertain, .stale: return amber
        case .analyzing: return blue
        case .minimapUnavailable: return inactive
        }
    }

    static func action(_ action: DrivingCoachAction) -> Color {
        switch action {
        case .brake: return red
        case .hold: return amber
        case .accelerateIfClear: return green
        case .unavailable, .setWaypoint: return inactive
        }
    }
}

private extension Font {
    static func hudLabel(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

private struct HUDPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(HUDPalette.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(HUDPalette.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private extension View {
    func hudPanel(cornerRadius: CGFloat = 22) -> some View {
        modifier(HUDPanelBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Navigation Card

/// One instruction from the same fresh cue that drives the steering target.
/// Preview and heads-up share wording; their internal distinction stays in review.
private struct NavigationCardView: View {
    let turnCue: TurnGuidanceSample?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var instruction: String { turnCue?.title ?? "Guidance unavailable" }
    private var isAvailable: Bool { turnCue.map { $0.stage != .unavailable } ?? false }
    private var isTurnNow: Bool { turnCue?.stage == .turnNow }
    private var symbol: String {
        guard let turnCue, isAvailable else { return "ellipsis" }
        if turnCue.stage == .straight { return "arrow.up" }
        return turnCue.direction == "left" ? "arrow.turn.up.left" : "arrow.turn.up.right"
    }
    private var foreground: Color {
        isTurnNow ? HUDPalette.amber : Color.white.opacity(isAvailable ? 1 : 0.75)
    }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .semibold))
                .frame(width: 44)
                .accessibilityHidden(true)
            Text(instruction)
                .font(.system(size: 28, weight: isTurnNow ? .bold : .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 22)
        .frame(width: 440, height: TrainerCoachHUD.bannerHeight)
        .background(reduceTransparency ? Color(white: 0.08) : HUDPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isTurnNow ? HUDPalette.amber : HUDPalette.stroke,
                              lineWidth: isTurnNow ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

// Road highlights come from RoadLineDetector in input-frame coordinates.
// No minimap-to-ground projection is used.

// MARK: - Session Timer

/// Session information is separate from turn guidance. The removed Upcoming
/// list used a different bend selector and could contradict the navigation card.
private struct SessionPanelView: View {
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            Text("Session")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HUDPalette.label)
            Text(Self.format(elapsed))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .hudPanel(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = max(interval, 0)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Speed Card

private struct SpeedCardView: View {
    let speed: Int?
    let unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(speed.map(String.init) ?? "---")
                .font(.system(size: 50, weight: .medium).monospacedDigit())
                .foregroundStyle(speed == nil ? HUDPalette.inactive : Color.white)
            Text((unit ?? "KM/H").uppercased())
                .font(.hudLabel(11))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .frame(minWidth: 180, minHeight: 76)
        .hudPanel(cornerRadius: 18)
    }
}

// MARK: - Pedal Action Card

private struct PedalActionCardView: View {
    let action: DrivingCoachAction
    var timingOnly = false

    /// 0 = full brake, 0.5 = hold, 1 = accelerate.
    private var position: CGFloat? {
        switch action {
        case .brake: return 0.12
        case .hold: return 0.5
        case .accelerateIfClear: return 0.88
        case .unavailable, .setWaypoint: return nil
        }
    }

    private var title: String {
        if timingOnly { return "TURN GUIDANCE" }
        switch action {
        case .unavailable: return "NO GUIDANCE"
        default: return action.title
        }
    }

    private var symbol: String {
        switch action {
        case .brake: return "arrow.down.to.line"
        case .hold: return "equal"
        case .accelerateIfClear: return "arrow.up"
        case .unavailable, .setWaypoint: return "minus"
        }
    }

    var body: some View {
        let color = HUDPalette.action(action)

        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if timingOnly {
                Text("Pedal timing is not calibrated")
                    .font(.hudLabel(12)).foregroundStyle(HUDPalette.label)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(HUDPalette.track)
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 7)
                            .offset(x: width * 0.5)
                        if let position {
                            let start = min(position, 0.5) * width
                            let end = max(position, 0.5) * width
                            Capsule()
                                .fill(color.opacity(0.85))
                                .frame(width: max(end - start, 8), height: 4)
                                .offset(x: position == 0.5 ? width * 0.5 - 4 : start)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color)
                                .frame(width: 2, height: 10)
                                .offset(x: width * position - 1)
                        }
                    }
                    .frame(height: 10)
                    .animation(.easeOut(duration: 0.2), value: position)
                }
                .frame(height: 10)

                HStack {
                    Text("BRAKE")
                    Spacer()
                    Text("HOLD")
                    Spacer()
                    Text("ACCEL")
                }
                .font(.hudLabel(11))
                .tracking(0.6)
                .foregroundStyle(HUDPalette.faint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 262)
        .hudPanel(cornerRadius: 18)
    }
}

// MARK: - Steering Wheel

/// The wheel artwork rotated to the coach's categorical steering target. The
/// angle is illustrative only: no wheel calibration exists (see
/// `SteeringGuidance.normalizedTarget`).
private struct SteeringWheelTargetView: View {
    let steering: SteeringGuidance
    let accent: Color
    let diameter: CGFloat
    /// Replaces the coach's target angle, in degrees (used by the editor).
    var rotationOverride: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Full-lock guidance is drawn as a quarter turn.
    private let maximumRotation = 90.0
    private let tickTargets: [Double] = [-0.6, -0.3, 0.3, 0.6]

    private var rotation: Double {
        rotationOverride ?? (steering.normalizedTarget ?? 0) * maximumRotation
    }

    var body: some View {
        let radius = diameter / 2
        let target = steering.normalizedTarget

        ZStack {
            // Fixed target ticks outside the rim.
            ForEach(tickTargets, id: \.self) { value in
                let angle = value * maximumRotation * .pi / 180
                let isTarget = target.map { abs($0 - value) < 0.01 } ?? false
                Circle()
                    .fill(isTarget ? accent : Color.white.opacity(0.28))
                    .frame(width: isTarget ? 7 : 4, height: isTarget ? 7 : 4)
                    .offset(
                        x: CGFloat(sin(angle)) * radius * 1.08,
                        y: -CGFloat(cos(angle)) * radius * 1.08
                    )
            }

            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 2, height: diameter * 0.03)
                .offset(y: -radius * 1.07)

            SteeringWheelShape(diameter: diameter, accent: accent, rotation: rotation)
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: rotation)
                .opacity(steering == .unavailable ? 0.55 : 0.95)
        }
        .frame(width: diameter * 1.3, height: diameter * 1.3)
    }
}

/// The wheel artwork (`SteeringWheel` in the asset catalog), rotated about its
/// hub. The PNG's hub sits below the image centre and its rim does not reach
/// the image edges, so both are corrected here to keep the rim at `diameter`.
private struct SteeringWheelShape: View {
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

// MARK: - Wheel Editor

/// Drag the wheel to move it, drag the handle (or pinch) to resize it, and
/// spin the test slider to check a full turn stays on screen. Values are
/// stored as fractions of the preview so they survive window resizes.
private struct WheelAdjustOverlay: View {
    let containerSize: CGSize
    let videoRect: CGRect
    @Binding var centerX: Double
    @Binding var hubY: Double
    @Binding var size: Double

    @State private var dragStart: (x: Double, y: Double)?
    @State private var pinchStart: Double?

    private var width: CGFloat { containerSize.width }
    private var height: CGFloat { containerSize.height }

    var body: some View {
        @Bindable var editor = HUDLayoutEditor.shared
        let hub = CGPoint(x: width * centerX, y: height * hubY)
        let turnRadius = height * size * SteeringWheelShape.turningRadius
        // The bottom of the wheel is meant to run off the video; only the
        // sides and top would look chopped mid-turn.
        let fits = hub.x - turnRadius >= videoRect.minX
            && hub.x + turnRadius <= videoRect.maxX
            && hub.y - turnRadius >= videoRect.minY
        let outline = fits ? Color.white : HUDPalette.red

        ZStack {
            // Area swept by the wheel at any rotation.
            Circle()
                .strokeBorder(outline, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(Circle().fill(Color.white.opacity(0.06)))
                .frame(width: turnRadius * 2, height: turnRadius * 2)
                .contentShape(Circle())
                .position(hub)
                .gesture(moveGesture)
                .simultaneousGesture(pinchGesture)

            // Resize handle on the right of the swept circle.
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .frame(width: 16, height: 16)
                .position(x: hub.x + turnRadius, y: hub.y)
                .gesture(resizeGesture(hub: hub))
                .help("Drag to resize the wheel")

            panel(editor: $editor, fits: fits)
                .padding(.leading, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .coordinateSpace(.named(Self.space))
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? (centerX, hubY)
                dragStart = start
                centerX = clamp(start.x + value.translation.width / width, 0...1)
                hubY = clamp(start.y + value.translation.height / height, 0...1)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? size
                pinchStart = start
                size = clamp(start * value.magnification, WheelPlacement.sizeRange)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func resizeGesture(hub: CGPoint) -> some Gesture {
        DragGesture(coordinateSpace: .named(WheelAdjustOverlay.space))
            .onChanged { value in
                let radius = hypot(value.location.x - hub.x, value.location.y - hub.y)
                size = clamp(radius / SteeringWheelShape.turningRadius / height, WheelPlacement.sizeRange)
            }
    }

    static let space = "wheelAdjust"

    private func panel(editor: Bindable<HUDLayoutEditor>, fits: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adjust Steering Wheel")
                .font(.system(size: 14, weight: .semibold))
            Text("Drag the wheel to move it. Drag the white handle or pinch to resize.")
                .font(.system(size: 12))
                .foregroundStyle(HUDPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Test turn")
                    .font(.system(size: 12))
                Slider(value: editor.testRotation, in: -360...360, step: 15)
                Text("\(Int(editor.wrappedValue.testRotation))°")
                    .font(.hudLabel(12))
                    .frame(width: 44, alignment: .trailing)
            }

            Text(String(format: "X %.3f · Y %.3f · SIZE %.3f", centerX, hubY, size))
                .font(.hudLabel(12))
                .foregroundStyle(HUDPalette.label)
                .textSelection(.enabled)

            if !fits {
                Label("The wheel's side or top leaves the video when it turns.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HUDPalette.red)
            }

            HStack {
                Button("Reset") {
                    centerX = WheelPlacement.defaultCenterX
                    hubY = WheelPlacement.defaultHubY
                    size = WheelPlacement.defaultSize
                    editor.wrappedValue.testRotation = 0
                }
                Spacer()
                Button("Done") {
                    editor.wrappedValue.isAdjustingWheel = false
                    editor.wrappedValue.testRotation = 0
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 320)
        .hudPanel(cornerRadius: 16)
        .environment(\.colorScheme, .dark)
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
