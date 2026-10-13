import Foundation

nonisolated struct ShadowSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case liveCapture, videoFile, syntheticTest }
    let kind: Kind
    let identifier: String
    let name: String
}

nonisolated struct ShadowTicket: Sendable {
    let sequence: Int
    let generation: Int
    let source: ShadowSource
    let sourcePTS: Double
    let receivedAt: Double
}

/// Pure ingress state. The pipeline locks this state; expensive work never holds that lock.
nonisolated struct ShadowCaptureGate {
    private(set) var source: ShadowSource?
    private(set) var generation = 0
    private(set) var sourceToken = 0
    private(set) var resetReason = "initial"
    private(set) var dropped: [String: Int] = [:]
    private(set) var lastArrival: Double?
    private var lastPTS: Double?
    private var lastAccepted: Double?
    private var sequence = 0
    private var inFlight: Int?

    mutating func begin(_ source: ShadowSource) -> Int {
        self.source = source
        reset("source_changed")
        sourceToken += 1
        return sourceToken
    }

    mutating func reset(_ reason: String, stop: Bool = false) {
        generation += 1; resetReason = reason
        lastArrival = nil; lastPTS = nil; lastAccepted = nil
        if stop { source = nil }
        // Keep inFlight until that exact work finishes. A reset must not grow the work queue.
    }

    mutating func drop(_ reason: String) { dropped[reason, default: 0] += 1 }

    mutating func reserve(sourceToken: Int, pts: Double, receivedAt: Double, now: Double) -> ShadowTicket? {
        guard let source, sourceToken == self.sourceToken else { drop("old_source_token"); return nil }
        guard pts.isFinite, pts >= 0, receivedAt.isFinite, now.isFinite,
              receivedAt >= 0, now >= receivedAt else { drop("invalid_clock"); return nil }
        guard now - receivedAt <= 0.25 else { drop("stale_delivery"); return nil }
        if let previous = lastArrival, receivedAt <= previous { drop("nonincreasing_arrival"); return nil }
        if let previous = lastArrival, receivedAt - previous > 0.75 {
            generation += 1; resetReason = "arrival_gap"; lastAccepted = nil
            lastPTS = nil
        }
        // Explicit callers reset on seeks. Unexpected PTS discontinuities fail closed as well.
        if let previous = lastPTS, pts <= previous {
            let reason = pts == previous ? "duplicate_source_frame" : "backward_source_clock"
            generation += 1; resetReason = reason; lastAccepted = nil; drop(reason)
            lastPTS = pts
            // Do not refresh lastArrival: the watchdog will invalidate a frozen source.
            return nil
        }
        if let previousPTS = lastPTS, let previousArrival = lastArrival,
           abs((pts - previousPTS) - (receivedAt - previousArrival)) > 0.5 {
            generation += 1; resetReason = "source_clock_discontinuity"; lastAccepted = nil
            lastPTS = pts; lastArrival = receivedAt; drop(resetReason)
            return nil
        }
        lastPTS = pts; lastArrival = receivedAt
        guard inFlight == nil else { drop("worker_busy"); return nil }
        guard lastAccepted.map({ receivedAt - $0 >= 0.1 - 1e-6 }) ?? true else {
            drop("rate_limit"); return nil
        }
        sequence += 1; inFlight = sequence; lastAccepted = receivedAt
        return ShadowTicket(sequence: sequence, generation: generation, source: source, sourcePTS: pts, receivedAt: receivedAt)
    }

    mutating func finish(_ ticket: ShadowTicket, at now: Double) -> Bool {
        guard inFlight == ticket.sequence else { drop("unknown_completion"); return false }
        inFlight = nil
        guard ticket.generation == generation, ticket.source == source else { drop("obsolete_completion"); return false }
        guard now.isFinite, now >= ticket.receivedAt, now - ticket.receivedAt <= 0.75 else {
            drop("stale_completion"); return false
        }
        return true
    }

    func completionIsCurrent(_ ticket: ShadowTicket, at now: Double) -> Bool {
        inFlight == ticket.sequence && ticket.generation == generation && ticket.source == source &&
        now.isFinite && now >= ticket.receivedAt && now - ticket.receivedAt <= 0.75
    }

    /// Keep the source token, but invalidate all pending work and history. Retain the PTS barrier.
    mutating func watchdog(now: Double) -> Bool {
        guard let lastArrival, now - lastArrival > 0.75 else { return false }
        generation += 1; resetReason = "capture_interruption"; self.lastArrival = nil; lastAccepted = nil
        return true
    }
}
