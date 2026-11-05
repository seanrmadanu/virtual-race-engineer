import XCTest

final class LiveTurnGuidanceTests: XCTestCase {
    func testFailureExplanationDoesNotReviveSteeringOrRenewEvidence() {
        var pipeline = LiveTurnGuidancePipeline()
        let result = pipeline.process(coach: coach(10, steps: 12, anchorConfidence: 0.2),
            minimapVisible: true, minimapConfidence: 0.9, speed: speed(10), speedUnit: "km/h",
            session: 1, completedAt: 10.02)
        XCTAssertEqual(result.waitingMessage(at: 10.1), "Waiting for a clear route ahead")
        XCTAssertEqual(result.steering(at: 10.1), .unavailable)
        XCTAssertNil(result.waitingMessage(at: 9))
        XCTAssertNil(result.waitingMessage(at: 11))
        XCTAssertLessThanOrEqual(result.expiresAt, 10.02)
    }
    private func coach(_ time: Double, steps: Int, left: Bool = false,
                       legacyUncertain: Bool = false, anchorConfidence: Float = 0.9) -> MinimapCoachSnapshot {
        let path = (0..<26).map { i in MinimapPoint(x: 0.5 + (left ? -1 : 1) * Double(max(0, i - steps)) * 0.018,
                                                  y: 0.85 - Double(min(i, steps)) * 0.018) }
        let scores = MinimapConfidenceBreakdown(minimap: 0.9, playerAnchor: anchorConfidence, routeMask: 0.9,
            forwardPath: 0.9, geometry: 0.9, temporalStability: legacyUncertain ? 0.2 : 0.9, freshness: 1, motionTracking: 0.9)
        return MinimapCoachSnapshot(state: legacyUncertain ? .routeUncertain : .ready, confidence: scores, direction: left ? .left : .right,
            severity: .medium, timing: .later, action: .brake, steering: left ? .hardLeft : .hardRight,
            orderedPath: path, turnStartPoint: nil, turnStartNormalizedDistance: nil, pathPointCount: path.count,
            branchPointCount: 0, speedUsed: 100, speedAgeMilliseconds: 0, sourceFrameUptime: time,
            processingLatencyMilliseconds: 20, trackingApplied: false, reason: "fixture", playerAnchor: MinimapPoint(x: 0.5, y: 0.85))
    }
    private func speed(_ time: Double, session: Int = 1, value: Int = 100) -> MinimapSpeedSample {
        MinimapSpeedSample(value: value, confidence: 0.9, sourceFrameUptime: time,
                          completionUptime: time + 0.01, sourceSessionID: session)
    }
    func testBothDirectionsRotateOnlyAtTurnInAndSuppressLegacyPedalCommands() {
        for left in [true, false] {
            var pipeline = LiveTurnGuidancePipeline()
            var outputs: [LiveTurnGuidanceSnapshot] = []
            for i in 0...16 {
                let time = 10 + Double(i) / 10, input = coach(time, steps: max(2, 14 - i), left: left)
                let edges = (0..<16).map { index -> RoadPoint in
                    let y = 0.45 + Double(index) * 0.02
                    return RoadPoint(x: 0.5 + (left ? -1 : 1) * pow(0.75 - y, 2) - 0.15, y: y)
                }
                let road = RoadLineObservation(capturedAt: time, left: edges,
                    right: edges.map { RoadPoint(x: $0.x + 0.3, y: $0.y) }, confidence: 0.9, reason: "fixture")
                let result = pipeline.process(coach: input, minimapVisible: true, minimapConfidence: 0.9,
                    speed: speed(time), speedUnit: "km/h", session: 1, completedAt: time + 0.02, road: road)
                outputs.append(result)
                if [.preview, .headsUp].contains(result.cue.stage) { XCTAssertEqual(result.steering(at: time + 0.02), .center) }
                XCTAssertNotEqual(input.applying(result, at: time + 0.02).action, .brake)
                XCTAssertNotEqual(input.applying(result, at: time + 0.02).action, .accelerateIfClear)
            }
            guard let now = outputs.first(where: { $0.cue.stage == .turnNow }) else { return XCTFail("No turn-in cue") }
            XCTAssertEqual(now.steering(at: now.cue.time), left ? .left : .right)
            XCTAssertEqual(now.steering(at: now.expiresAt + 0.01), .unavailable)
            XCTAssertEqual(now.steering(at: now.cue.time - 0.01), .unavailable)
        }
    }
    func testSpeedAndRouteGatesPreventTurnIn() {
        for failure in ["missing_speed", "stale_speed", "source", "unit", "stopped", "route"] {
            var pipeline = LiveTurnGuidancePipeline()
            for i in 0...12 {
                let time = 10 + Double(i) / 10
                let value = failure == "missing_speed" ? nil : speed(failure == "stale_speed" ? time - 1 : time,
                    session: failure == "source" ? 2 : 1, value: failure == "stopped" ? 0 : 100)
                let result = pipeline.process(coach: coach(failure == "route" ? time - 1 : time, steps: 14 - i),
                    minimapVisible: true, minimapConfidence: 0.9, speed: value,
                    speedUnit: failure == "unit" ? nil : "km/h", session: 1, completedAt: time + 0.02)
                XCTAssertNotEqual(result.cue.stage, .turnNow, failure)
            }
        }
    }
    func testSourceResetClearsPreviousTurnApproach() {
        var pipeline = LiveTurnGuidancePipeline()
        for i in 0..<8 {
            let time = 10 + Double(i) / 10
            _ = pipeline.process(coach: coach(time, steps: 14 - i), minimapVisible: true, minimapConfidence: 0.9,
                speed: speed(time), speedUnit: "mph", session: 1, completedAt: time + 0.02)
        }
        pipeline.reset()
        let result = pipeline.process(coach: coach(10.8, steps: 2), minimapVisible: true, minimapConfidence: 0.9,
            speed: speed(10.8, session: 2), speedUnit: "mph", session: 2, completedAt: 10.82)
        XCTAssertNotEqual(result.cue.stage, .turnNow)
    }

