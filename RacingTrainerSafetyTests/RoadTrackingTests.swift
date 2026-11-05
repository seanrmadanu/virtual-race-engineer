import XCTest

/// Frame-to-frame road-line tracking: steady display, no evidence outliving its frame.
final class RoadTrackingTests: XCTestCase {
    private static let frame = 1.0 / 60

    /// Paint pixels along a left and a right lane line, optionally shifted.
    private func paint(left: Bool = true, right: Bool = true, shift: Double = 0) -> [RoadPaintCandidate] {
        stride(from: 0.45, through: 0.80, by: 0.005).flatMap { y -> [RoadPaintCandidate] in
            var row: [RoadPaintCandidate] = []
            if left { row.append(RoadPaintCandidate(x: 0.5 - 0.95 * (y - 0.4) + shift, y: y, color: .yellow, strength: 60)) }
            if right { row.append(RoadPaintCandidate(x: 0.5 + 1.15 * (y - 0.4) + shift, y: y, color: .white, strength: 60)) }
            return row
        }
    }

    private func x(_ edge: [RoadPoint], at y: Double) -> Double? {
        for (a, b) in zip(edge, edge.dropFirst()) where a.y <= y && b.y >= y && b.y > a.y {
            return a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
        }
        return nil
    }

    func testLinesAppearAfterConfirmationAndHoldThroughBriefDropout() {
        var tracker = RoadLineTracker()
        var time = 10.0
        var result = tracker.update(candidates: paint(), at: time)
        XCTAssertFalse(result.display.hasBoundary, "One frame is not enough to show a line")
        for _ in 0..<12 { time += Self.frame; result = tracker.update(candidates: paint(), at: time) }
        XCTAssertTrue(result.display.hasCorridor, result.display.reason)
        XCTAssertTrue(result.observation.hasCorridor)

        // 0.15 s without paint: still drawn, but guidance gets nothing.
        for _ in 0..<9 { time += Self.frame; result = tracker.update(candidates: [], at: time) }
        XCTAssertTrue(result.display.hasCorridor)
        XCTAssertFalse(result.observation.hasBoundary)

        // Past the hold time the lines are gone.
        for _ in 0..<30 { time += Self.frame; result = tracker.update(candidates: [], at: time) }
        XCTAssertFalse(result.display.hasBoundary)
    }

    func testSingleFrameGlintsAreNeverShown() {
        var tracker = RoadLineTracker()
        var time = 0.0
        for frame in 0..<60 {
            time += Self.frame
            // A spurious line flashes every fifth frame.
            let result = tracker.update(candidates: frame % 5 == 0 ? paint(right: false) : [], at: time)
            XCTAssertFalse(result.display.hasBoundary, "frame \(frame)")
        }
    }

    func testJitterIsSmoothedButSteadyMotionIsFollowed() {
        var tracker = RoadLineTracker()
        var time = 0.0
        var shown: [Double] = []
        for frame in 0..<60 {
            time += Self.frame
            let jitter = frame % 2 == 0 ? 0.006 : -0.006
            let result = tracker.update(candidates: paint(shift: jitter), at: time)
            if frame >= 20, let value = x(result.display.left, at: 0.6) { shown.append(value) }
        }
        let steps = zip(shown, shown.dropFirst()).map { abs($1 - $0) }
        XCTAssertFalse(steps.isEmpty)
        XCTAssertLessThan(steps.max()!, 0.006, "Displayed line moves less than half the raw 0.012 frame-to-frame jump")

        // A line drifting steadily is followed closely, not left behind.
        var drifting = RoadLineTracker()
        time = 0
        var last: RoadLineObservation?
        for frame in 0..<60 {
            time += Self.frame
            last = drifting.update(candidates: paint(shift: Double(frame) * 0.001), at: time).display
        }
        let expected = 0.5 - 0.95 * 0.2 + 0.059
        XCTAssertEqual(x(last!.left, at: 0.6)!, expected, accuracy: 0.01)
    }

    func testSeekOrSourceChangeStartsOver() {
        var tracker = RoadLineTracker()
        var time = 5.0
        for _ in 0..<12 { time += Self.frame; _ = tracker.update(candidates: paint(), at: time) }
        XCTAssertFalse(tracker.tracks.isEmpty)
        // Time going backwards (seek) clears everything learned so far.
        let result = tracker.update(candidates: paint(), at: 1.0)
        XCTAssertFalse(result.display.hasBoundary)
        XCTAssertTrue(tracker.tracks.allSatisfy { $0.hits == 1 })
    }

    func testDisplayKeepsSameLaneLinesWhenANeighbourIsSlightlyCloser() {
        var tracker = RoadLineTracker()
        var time = 0.0
        var result = tracker.update(candidates: paint(), at: time)
        for _ in 0..<12 { time += Self.frame; result = tracker.update(candidates: paint(), at: time) }
        let leftBefore = x(result.observation.left, at: 0.6)
        // A second, fainter left line appears just inside the first.
        for _ in 0..<12 {
            time += Self.frame
            let extra = stride(from: 0.5, through: 0.75, by: 0.005).map {
                RoadPaintCandidate(x: 0.5 - 0.95 * ($0 - 0.4) + 0.02, y: $0, color: .white, strength: 30)
            }
            result = tracker.update(candidates: paint() + extra, at: time)
        }
        XCTAssertEqual(x(result.observation.left, at: 0.6)!, leftBefore!, accuracy: 0.005)
    }

