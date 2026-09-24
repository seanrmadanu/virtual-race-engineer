import XCTest

final class CoachSafetyPolicyTests: XCTestCase {
    private let now = 100.0

    private func route(
        state: PerceptionState = .fresh, direction: RouteTurnDirection = .left,
        severity: TurnSeverity = .sharp, timing: TurnTiming = .now,
        capturedAt: Double = 99.9, completedAt: Double = 100,
        confidence: Float = 0.9, session: Int = 1
    ) -> PerceptionObservation<RouteGuidance> {
        PerceptionObservation(value: RouteGuidance(direction: direction, severity: severity, timing: timing),
                              state: state, confidence: confidence,
                              capturedAt: capturedAt, completedAt: completedAt,
                              sourceSessionID: session, implementation: "fixture", version: "1",
                              failureReason: state == .fresh ? nil : "Rejected fixture")
    }

    private func speed(
        _ value: Int? = 100, state: PerceptionState = .fresh,
        capturedAt: Double = 99.9, completedAt: Double = 100,
        confidence: Float = 0.9, session: Int = 1
    ) -> PerceptionObservation<Int> {
        PerceptionObservation(value: value, state: state, confidence: confidence,
                              capturedAt: capturedAt, completedAt: completedAt,
                              sourceSessionID: session, implementation: "fixture", version: "1",
                              failureReason: state == .fresh ? nil : "Rejected fixture")
    }

    private func decide(_ route: PerceptionObservation<RouteGuidance>,
                        _ speed: PerceptionObservation<Int>?, straightFrames: Int = 4) -> CoachDecision {
        CoachSafetyPolicy.decide(route: route, speed: speed,
                                 stableStraightFrames: straightFrames, sessionID: 1, now: now)
    }

    func testEvidenceTruthTableForEveryStateCombination() {
        for routeState in PerceptionState.allCases {
            for speedState in PerceptionState.allCases {
                let decision = decide(route(state: routeState), speed(state: speedState))
                let expected: DrivingCoachAction = routeState != .fresh ? .unavailable :
                    speedState == .fresh ? .brake : .hold
                XCTAssertEqual(decision.action, expected, "route=\(routeState) speed=\(speedState)")
            }
        }
    }

    func testMissingSpeedNeverAuthorizesAnyTurnOrStraightAction() {
        let directions: [RouteTurnDirection] = [.unknown, .straight, .left, .right, .uTurnLeft, .uTurnRight]
        let severities: [TurnSeverity] = [.unknown, .straight, .gentle, .medium, .sharp, .uTurn]
        let timings: [TurnTiming] = [.unknown, .none, .later, .soon, .now]
        for direction in directions {
            for severity in severities {
                for timing in timings {
                    for missing in [nil, speed(nil)] as [PerceptionObservation<Int>?] {
                        let decision = decide(route(direction: direction, severity: severity, timing: timing), missing)
                        XCTAssertNotEqual(decision.action, .brake)
                        XCTAssertNotEqual(decision.action, .accelerateIfClear)
                        XCTAssertNil(decision.speedUsed)
                    }
                }
            }
        }
    }

    func testOriginalSharpAndUTurnRegressionsReturnRouteOnlyHold() {
        for severity: TurnSeverity in [.sharp, .uTurn] {
            let decision = decide(route(severity: severity), nil)
            XCTAssertEqual(decision.action, .hold)
            XCTAssertEqual(decision.requiredEvidence, ["route"])
            XCTAssertTrue(decision.explanation.contains("Direction only"))
        }
    }

    func testStaleSpeedCannotPassMerelyBecauseItMatchesRouteTimestamp() {
        // Timestamp skew is 0.6s (within the former 0.75s gate), but speed is 0.8s old.
        XCTAssertEqual(decide(route(capturedAt: 99.8), speed(capturedAt: 99.2)).action, .hold)
        XCTAssertEqual(decide(route(capturedAt: 99), speed(capturedAt: 99)).action, .unavailable)
    }

    func testSessionChangeInvalidatesBothKindsOfEvidence() {
        XCTAssertEqual(decide(route(session: 0), speed()).action, .unavailable)
        XCTAssertEqual(decide(route(), speed(session: 0)).action, .hold)
        XCTAssertEqual(decide(route(session: 0), speed(session: 0)).action, .unavailable)
        XCTAssertEqual(decide(route(), speed()).action, .brake)
    }