    func testLegacyFarTurnUncertaintyDoesNotDiscardUsableCurrentRoad() {
        for anchorConfidence: Float in [0.9, 0.4] {
            var pipeline = LiveTurnGuidancePipeline()
            var result: LiveTurnGuidanceSnapshot?
            for i in 0..<8 {
                let time = 10 + Double(i) / 10
                result = pipeline.process(coach: coach(time, steps: 12, legacyUncertain: true, anchorConfidence: anchorConfidence),
                    minimapVisible: true, minimapConfidence: 0.9, speed: speed(time), speedUnit: "km/h",
                    session: 1, completedAt: time + 0.02)
            }
            if anchorConfidence > 0.52 {
                XCTAssertEqual(result?.cue.title, "Go straight")
                XCTAssertEqual(result?.cue.upcomingTitle, "Next: Right")
            } else { XCTAssertEqual(result?.cue.stage, .unavailable) }
        }
    }

    func testBriefRetentionExpiresFromOriginalEvidenceAndDoesNotRenewItself() {
        var pipeline = LiveTurnGuidancePipeline()
        for i in 0..<8 {
            let time = 10 + Double(i) / 10
            _ = pipeline.process(coach: coach(time, steps: 12), minimapVisible: true, minimapConfidence: 0.9,
                speed: speed(time), speedUnit: "km/h", session: 1, completedAt: time + 0.02)
        }
        let retained = pipeline.process(coach: coach(10.8, steps: 12, legacyUncertain: true, anchorConfidence: 0.4),
            minimapVisible: true, minimapConfidence: 0.9, speed: speed(10.8), speedUnit: "km/h", session: 1, completedAt: 10.82)
        XCTAssertEqual(retained.cue.title, "Go straight")
        XCTAssertEqual(retained.sourceFrameUptime, 10.7, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(retained.expiresAt, 10.97 + 1e-9)
        XCTAssertEqual(retained.steering(at: 10.98), .unavailable)
        let expired = pipeline.process(coach: coach(11, steps: 12, legacyUncertain: true, anchorConfidence: 0.4),
            minimapVisible: true, minimapConfidence: 0.9, speed: speed(11), speedUnit: "km/h", session: 1, completedAt: 11.02)
        XCTAssertEqual(expired.cue.stage, .unavailable)
    }
}
