import Foundation

// MARK: - Shared Minimap Geometry

/// A normalized point inside the minimap crop. `(0, 0)` is the crop's
/// top-left corner and `(1, 1)` is its bottom-right corner.
nonisolated struct MinimapPoint:
    Equatable,
    Sendable {

    let x: Double
    let y: Double

    func clamped() -> MinimapPoint {
        MinimapPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

// MARK: - Operational State

nonisolated enum MinimapCoachState:
    String,
    Sendable {

    case analyzing
    case ready
    case noWaypoint
    case minimapUnavailable
    case routeUncertain
    case stale

    var title: String {
        switch self {
        case .analyzing:
            return "ANALYZING MINIMAP"
        case .ready:
            return "COACH READY"
        case .noWaypoint:
            return "SET A WAYPOINT"
        case .minimapUnavailable:
            return "MINIMAP / GAMEPLAY NOT FOUND"
        case .routeUncertain:
            return "ROUTE UNCERTAIN"
        case .stale:
            return "GUIDANCE STALE"
        }
    }
}

// MARK: - Turn Description

nonisolated enum RouteTurnDirection:
    String,
    Sendable {

    case unknown
    case straight
    case left
    case right
    case uTurnLeft
    case uTurnRight

    var title: String {
        switch self {
        case .unknown:
            return "UNKNOWN"
        case .straight:
            return "STRAIGHT"
        case .left:
            return "LEFT"
        case .right:
            return "RIGHT"
        case .uTurnLeft:
            return "U-TURN LEFT"
        case .uTurnRight:
            return "U-TURN RIGHT"
        }
    }

    var isTurn: Bool {
        self != .unknown && self != .straight
    }

    var sideSign: Double {
        switch self {
        case .left, .uTurnLeft:
            return -1
        case .right, .uTurnRight:
            return 1
        case .unknown, .straight:
            return 0
        }
    }
}

nonisolated enum TurnSeverity:
    String,
    Sendable {

    case unknown
    case straight
    case gentle
    case medium
    case sharp
    case uTurn

    var title: String {
        rawValue.uppercased()
    }

    var urgencyRank: Int {
        switch self {
        case .unknown:
            return -1
        case .straight:
            return 0
        case .gentle:
            return 1
        case .medium:
            return 2
        case .sharp:
            return 3
        case .uTurn:
            return 4
        }
    }
}

nonisolated enum TurnTiming:
    String,
    Sendable {

    case unknown
    case none
    case later
    case soon
    case now

    var title: String {
        switch self {
        case .unknown:
            return "UNKNOWN"
        case .none:
            return "CLEAR"
        default:
            return rawValue.uppercased()
        }
    }

    var urgencyRank: Int {
        switch self {
        case .unknown:
            return -1
        case .none:
            return 0
        case .later:
            return 1
        case .soon:
            return 2
        case .now:
            return 3
        }
    }
}

// MARK: - Conservative Guidance

nonisolated enum DrivingCoachAction:
    String,
    Sendable {

    case unavailable
    case setWaypoint
    case brake
    case hold
    case accelerateIfClear

    var title: String {
        switch self {
        case .unavailable:
            return "GUIDANCE UNAVAILABLE"
        case .setWaypoint:
            return "SET A WAYPOINT"
        case .brake:
            return "BRAKE"
        case .hold:
            return "HOLD"
        case .accelerateIfClear:
            return "ACCELERATE IF CLEAR"
        }
    }
}

nonisolated enum SteeringGuidance:
    String,
    Sendable {

    case unavailable
    case center
    case slightLeft
    case left
    case hardLeft
    case slightRight
    case right
    case hardRight

    var title: String {
        switch self {
        case .unavailable:
            return "STEERING UNAVAILABLE"
        case .center:
            return "CENTER"
        case .slightLeft:
            return "SLIGHT LEFT"
        case .left:
            return "LEFT"
        case .hardLeft:
            return "HARD LEFT"
        case .slightRight:
            return "SLIGHT RIGHT"
        case .right:
            return "RIGHT"
        case .hardRight:
            return "HARD RIGHT"
        }
    }

    /// A categorical, normalized steering target. This is deliberately not
    /// presented as wheel degrees because no G29/vehicle calibration exists.
    var normalizedTarget: Double? {
        switch self {
        case .unavailable:
            return nil
        case .center:
            return 0
        case .slightLeft:
            return -0.3
        case .left:
            return -0.6
        case .hardLeft:
            return -1
        case .slightRight:
            return 0.3
        case .right:
            return 0.6
        case .hardRight:
            return 1
        }
    }
}

// MARK: - Confidence

/// Confidence remains separated internally so one strong subsystem cannot
/// hide a critical failure in another subsystem.
nonisolated struct MinimapConfidenceBreakdown:
    Equatable,
    Sendable {

    let minimap: Float
    let playerAnchor: Float
    let routeMask: Float
    let forwardPath: Float
    let geometry: Float
    let temporalStability: Float
    let freshness: Float
    let motionTracking: Float

    var criticalMinimum: Float {
        [
            minimap,
            playerAnchor,
            routeMask,
            forwardPath,
            geometry,
            temporalStability,
            freshness,
            motionTracking
        ]
        .min() ?? 0
    }

    static let zero =
        MinimapConfidenceBreakdown(
            minimap: 0,
            playerAnchor: 0,
            routeMask: 0,
            forwardPath: 0,
            geometry: 0,
            temporalStability: 0,
            freshness: 0,
            motionTracking: 0
        )
}

// MARK: - Speed Synchronization

nonisolated struct MinimapSpeedSample:
    Equatable,
    Sendable {

    let value: Int
    let confidence: Float
    let sourceFrameUptime: TimeInterval
}

// MARK: - Published Coach Result

nonisolated struct MinimapCoachSnapshot:
    Sendable {

    let state: MinimapCoachState
    let confidence: MinimapConfidenceBreakdown
    let direction: RouteTurnDirection
    let severity: TurnSeverity
    let timing: TurnTiming
    let action: DrivingCoachAction
    let steering: SteeringGuidance
    let orderedPath: [MinimapPoint]
    let turnStartPoint: MinimapPoint?
    let turnStartNormalizedDistance: Double?
    let pathPointCount: Int
    let branchPointCount: Int
    let speedUsed: Int?
    let speedAgeMilliseconds: Double?
    let sourceFrameUptime: TimeInterval
    let processingLatencyMilliseconds: Double
    let trackingApplied: Bool
    let reason: String

    var overallConfidence: Float {
        confidence.criticalMinimum
    }

    var guidanceAvailable: Bool {
        state == .ready && action != .unavailable
    }

    func safeGuidanceAvailable(
        at currentUptime: TimeInterval
    ) -> Bool {
        displayedState(at: currentUptime) == .ready &&
        action != .unavailable
    }

    func ageMilliseconds(
        at currentUptime: TimeInterval
    ) -> Double {
        max(currentUptime - sourceFrameUptime, 0) * 1000
    }

    func displayedState(
        at currentUptime: TimeInterval
    ) -> MinimapCoachState {
        guard state == .ready else {
            return state
        }

        return ageMilliseconds(at: currentUptime) <= 650
            ? .ready
            : .stale
    }

    static let empty =
        MinimapCoachSnapshot(
            state: .analyzing,
            confidence: .zero,
            direction: .unknown,
            severity: .unknown,
            timing: .unknown,
            action: .unavailable,
            steering: .unavailable,
            orderedPath: [],
            turnStartPoint: nil,
            turnStartNormalizedDistance: nil,
            pathPointCount: 0,
            branchPointCount: 0,
            speedUsed: nil,
            speedAgeMilliseconds: nil,
            sourceFrameUptime: 0,
            processingLatencyMilliseconds: 0,
            trackingApplied: false,
            reason: "Waiting for a gameplay frame."
        )
}
