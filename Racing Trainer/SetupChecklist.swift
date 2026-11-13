import Foundation

/// What the app needs before turn guidance can work, as a list the app ticks
/// off by itself. Rules only: no pixels, no UI, and no clock of its own.
nonisolated enum SetupItemID: String, CaseIterable, Sendable {
    case video, picture, minimap, route, speed, speedUnit
    case steeringAngle, assists, car

    /// Guidance needs these today. The others are saved for wheel sizing and
    /// per-car braking; they never block "ready".
    var isRequired: Bool {
        switch self {
        case .video, .picture, .minimap, .route, .speed, .speedUnit: return true
        case .steeringAngle, .assists, .car: return false
        }
    }

    /// Ticked by reading a game menu the player shows, not by watching the road.
    var isReadFromMenus: Bool {
        switch self {
        case .speedUnit, .steeringAngle, .assists, .car: return true
        case .video, .picture, .minimap, .route, .speed: return false
        }
    }
}

nonisolated enum SetupItemStatus: String, Sendable {
    /// Satisfied.
    case done
    /// The app looked and did not find it.
    case missing
    /// Cannot be checked until an earlier item is done, or while a menu covers the road.
    case waiting
    /// The app has not seen it yet. The player shows it by opening the right screen.
    case showMe
}

nonisolated struct SetupItem: Equatable, Identifiable, Sendable {
    let id: SetupItemID
    let title: String
    let status: SetupItemStatus
    let detail: String
}

/// What the analyzer reports right now. Sampled for display only; this is
/// never used as guidance evidence.
nonisolated struct SetupSignals: Equatable, Sendable {
    var receivingFrames = false
    var frameWidth = 0
    var frameHeight = 0
    var minimapVisible = false
    var routeDetected = false
    /// The coach positively reports a visible minimap without a waypoint.
    var noWaypoint = false
    var speedReadable = false
    /// The last screen read saw a settings page, so the road HUD is covered.
    var gameMenuOpen = false
}

/// What the app has read from the game's screens (or, as a fallback, what the
/// player entered). An empty value means "not seen yet".
nonisolated struct SetupPreferences: Equatable, Sendable {
    var speedUnit = "km/h"
    /// A default unit is not a reading.
    var speedUnitConfirmed = false
    /// "auto" (the game sets it per car) or degrees.
    var steeringRange = ""
    /// The assists summary as read, e.g. "Auto steering off · Auto braking off".
    var assists = ""
    var carName = ""
    var carSpecs = ""
    /// Items whose value came from reading the screen, not from the player.
    var readFromScreen: Set<SetupItemID> = []

    /// Stores a confirmed screen reading. Returns false if nothing changed.
    mutating func apply(_ reading: SetupReading, for id: SetupItemID) -> Bool {
        let before = self
        switch id {
        case .speedUnit: speedUnit = reading.value; speedUnitConfirmed = true
        case .steeringAngle: steeringRange = reading.value
        case .assists: assists = reading.summary
        case .car: carName = reading.value; carSpecs = reading.summary
        case .video, .picture, .minimap, .route, .speed: return false
        }
        readFromScreen.insert(id)
        return self != before
    }

    /// Forgets one item so the app reads it again.
    mutating func clear(_ id: SetupItemID) {
        switch id {
        case .speedUnit: speedUnitConfirmed = false
        case .steeringAngle: steeringRange = ""
        case .assists: assists = ""
        case .car: carName = ""; carSpecs = ""
        case .video, .picture, .minimap, .route, .speed: return
        }
        readFromScreen.remove(id)
    }
}

