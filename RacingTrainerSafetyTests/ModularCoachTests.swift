import XCTest

final class ModularCoachTests: XCTestCase {
    func observation(_ value: CoachModuleValue? = CoachModuleValue(number: 100),
                     at: Double = 10, completed: Double = 10, session: Int = 1,
                     state: PerceptionState = .fresh, confidence: Float = 0.9,
                     units: String = "km/h") -> CoachModuleObservation {
        CoachModuleObservation(value: value, state: state, confidence: confidence,
            capturedAt: at, completedAt: completed, sourceSessionID: session,
            implementation: "fixture", version: "1", failureReason: nil, units: units)
    }
    func row(time: Double = 10) -> CoachHistoryRow {
        CoachHistoryRow(time: time, observations: [
            "speed": observation(), "minimap": observation(CoachModuleValue(flag: true)),
            "geometry": observation(CoachModuleValue(direction: "right", severity: "sharp", timing: "now", turnDistance: 0.1)),
            "validity": observation(CoachModuleValue(flag: true))], ages: [:])
    }
    var calibration: SlowdownCalibration {
        SlowdownCalibration(carSetupID: "fixture", hudProfile: "fixture", speedUnit: "km/h",
            metersPerMapUnit: 100, brakingDeceleration: 8, liftDeceleration: 2, warningDelaySeconds: 0.2,
            minimumSpeedKPH: 0, maximumSpeedKPH: 300, targetSpeedKPH: ["sharp": 40],
            reviewedBy: "synthetic test only", evidence: ["fixture"])
    }
    func guardDecision(_ cue: SlowdownCue, row: CoachHistoryRow, profile: SlowdownCalibration? = nil,
                       origin: String = "rules") -> SlowdownDecision {
        SlowdownEvidenceGuard.apply(SlowdownProposal(cue: cue, origin: origin, confidence: nil, reason: "fixture"),
            row: row, session: 1, calibration: profile, carSetup: "fixture", hud: "fixture", cameraVerified: true)
    }
    func testGridAndFutureCompletionExclusion() {
        var history = CoachObservationHistory()
        history.append(["speed": observation(at: 10, completed: 10.2)], frameTime: 10, session: 1)
        let rows = history.sample(at: 10.1)
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows.first!.time, 8.2, accuracy: 0.000001)
        XCTAssertTrue(rows.allSatisfy { $0.observations.isEmpty })
        XCTAssertNotNil(history.sample(at: 10.2).last?.observations["speed"])
    }
    func testMissingReadingDoesNotRecoverOlderSuccess() {
        var history = CoachObservationHistory()
        history.append(["speed": observation()], frameTime: 10, session: 1)
        history.append(["speed": observation(nil, at: 10.1, completed: 10.1, state: .missing)], frameTime: 10.1, session: 1)
        XCTAssertNil(history.sample(at: 10.1).last?.observations["speed"]?.value)
        XCTAssertEqual(history.sample(at: 10.1).last?.observations["speed"]?.state, .missing)
    }
    func testAgeIsPreservedAndStallsExpireEvidence() {
        var history = CoachObservationHistory()
        history.append(["speed": observation()], frameTime: 10, session: 1)
        let row = history.sample(at: 10.8).last!
        XCTAssertEqual(row.ages["speed"]!, 0.8, accuracy: 1e-8)
        XCTAssertEqual(row.observations["speed"]?.state, .stale)
    }
    func testBackwardSeekForwardSeekSourceChangeAndExplicitReset() {
        for (time, session, reason) in [(9.0, 1, "seek_or_duplicate_frame"), (20.0, 1, "interruption"), (10.1, 2, "source_change")] {
            var history = CoachObservationHistory()
            history.append(["speed": observation()], frameTime: 10, session: 1)
            history.append([:], frameTime: time, session: session)
            XCTAssertEqual(history.resetReason, reason)
            XCTAssertTrue(history.sample(at: time).allSatisfy { $0.observations.isEmpty })
            history.reset(reason: "pause"); XCTAssertNil(history.sessionID)
        }
    }
    func testMissingCalibrationBlocksBrakeLiftAndNoCueButNotDirectionWarning() {
        for cue in [SlowdownCue.brake, .lift, .noCue] {
            XCTAssertEqual(guardDecision(cue, row: row()).acceptedCue, .cannotJudge)
        }
        XCTAssertEqual(guardDecision(.advanceWarning, row: row()).acceptedCue, .advanceWarning)
    }
    func testEverySpeedFailureBlocksAdvice() {
        let variants = [observation(nil), observation(state: .missing), observation(state: .uncertain),
                        observation(state: .stale), observation(confidence: .nan), observation(confidence: 0.1),
                        observation(at: 8, completed: 8), observation(completed: 11), observation(session: 2),
                        observation(units: "mph"), observation(CoachModuleValue(number: 501))]
        for speed in variants {
            var values = row().observations; values["speed"] = speed
            XCTAssertEqual(guardDecision(.brake, row: CoachHistoryRow(time: 10, observations: values, ages: [:]), profile: calibration).acceptedCue, .cannotJudge)
        }
    }

    func testObservedStraightRequiresFreshRoadAndSpeed() {
        let left = (0..<8).map { RoadPoint(x: 0.4 - Double($0) * 0.015, y: 0.4 + Double($0) * 0.02) }
        let right = left.map { RoadPoint(x: 1 - $0.x, y: $0.y) }
        let road = RoadLineObservation(capturedAt: 10, left: left, right: right, confidence: 0.8, reason: "fixture")
        var values = row().observations
        values["geometry"] = observation(CoachModuleValue(direction: "straight", severity: "straight", target: "straight_segment"))
        values["road"] = observation(CoachModuleValue(road: road))
        func decide(_ values: [String: CoachModuleObservation]) -> SlowdownDecision {
            let row = CoachHistoryRow(time: 10, observations: values, ages: [:])
            let proposal = SlowdownRules.propose(row: row, calibration: nil, carSetup: "", hud: "")
            return SlowdownEvidenceGuard.apply(proposal, row: row, session: 1, calibration: nil, carSetup: "", hud: "")
        }
        XCTAssertEqual(decide(values).acceptedCue, .noCue)
        for bad in [observation(nil), observation(at: 9, completed: 9), observation(units: "mph")] {
            var changed = values; changed["speed"] = bad
            XCTAssertEqual(decide(changed).acceptedCue, .cannotJudge)
        }
        values["road"] = observation(CoachModuleValue(road: road), at: 9, completed: 9)
        XCTAssertEqual(decide(values).acceptedCue, .cannotJudge)
    }
    func testMenuMissingWaypointAndCameraGuard() {
        for key in ["minimap", "geometry", "validity"] {
            var values = row().observations; values[key] = observation(nil, state: .missing)
            XCTAssertEqual(guardDecision(.advanceWarning, row: CoachHistoryRow(time: 10, observations: values, ages: [:])).acceptedCue, .cannotJudge)
        }
        let decision = SlowdownEvidenceGuard.apply(SlowdownProposal(cue: .brake, origin: "rules", confidence: nil, reason: ""),
            row: row(), session: 1, calibration: calibration, carSetup: "fixture", hud: "fixture")
        XCTAssertTrue(decision.suppressionReasons.contains("camera_not_verified"))
    }
    func testLearnedOutputAlwaysRemainsShadowOnly() {
        let decision = guardDecision(.brake, row: row(), profile: calibration, origin: "learned-v1")
        XCTAssertEqual(decision.acceptedCue, .cannotJudge)
        XCTAssertFalse(decision.learnedLiveEnabled)
    }
    func testCalibratedMathAndMetadataRoundTrip() throws {
        let proposal = SlowdownRules.propose(row: row(), calibration: calibration, carSetup: "fixture", hud: "fixture")
        XCTAssertEqual(proposal.cue, .brake)
        XCTAssertEqual(guardDecision(proposal.cue, row: row(), profile: calibration).acceptedCue, .brake)
        let decoded = try JSONDecoder().decode(CoachHistoryRow.self, from: JSONEncoder().encode(row()))
        XCTAssertEqual(decoded.observations["speed"]?.units, "km/h")
        XCTAssertFalse(calibration.supports(carSetup: "other car", hud: "fixture"))
    }

    func testStationaryAndNearRouteDoNotIssueAdvanceWarnings() {
        var values = row().observations
        values["speed"] = observation(CoachModuleValue(number: 0))
        let stopped = SlowdownRules.propose(row: CoachHistoryRow(time: 10, observations: values, ages: [:]),
                                            calibration: nil, carSetup: "", hud: "")
        XCTAssertEqual(stopped.cue, .cannotJudge)
        XCTAssertEqual(stopped.reason, "stationary_route_preview")
        values["speed"] = observation()
        values["geometry"] = observation(CoachModuleValue(direction: "left", severity: "medium", target: "near_route"))
        let near = SlowdownRules.propose(row: CoachHistoryRow(time: 10, observations: values, ages: [:]),
                                        calibration: nil, carSetup: "", hud: "")
        XCTAssertEqual(near.cue, .cannotJudge)
        XCTAssertEqual(near.reason, "near_bend_warning_timing_unresolved")
    }
}
