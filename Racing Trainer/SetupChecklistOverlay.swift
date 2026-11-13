import SwiftUI

/// The setup checklist on the practice screen. The app ticks the items itself:
/// road items by watching the HUD, menu items by reading the game's screens
/// while the player moves through them. It samples the analyzer twice a second
/// instead of observing it, and never takes part in guidance.
struct SetupChecklistOverlay: View {
    let analyzer: FrameAnalyzer
    let containerSize: CGSize
    /// A test video is paused: not a missing signal.
    var isPaused = false

    // The same keys the Guidance menu uses; a reading here changes it there.
    @AppStorage("guidance.speedUnit") private var speedUnit = "km/h"
    @AppStorage("guidance.hudProfile") private var hudProfile = "motorfest-standard-v1"
    @AppStorage(SetupChecklistStorage.speedUnitConfirmed) private var speedUnitConfirmed = false
    @AppStorage(SetupChecklistStorage.steeringRange) private var steeringRange = ""
    @AppStorage(SetupChecklistStorage.assists) private var assists = ""
    @AppStorage(SetupChecklistStorage.carName) private var carName = ""
    @AppStorage(SetupChecklistStorage.carSpecs) private var carSpecs = ""
    @AppStorage(SetupChecklistStorage.readFromScreen) private var readFromScreen = ""

    @State private var signals = SetupSignals()
    @State private var stabilizer = SetupSignalStabilizer()
    @State private var presentation = SetupChecklistPresentation()
    @State private var confirmer = SetupReadingConfirmer()
    @State private var isReadingScreen = false
    @State private var gameMenuOpen = false
    @State private var lastScanAt = -Double.infinity

    /// One screen read a second is enough for a menu and keeps the cost low.
    private static let scanInterval = 0.9

    private var currentPreferences: SetupPreferences {
        SetupPreferences(speedUnit: speedUnit, speedUnitConfirmed: speedUnitConfirmed,
                         steeringRange: steeringRange, assists: assists, carName: carName, carSpecs: carSpecs,
                         readFromScreen: SetupChecklistStorage.decode(readFromScreen))
    }

    private func store(_ new: SetupPreferences) {
        // Write only what changed: a speed-unit write resets the analyzer.
        if new.speedUnit != speedUnit { speedUnit = new.speedUnit }
        if new.speedUnitConfirmed != speedUnitConfirmed { speedUnitConfirmed = new.speedUnitConfirmed }
        if new.steeringRange != steeringRange { steeringRange = new.steeringRange }
        if new.assists != assists { assists = new.assists }
        if new.carName != carName { carName = new.carName }
        if new.carSpecs != carSpecs { carSpecs = new.carSpecs }
        let sources = SetupChecklistStorage.encode(new.readFromScreen)
        if sources != readFromScreen { readFromScreen = sources }
    }

    var body: some View {
        let items = SetupChecklist.evaluate(signals: signals, preferences: currentPreferences)
        let hudScale = TrainerCoachHUD.layoutScale(for: containerSize)
        let scale = min(max(hudScale, 0.8), 1.15)
        let top = TrainerCoachHUD.bannerBottom(for: containerSize) + 8
        let available = max(160, containerSize.height - top - 16)

        Group {
            if presentation.isExpanded {
                SetupChecklistPanel(
                    items: items,
                    preferences: Binding(get: { currentPreferences }, set: { store($0) }),
                    hudProfile: $hudProfile, scale: scale, isWatching: signals.receivingFrames || signals.paused,
                    onInteraction: { presentation.userInteracted() },
                    onClose: { withAnimation(.easeOut(duration: 0.18)) { presentation.toggle() } })
                    .frame(maxHeight: available, alignment: .top)
                    .transition(.opacity)
            } else {
                SetupChecklistButton(
                    openRequired: SetupChecklist.openCount(items, required: true),
                    needsAttention: presentation.needsAttention, scale: scale,
                    action: { withAnimation(.easeOut(duration: 0.18)) { presentation.toggle() } })
                    .transition(.opacity)
            }
        }
        .padding(.top, top)
        .padding(.trailing, 34 * hudScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .task { await watch() }
        .onDisappear { analyzer.setKeepsLatestFrame(false) }
    }

    private func watch() async {
        while !Task.isCancelled {
            sample()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var raw = SetupSignals()
        raw.receivingFrames = analyzer.lastFrameDate.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        raw.frameWidth = analyzer.frameWidth
        raw.frameHeight = analyzer.frameHeight
        raw.minimapVisible = analyzer.minimapVisible
        raw.routeDetected = analyzer.yellowRouteDetected
        raw.noWaypoint = analyzer.coachSnapshot.state == .noWaypoint
        raw.speedReadable = analyzer.detectedSpeed != nil
        raw.gameMenuOpen = gameMenuOpen
        raw.paused = isPaused
        let held = stabilizer.update(raw, at: now)
        if held != signals { signals = held }

        let items = SetupChecklist.evaluate(signals: held, preferences: currentPreferences)
        var next = presentation
        next.update(isReady: SetupChecklist.isReady(items), at: now)
        if next != presentation {
            withAnimation(.easeOut(duration: 0.18)) { presentation = next }
        }

        // The screen is read only while the checklist is open.
        analyzer.setKeepsLatestFrame(next.isExpanded)
        guard next.isExpanded else {
            confirmer.reset()
            if gameMenuOpen { gameMenuOpen = false }
            return
        }
        if !isReadingScreen, now - lastScanAt >= Self.scanInterval, let frame = analyzer.latestFrame() {
            lastScanAt = now
            readScreen(frame)
        }
    }

    private func readScreen(_ frame: CVPixelBuffer) {
        isReadingScreen = true
        let box = FrameBox(buffer: frame)
        Task {
            // Off the main thread and off the analyzer's queues.
            let lines = await Task.detached(priority: .utility) { SetupScreenReader.lines(in: box.buffer) }.value
            isReadingScreen = false
            let menu = SetupScreenMatcher.looksLikeSettingsMenu(lines)
            if menu != gameMenuOpen { gameMenuOpen = menu }
            var preferences = currentPreferences
            var changed = false
            for (id, reading) in confirmer.confirm(SetupScreenMatcher.read(lines)) {
                changed = preferences.apply(reading, for: id) || changed
            }
            if changed { store(preferences) }
        }
    }
}

/// Hands one frame to the background reader. The buffer is only read.
private struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