nonisolated enum SetupChecklistStorage {
    static let speedUnitConfirmed = "setup.speedUnitConfirmed"
    static let steeringRange = "setup.steeringRange"
    static let assists = "setup.assists"
    static let carName = "setup.carName"
    static let carSpecs = "setup.carSpecs"
    static let readFromScreen = "setup.readFromScreen"

    static func encode(_ ids: Set<SetupItemID>) -> String {
        ids.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func decode(_ text: String) -> Set<SetupItemID> {
        Set(text.split(separator: ",").compactMap { SetupItemID(rawValue: String($0)) })
    }
}

nonisolated enum SetupChecklist {
    /// Wide enough for any consumer wheel; narrow enough to catch a misread.
    static let steeringAngleRange = 90...2520

    static func isValidSteeringAngle(_ degrees: Int) -> Bool {
        steeringAngleRange.contains(degrees)
    }

    static func evaluate(signals: SetupSignals, preferences: SetupPreferences) -> [SetupItem] {
        var items: [SetupItem] = []
        func add(_ id: SetupItemID, _ title: String, _ status: SetupItemStatus, _ detail: String) {
            items.append(SetupItem(id: id, title: title, status: status, detail: detail))
        }
        func source(_ id: SetupItemID) -> String {
            preferences.readFromScreen.contains(id) ? "read from the game" : "entered by you"
        }

        let live = signals.receivingFrames
        let hasSize = signals.frameWidth > 0 && signals.frameHeight > 0
        let size = "\(signals.frameWidth) × \(signals.frameHeight)"
        if live {
            add(.video, "Video signal", .done, hasSize ? "Receiving \(size)" : "Receiving video")
        } else {
            add(.video, "Video signal", .missing, "No new frames. Play the video or check the capture card.")
        }

        let ratio = hasSize ? Double(signals.frameWidth) / Double(signals.frameHeight) : 0
        let wide = hasSize && abs(ratio - 16.0 / 9.0) < 0.025
        if !live || !hasSize {
            add(.picture, "Full 16:9 picture", .waiting, "Waiting for video")
        } else if wide {
            add(.picture, "Full 16:9 picture", .done, "16:9 picture")
        } else {
            add(.picture, "Full 16:9 picture", .missing,
                "The picture is \(size). Send the full 16:9 game picture, not cropped or stretched.")
        }

        // The HUD crops assume a 16:9 frame, so nothing below can be judged without one.
        let pictureReady = live && wide
        let pictureWait = live ? "Waiting for a 16:9 picture" : "Waiting for video"
        // A settings page covers the road HUD. That is expected during setup, not a fault.
        let inMenu = pictureReady && signals.gameMenuOpen
        let menuWait = "Game menu open. Checked when you're back on the road."

        if !pictureReady {
            add(.minimap, "Minimap", .waiting, pictureWait)
        } else if signals.minimapVisible {
            add(.minimap, "Minimap", .done, "Minimap found")
        } else if inMenu {
            add(.minimap, "Minimap", .waiting, menuWait)
        } else {
            add(.minimap, "Minimap", .missing,
                "Can't find the minimap. Use Motorfest's default HUD and close any menu or map.")
        }

        if !(pictureReady && signals.minimapVisible) {
            add(.route, "GPS route", .waiting, inMenu ? menuWait : "Waiting for the minimap")
        } else if signals.routeDetected {
            add(.route, "GPS route", .done, "Route found")
        } else if signals.noWaypoint {
            add(.route, "GPS route", .missing, "No route on the minimap. Set a waypoint or start an event.")
        } else {
            add(.route, "GPS route", .missing, "Can't follow the route right now. Set a waypoint if there isn't one.")
        }

        if !pictureReady {
            add(.speed, "Speedometer", .waiting, pictureWait)
        } else if signals.speedReadable {
            add(.speed, "Speedometer", .done, "Speed readable")
        } else if inMenu {
            add(.speed, "Speedometer", .waiting, menuWait)
        } else {
            add(.speed, "Speedometer", .missing, "Can't read the speed. Try the other HUD layout.")
        }

        let unitReady = preferences.speedUnitConfirmed && ["km/h", "mph"].contains(preferences.speedUnit)
        add(.speedUnit, "Speed unit", unitReady ? .done : .showMe,
            unitReady ? "\(preferences.speedUnit), \(source(.speedUnit))"
                      : "Looking at the speedometer. Or open Options › Game Settings so the app can read Unit.")

        let range = preferences.steeringRange
        let rangeReady = range == "auto" || Int(range).map(isValidSteeringAngle) == true
        add(.steeringAngle, "Steering range", rangeReady ? .done : .showMe,
            rangeReady ? (range == "auto" ? "Set per car by the game (Dynamic Range on)" : "\(range)°, \(source(.steeringAngle))")
                       : "Open Options › Controls › Wheel Controls so the app can read Dynamic Range.")

        add(.assists, "Driving assists", preferences.assists.isEmpty ? .showMe : .done,
            preferences.assists.isEmpty
                ? "Open Options › Difficulty so the app can read Auto Steering and Auto Braking."
                : preferences.assists)

        let car = preferences.carName.trimmingCharacters(in: .whitespacesAndNewlines)
        let specs = preferences.carSpecs.isEmpty ? "" : " · \(preferences.carSpecs)"
        add(.car, "Car", car.isEmpty ? .showMe : .done,
            car.isEmpty ? "Open your car's stats screen so the app can read its name and specs."
                        : "\(car)\(specs)")

        return items
    }

    /// Guidance can run. Optional items do not count.
    static func isReady(_ items: [SetupItem]) -> Bool {
        items.filter { $0.id.isRequired }.allSatisfy { $0.status == .done }
    }

    /// Items the player can act on now. A waiting item clears once the one before it does.
    static func openCount(_ items: [SetupItem], required: Bool) -> Int {
        items.filter { $0.id.isRequired == required && ($0.status == .missing || $0.status == .showMe) }.count
    }
}

/// Detections flicker from frame to frame. A found item stays found for a short
/// hold so the list does not blink; a real loss still shows once the hold ends.
nonisolated struct SetupSignalStabilizer {
    static let hold = 2.0
    private var lastSeen: [SetupItemID: Double] = [:]
    private var lastTime: Double?

    mutating func update(_ raw: SetupSignals, at time: Double) -> SetupSignals {
        guard time.isFinite else { return raw }
        // A new source or a clock that ran backwards must not inherit old sightings.
        if raw.frameWidth == 0 || lastTime.map({ time < $0 }) == true { lastSeen = [:] }
        lastTime = time
        var held = raw
        held.minimapVisible = hold(.minimap, raw.minimapVisible, at: time)
        held.routeDetected = hold(.route, raw.routeDetected, at: time)
        held.speedReadable = hold(.speed, raw.speedReadable, at: time)
        if held.routeDetected { held.noWaypoint = false }
        return held
    }

    private mutating func hold(_ id: SetupItemID, _ seen: Bool, at time: Double) -> Bool {
        if seen { lastSeen[id] = time; return true }
        return time - (lastSeen[id] ?? -.infinity) <= Self.hold
    }
}

/// When the checklist opens and closes by itself. It opens once, if setup is
/// still incomplete after a short grace; it closes once everything needed is
/// found. Anything the player does takes over from there.
nonisolated struct SetupChecklistPresentation: Equatable {
    /// Detection needs a moment after video starts; do not flash the panel.
    static let expandDelay = 2.5
    static let collapseDelay = 1.5
    /// How long something must be missing before the closed button flags it.
    static let attentionDelay = 5.0

    private(set) var isExpanded = false
    private(set) var needsAttention = false
    private var startedAt: Double?
    private var readySince: Double?
    private var notReadySince: Double?
    /// The player opened or edited the panel: never close it for them.
    private var pinned = false
    /// Setup completed once, or the player took over: never open it for them.
    private var settled = false

    mutating func update(isReady: Bool, at time: Double) {
        guard time.isFinite else { return }
        if startedAt == nil { startedAt = time }
        if isReady {
            notReadySince = nil
            needsAttention = false
            if readySince == nil { readySince = time }
            if time - (readySince ?? time) >= Self.collapseDelay {
                settled = true
                if isExpanded && !pinned { isExpanded = false }
            }
        } else {
            readySince = nil
            if notReadySince == nil { notReadySince = time }
            if !settled && !isExpanded && time - (startedAt ?? time) >= Self.expandDelay {
                isExpanded = true
                settled = true
            }
            needsAttention = !isExpanded && time - (notReadySince ?? time) >= Self.attentionDelay
        }
    }

    /// The player pressed the Setup button or the panel's close button.
    mutating func toggle() {
        isExpanded.toggle()
        pinned = isExpanded
        settled = true
        if isExpanded { needsAttention = false }
    }

    /// The player changed something in the panel.
    mutating func userInteracted() {
        pinned = true
        settled = true
    }
}
