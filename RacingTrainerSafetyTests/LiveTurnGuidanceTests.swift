import XCTest

final class LiveTurnGuidanceTests: XCTestCase {
    private func coach(_ time: Double, steps: Int, left: Bool = false) -> MinimapCoachSnapshot {
        let path = (0..<40).map { i in MinimapPoint(x: 0.5 + (left ? -1 : 1) * Double(max(0, i - steps)) * 0.018,
                                                  y: 0.85 - Double(min(i, steps)) * 0.018) }
        let scores = MinimapConfidenceBreakdown(minimap: 0.9, playerAnchor: 0.9, routeMask: 0.9,
            forwardPath: 0.9, geometry: 0.9, temporalStability: 0.9, freshness: 1, motionTracking: 0.9)
        return MinimapCoachSnapshot(state: .ready, confidence: scores, direction: left ? .left : .right,
            severity: .medium, timing: .later, action: .brake, steering: left ? .hardLeft : .hardRight,
            orderedPath: path, turnStartPoint: nil, turnStartNormalizedDistance: nil, pathPointCount: path.count,
            branchPointCount: 0, speedUsed: 100, speedAgeMilliseconds: 0, sourceFrameUptime: time,
            processingLatencyMilliseconds: 20, trackingApplied: false, reason: "fixture")
    }
    private func speed(_ time: Double, session: Int = 1, value: Int = 100) -> MinimapSpeedSample {
        MinimapSpeedSample(value: value, confidence: 0.9, sourceFrameUptime: time,
                          completionUptime: time + 0.01, sourceSessionID: session)
    }
    func testBothDirectionsRotateOnlyAtTurnInAndSuppressLegacyPedalCommands() {
        for left in [true, false] {
            var pipeline = LiveTurnGuidancePipeline()
            var outputs: [LiveTurnGuidanceSnapshot] = []
            for i in 0...12 {
                let time = 10 + Double(i) / 10, input = coach(time, steps: 14 - i, left: left)
                let result = pipeline.process(coach: input, minimapVisible: true, minimapConfidence: 0.9,
                    speed: speed(time), speedUnit: "km/h", session: 1, completedAt: time + 0.02)
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
}
