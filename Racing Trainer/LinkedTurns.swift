import Foundation

nonisolated enum LinkedTurnPattern: String, Codable, CaseIterable {
    case unavailable = "unknown", noneVisible = "none_visible"
    case left, right, leftRight = "left_right", rightLeft = "right_left"

    var title: String {
        switch self {
        case .unavailable: return "Sequence unavailable"
        case .noneVisible: return "No bend sequence visible"
        case .left: return "One left bend visible"
        case .right: return "One right bend visible"
        case .leftRight: return "Left → right"
        case .rightLeft: return "Right → left"
        }
    }

    var directions: [String] {
        switch self {
        case .unavailable, .noneVisible: return []
        case .left: return ["left"]
        case .right: return ["right"]
        case .leftRight: return ["left", "right"]
        case .rightLeft: return ["right", "left"]
        }
    }
}

/// Spatial preview only: normalized map distances are neither seconds nor metres.
/// No control output, target speed, or assertion of current vehicle steering.
nonisolated struct LinkedTurnSample: Codable, Equatable, Sendable {
    let time: Double
    let pattern: LinkedTurnPattern
    let distances: [Double]
    let reason: String
    let evidenceCapturedAt: Double?
    let validUntil: Double?
    let isSequenceStart: Bool
    static let implementationVersion = "linked-turns-v1-route-preview"
    var version = Self.implementationVersion

    func validate() throws {
        guard time.isFinite, time >= 0, version == Self.implementationVersion, !reason.isEmpty,
              distances.count == pattern.directions.count,
              distances.allSatisfy({ $0.isFinite && $0 >= 0 }),
              distances.count < 2 || distances[1] - distances[0] >= 0.08 - 1e-9,
              !isSequenceStart || pattern != .unavailable else {
            throw ModelReviewError.invalid("Invalid linked-turn preview.")
        }
        if pattern != .unavailable {
            guard let capture = evidenceCapturedAt, let expiry = validUntil,
                  capture.isFinite, expiry.isFinite, capture >= 0, capture <= time,
                  expiry >= time, expiry <= capture + 0.65 + 1e-9 else {
                throw ModelReviewError.invalid("Linked turns lack fresh causal route evidence.")
            }
        } else if evidenceCapturedAt != nil || validUntil != nil {
            throw ModelReviewError.invalid("Unavailable linked turns cannot retain evidence.")
        }
    }
}

/// Confirms spatial bend order over distinct completed captures. Stationary
/// previews are allowed; speed is deliberately not used to infer turn timing.
nonisolated struct LinkedTurnTracker {
    private var session: Int?
    private var lastTime: Double?
    private var lastCapture: Double?
    private var candidate: LinkedTurnPattern?
    private var candidateDistances: [Double] = []
    private var since = 0.0
    private var count = 0
    private var accepted: LinkedTurnPattern?
    private var lastSample: LinkedTurnSample?

    mutating func reset() { self = Self() }

    mutating func update(row: CoachHistoryRow, session: Int) -> LinkedTurnSample {
        let time = row.time
        if self.session != session || lastTime.map({ time <= $0 || time - $0 > 0.75 }) == true { reset() }
        self.session = session; lastTime = time
        func usable(_ key: String, confidence: Float) -> Bool {
            row.observations[key]?.isUsable(at: time, sessionID: session,
                maximumAge: 0.65, minimumConfidence: confidence) == true
        }
        guard time.isFinite, time >= 0,
              usable("validity", confidence: 0), row.observations["validity"]?.value?.flag == true,
              usable("minimap", confidence: 0.52), row.observations["minimap"]?.value?.flag == true,
              usable("geometry", confidence: 0.52), let geometry = row.observations["geometry"],
              let points = geometry.value?.path, (8...4096).contains(points.count),
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }),
              let anchor = geometry.value?.playerAnchor, anchor.count == 2,
              anchor.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              ["minimap", "validity"].allSatisfy({ abs(row.observations[$0]!.capturedAt - geometry.capturedAt) <= 0.25 }) else {
            return unavailable(time, "Fresh route and player position are needed")
        }
        let path = points.map { MinimapPoint(x: $0[0], y: $0[1]) }
        guard let near = RouteTurnSelector.nearRoute(path, anchor: MinimapPoint(x: anchor[0], y: anchor[1])),
              let bends = RouteTurnSelector.visibleBends(path) else {
            return unavailable(time, "The visible route is not connected to the player")
        }
        let capture = geometry.capturedAt
        if let lastCapture, capture < lastCapture { return unavailable(time, "Route frames arrived out of order") }
        if capture == lastCapture, let sample = lastSample {
            guard sample.validUntil.map({ time <= $0 }) ?? true else {
                return unavailable(time, "The sequence evidence has expired")
            }
            return LinkedTurnSample(time: time, pattern: sample.pattern, distances: sample.distances,
                reason: sample.reason, evidenceCapturedAt: sample.evidenceCapturedAt,
                validUntil: sample.validUntil, isSequenceStart: false)
        }
        let captureGap = lastCapture.map { capture - $0 > 0.35 + 1e-9 } ?? false
        lastCapture = capture
        let first = bends.first
        // Two separated reversals support a sequence. A single long corner or
        // same-direction continuation must not become a fabricated second turn.
        let second = first.flatMap { first in bends.dropFirst().first.flatMap { next in
            next.change * first.change < 0 && next.distance - first.distance >= 0.08 ? next : nil
        } }
        let selected = [first, second].compactMap { $0 }
        let distances = selected.map { $0.distance + near.startGap }
        let pattern: LinkedTurnPattern = first == nil ? .noneVisible
            : second == nil ? (first!.change < 0 ? .left : .right)
            : first!.change < 0 ? .leftRight : .rightLeft
        let jumped = distances.count == candidateDistances.count && zip(distances, candidateDistances).contains { abs($0 - $1) > 0.06 }
        if candidate != pattern || captureGap || jumped {
            candidate = pattern; since = capture; count = 0; accepted = nil
        }
        candidateDistances = distances; count += 1
        guard accepted == pattern || (count >= 3 && capture - since >= 0.25 - 1e-9) else {
            return publish(time, .unavailable, [], "Confirming the visible bend order", nil, nil)
        }
        accepted = pattern
        let expiry = min(capture + 0.65, row.observations["minimap"]!.capturedAt + 0.65,
                         row.observations["validity"]!.capturedAt + 0.65)
        return publish(time, pattern, distances,
            selected.count == 2 ? "Two separated changes of direction in the visible route"
                : selected.isEmpty ? "The visible route has no supported heading changes" : "Only one supported bend is visible",
            capture, expiry)
    }

    private mutating func unavailable(_ time: Double, _ reason: String) -> LinkedTurnSample {
        candidate = nil; candidateDistances = []; count = 0; accepted = nil; lastCapture = nil
        return publish(time, .unavailable, [], reason, nil, nil)
    }

    private mutating func publish(_ time: Double, _ pattern: LinkedTurnPattern, _ distances: [Double],
                                 _ reason: String, _ capture: Double?, _ expiry: Double?) -> LinkedTurnSample {
        let sample = LinkedTurnSample(time: time, pattern: pattern, distances: distances, reason: reason,
            evidenceCapturedAt: capture, validUntil: expiry,
            isSequenceStart: pattern != .unavailable && lastSample?.pattern != pattern)
        lastSample = sample
        return sample
    }
}