    // MARK: Drawing animation

    private func lane(shift: Double = 0, at time: Double, corridor: Bool = true) -> RoadLineObservation {
        let left = stride(from: 0.5, through: 0.75, by: 0.25 / 15).map { RoadPoint(x: 0.5 - 0.95 * ($0 - 0.4) + shift, y: $0) }
        let right = left.map { RoadPoint(x: 0.5 + 1.15 * ($0.y - 0.4) + shift, y: $0.y) }
        return RoadLineObservation(capturedAt: time, left: left, right: corridor ? right : [], confidence: 0.9, reason: "fixture")
    }

    func testDrawnLinesFadeInsteadOfPopping() {
        let animator = RoadOverlayAnimator()
        var time = 1.0
        var frame = animator.frame(for: lane(at: time), at: time)
        XCTAssertLessThan(frame.corridors.first?.opacity ?? 0, 0.2, "First frame must not appear at full strength")
        for _ in 0..<20 { time += Self.frame; frame = animator.frame(for: lane(at: time), at: time) }
        XCTAssertEqual(frame.corridors.first?.opacity ?? 0, 1, accuracy: 0.001)
        // Lines vanish from the data: they ease out over the fade time, not at once.
        time += Self.frame
        frame = animator.frame(for: .unavailable(at: time, reason: "gone"), at: time)
        XCTAssertGreaterThan(frame.corridors.first?.opacity ?? 0, 0.8)
        for _ in 0..<20 { time += Self.frame; frame = animator.frame(for: .unavailable(at: time, reason: "gone"), at: time) }
        XCTAssertTrue(frame.corridors.isEmpty && frame.strokes.isEmpty)
    }

    func testBoundarySwitchCrossfadesAndSmallMovesFollowDirectly() {
        let animator = RoadOverlayAnimator()
        var time = 1.0
        for _ in 0..<20 { time += Self.frame; _ = animator.frame(for: lane(at: time, corridor: false), at: time) }
        // A small move is followed exactly, at full strength.
        time += Self.frame
        var frame = animator.frame(for: lane(shift: 0.004, at: time, corridor: false), at: time)
        XCTAssertEqual(frame.strokes.filter(\.isBoundary).count, 1)
        XCTAssertEqual(frame.strokes.first?.opacity ?? 0, 1, accuracy: 0.001)
        // Jumping to a different painted line: old fades out while the new fades in.
        time += Self.frame
        frame = animator.frame(for: lane(shift: 0.12, at: time, corridor: false), at: time)
        let boundaries = frame.strokes.filter(\.isBoundary)
        XCTAssertEqual(boundaries.count, 2)
        XCTAssertGreaterThan(boundaries.map(\.opacity).max()!, 0.8)
        XCTAssertLessThan(boundaries.map(\.opacity).min()!, 0.2)
    }

    func testWheelTargetKeepsItsSizeThroughShortRouteGapsAndSmoothsNoise() {
        func cue(_ time: Double) -> LiveTurnGuidanceSnapshot {
            LiveTurnGuidanceSnapshot(cue: TurnGuidanceSample(time: time, stage: .following, direction: "right",
                reason: "fixture", currentManeuver: "bend"), sourceFrameUptime: time, expiresAt: time + 0.5, sourceSessionID: 1)
        }
        func route(_ degrees: Double, at time: Double) -> MinimapCoachSnapshot {
            var points = [MinimapPoint(x: 0.5, y: 0.85)], heading = 0.0
            for i in 1...30 {
                if i > 3 { heading = degrees * min(1, Double(i - 3) / 4) }
                let last = points.last!, angle = heading * .pi / 180
                points.append(MinimapPoint(x: last.x + sin(angle) * 0.015, y: last.y - cos(angle) * 0.015))
            }
            return MinimapCoachSnapshot(state: .ready, confidence: .zero, direction: .unknown, severity: .unknown,
                timing: .unknown, action: .hold, steering: .center, orderedPath: Array(points.dropFirst()),
                turnStartPoint: nil, turnStartNormalizedDistance: nil, pathPointCount: points.count, branchPointCount: 0,
                speedUsed: nil, speedAgeMilliseconds: nil, sourceFrameUptime: time, processingLatencyMilliseconds: 0,
                trackingApplied: false, reason: "fixture", playerAnchor: points[0])
        }
        let filter = SteeringWheelTargetFilter()
        var time = 10.0, values: [Double] = []
        for frame in 0..<60 {
            time += Self.frame
            // Readings alternate between 25° and 55° bends.
            values.append(filter.degrees(turn: cue(time), route: route(frame % 2 == 0 ? 25 : 55, at: time), at: time)!)
        }
        let late = Array(values.suffix(20))
        XCTAssertLessThan(late.max()! - late.min()!, 8, "Noisy readings are smoothed")
        let settled = values.last!
        // The route goes stale for 0.3 s: the size is kept, not replaced by the fallback.
        for _ in 0..<18 {
            time += Self.frame
            let value = filter.degrees(turn: cue(time), route: route(40, at: time - 2), at: time)!
            XCTAssertEqual(value, settled, accuracy: 0.001)
        }
    }
}
