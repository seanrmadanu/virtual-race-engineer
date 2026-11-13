import AppKit
import SwiftUI

/// Off-screen render of the real checklist views in fixed states. No screen
/// capture and no running app: the views are hosted in an unshown window.
private struct Gallery: View {
    static let road = SetupSignals(receivingFrames: true, frameWidth: 1920, frameHeight: 1080,
                                   minimapVisible: true, routeDetected: true, noWaypoint: false, speedReadable: true)
    static let menu = SetupSignals(receivingFrames: true, frameWidth: 1920, frameHeight: 1080, gameMenuOpen: true)

    /// First run on the road: nothing read yet.
    @State private var first = SetupPreferences()
    /// In the game's Options: the unit and wheel page have been read.
    @State private var walking: SetupPreferences = {
        var p = SetupPreferences()
        _ = p.apply(SetupReading(value: "km/h", summary: "km/h"), for: .speedUnit)
        _ = p.apply(SetupReading(value: "auto", summary: ""), for: .steeringAngle)
        return p
    }()
    /// Everything read.
    @State private var all: SetupPreferences = {
        var p = SetupPreferences()
        _ = p.apply(SetupReading(value: "km/h", summary: "km/h"), for: .speedUnit)
        _ = p.apply(SetupReading(value: "auto", summary: ""), for: .steeringAngle)
        _ = p.apply(SetupReading(value: "", summary: "Auto steering off · Auto braking off"), for: .assists)
        _ = p.apply(SetupReading(value: "BMW M4 Competition", summary: "Top speed 290 km/h · Power 503 hp"), for: .car)
        return p
    }()
    @State private var hud = "motorfest-standard-v1"
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            SetupChecklistPanel(items: SetupChecklist.evaluate(signals: Self.road, preferences: first),
                                preferences: $first, hudProfile: $hud, scale: scale)
            SetupChecklistPanel(items: SetupChecklist.evaluate(signals: Self.menu, preferences: walking),
                                preferences: $walking, hudProfile: $hud, scale: scale)
            VStack(alignment: .trailing, spacing: 16) {
                SetupChecklistPanel(items: SetupChecklist.evaluate(signals: Self.road, preferences: all),
                                    preferences: $all, hudProfile: $hud, scale: scale)
                SetupChecklistButton(openRequired: 0, needsAttention: false, scale: scale)
                SetupChecklistButton(openRequired: 1, needsAttention: true, scale: scale)
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.45, green: 0.62, blue: 0.80), Color(red: 0.42, green: 0.45, blue: 0.40)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

@main
enum SetupChecklistRender {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("usage: render OUTPUT.png [scale]") }
        let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: Gallery(scale: scale))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("no png") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Rendered \(Int(size.width)) x \(Int(size.height)) at scale \(scale)")
    }
}