    func testMalformedTimestampsAreRejected() {
        for timestamp in [Double.nan, .infinity, -.infinity, -1, 100.1] {
            XCTAssertEqual(decide(route(capturedAt: timestamp), speed()).action, .unavailable)
            XCTAssertEqual(decide(route(), speed(capturedAt: timestamp)).action, .hold)
        }
        for completion in [Double.nan, .infinity, 99.8, 100.1] {
            XCTAssertEqual(decide(route(completedAt: completion), speed()).action, .unavailable)
            XCTAssertEqual(decide(route(), speed(completedAt: completion)).action, .hold)
        }
        let invalidNow = CoachSafetyPolicy.decide(route: route(), speed: speed(),
                                                  stableStraightFrames: 4, sessionID: 1, now: .nan)
        XCTAssertEqual(invalidNow.action, .unavailable)
    }

    func testConfidenceAndValueValidation() {
        for confidence: Float in [.nan, .infinity, -0.1, 0.29, 1.1] {
            XCTAssertEqual(decide(route(), speed(confidence: confidence)).action, .hold)
        }
        for confidence: Float in [.nan, .infinity, -0.1, 0.51, 1.1] {
            XCTAssertEqual(decide(route(confidence: confidence), speed()).action, .unavailable)
        }
        for value in [-1, 501, Int.max, Int.min] {
            XCTAssertEqual(decide(route(), speed(value)).action, .hold)
        }
        XCTAssertEqual(decide(route(), speed(0)).action, .hold)
    }

    func testBrakingThresholdBoundariesArePreserved() {
        let cases: [(TurnSeverity, TurnTiming, Int)] = [
            (.uTurn, .soon, 30), (.uTurn, .now, 30), (.sharp, .now, 45),
            (.sharp, .soon, 80), (.medium, .now, 85), (.medium, .soon, 135),
            (.gentle, .now, 170)
        ]
        for (severity, timing, threshold) in cases {
            let evidence = route(severity: severity, timing: timing)
            XCTAssertEqual(decide(evidence, speed(threshold - 1)).action, .hold)
            XCTAssertEqual(decide(evidence, speed(threshold)).action, .brake)
        }
    }

    func testAccelerationRequiresStableConsistentStraightAndValidSpeed() {
        let straight = route(direction: .straight, severity: .straight, timing: .none)
        XCTAssertEqual(decide(straight, speed(), straightFrames: 3).action, .hold)
        XCTAssertEqual(decide(straight, speed(), straightFrames: 4).action, .accelerateIfClear)
        XCTAssertEqual(decide(straight, nil).action, .hold)
        XCTAssertEqual(decide(straight, speed(state: .uncertain)).action, .hold)
        XCTAssertEqual(decide(route(direction: .straight, severity: .sharp, timing: .later), speed()).action, .hold)
    }

    func testDecisionExpiresWithOldestRequiredEvidence() {
        let decision = decide(route(), speed(capturedAt: 99.3))
        XCTAssertEqual(decision.action, .brake)
        XCTAssertEqual(decision.expiresAt, 100.05, accuracy: 0.000001)
        XCTAssertEqual(decision.requiredEvidence, ["route", "speed"])
        XCTAssertEqual(decide(route(), nil).expiresAt, 100.55, accuracy: 0.000001)
    }

    func testExpirationIsEnforcedByPublishedSnapshot() {
        let snapshot = MinimapCoachSnapshot(
            state: .ready, confidence: .zero, direction: .left, severity: .sharp,
            timing: .now, action: .brake, steering: .hardLeft, orderedPath: [],
            turnStartPoint: nil, turnStartNormalizedDistance: nil,
            pathPointCount: 0, branchPointCount: 0, speedUsed: 100, speedAgeMilliseconds: 700,
            sourceFrameUptime: 99.9, processingLatencyMilliseconds: 100,
            trackingApplied: false, reason: "Fixture", guidanceExpiresAt: 100.05
        )
        XCTAssertTrue(snapshot.safeGuidanceAvailable(at: 100))
        XCTAssertFalse(snapshot.safeGuidanceAvailable(at: 100.06))
        XCTAssertEqual(snapshot.displayedState(at: 100.06), .stale)
        XCTAssertFalse(snapshot.safeGuidanceAvailable(at: .nan))
        XCTAssertFalse(snapshot.safeGuidanceAvailable(at: 99))
    }
}
