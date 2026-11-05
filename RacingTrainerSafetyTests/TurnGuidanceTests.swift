import XCTest

final class TurnGuidanceTests: XCTestCase {
    private func row(_ time: Double, steps: Int, session: Int = 1, speed: Double = 100,
                     state: PerceptionState = .fresh, completedAt: Double? = nil) -> CoachHistoryRow {
        let path = (0..<26).map { i in
            [0.5 + Double(max(0, i - steps)) * 0.018, 0.85 - Double(min(i, steps)) * 0.018]
        }
        func observation(_ value: CoachModuleValue, units: String? = nil) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: state, confidence: 0.9, capturedAt: time,
                completedAt: completedAt ?? time, sourceSessionID: session, implementation: "fixture", version: "1",
                failureReason: nil, units: units)
        }
        return CoachHistoryRow(time: time, observations: [
            "geometry": observation(CoachModuleValue(direction: "right", path: path, playerAnchor: [0.5, 0.85])),
            "minimap": observation(CoachModuleValue(flag: true)),
            "validity": observation(CoachModuleValue(flag: true)),
            "speed": observation(CoachModuleValue(number: speed), units: "km/h"),
            "road": observation(CoachModuleValue(direction: steps <= 4 ? "right" : "straight", flag: true,
                road: road(time, curved: steps <= 4)))
        ], ages: [:])
    }

    func testApproachGivesHeadsUpThenSingleTurnNow() {
        var tracker = TurnGuidanceTracker()
        let samples = (0...16).map { tracker.update(row: row(10 + Double($0) / 10, steps: max(2, 14 - $0)), session: 1) }
        XCTAssertTrue(samples.contains { $0.stage == .headsUp })
        XCTAssertTrue(samples.contains { $0.stage == .turnNow }, "\(samples)")
        XCTAssertEqual(samples.filter { $0.stage == .turnNow && $0.isCueStart }.count, 1)
        if let firstNow = samples.firstIndex(where: { $0.stage == .turnNow }),
           let firstWarning = samples.firstIndex(where: { $0.stage == .headsUp }) {
            XCTAssertGreaterThan(firstNow, firstWarning)
        }
        let repeated = tracker.update(row: row(11.7, steps: 2), session: 1)
        XCTAssertFalse(repeated.isCueStart)
    }

    func testNearSnapshotStationaryAndNonApproachingBendsNeverSayNow() {
        for (steps, speed) in [(2, 100.0), (10, 100.0), (10, 0.0)] {
            var tracker = TurnGuidanceTracker()
            for i in 0..<20 {
                let cue = tracker.update(row: row(10 + Double(i) / 10, steps: steps, speed: speed), session: 1)
                XCTAssertNotEqual(cue.stage, .turnNow)
                if speed == 0 { XCTAssertNotEqual(cue.stage, .headsUp) }
            }
        }
    }

    func testGapsSeeksSourceChangesAndUnavailableEvidenceClearApproach() {
        for reset in ["gap", "seek", "source", "stale", "future"] {
            var tracker = TurnGuidanceTracker()
            for i in 0..<8 { _ = tracker.update(row: row(10 + Double(i) / 10, steps: 14 - i), session: 1) }
            let time = reset == "gap" ? 12.0 : reset == "seek" ? 9 : 10.8
            let session = reset == "source" ? 2 : 1
            let result = tracker.update(row: row(time, steps: 2, session: session,
                state: reset == "stale" ? .stale : .fresh, completedAt: reset == "future" ? 11 : nil), session: session)
            XCTAssertNotEqual(result.stage, .turnNow, reset)
        }
    }

    func testRouteJumpDoesNotMasqueradeAsArrival() {
        var tracker = TurnGuidanceTracker()
        for i in 0..<10 { _ = tracker.update(row: row(10 + Double(i) / 10, steps: 18 - i / 3), session: 1) }
        XCTAssertNotEqual(tracker.update(row: row(11, steps: 2), session: 1).stage, .turnNow)
    }

    func testShortEvidenceDropoutDoesNotRepeatHeadsUp() {
        var tracker = TurnGuidanceTracker()
        let first = (0..<7).map { tracker.update(row: row(10 + Double($0) / 10, steps: 12), session: 1) }
        XCTAssertEqual(first.filter(\.isCueStart).count, 1)
        _ = tracker.update(row: row(10.7, steps: 12, state: .missing), session: 1)
        let after = (0..<7).map { tracker.update(row: row(10.8 + Double($0) / 10, steps: 12), session: 1) }
        XCTAssertTrue(after.contains { $0.stage == .headsUp })
        XCTAssertFalse(after.contains { $0.isCueStart })
    }

    func testCuePlaybackIsCausalAndExpiresAcrossMissingSamples() throws {
        let first = TurnGuidanceSample(time: 10.1, stage: .headsUp, direction: "right", reason: "fixture")
        let now = TurnGuidanceSample(time: 11.2, stage: .turnNow, direction: "right", reason: "fixture", isCueStart: true)
        let bundle = fixture(samples: [first, now])
        try bundle.validate()
        XCTAssertNil(bundle.turnGuidance(atPlaybackTime: 10))
        XCTAssertEqual(bundle.turnGuidance(atPlaybackTime: 10.2)?.stage, .headsUp)
        XCTAssertNil(bundle.turnGuidance(atPlaybackTime: 11.1))
        XCTAssertEqual(bundle.turnGuidance(atPlaybackTime: 11.2)?.stage, .turnNow)
        XCTAssertNil(bundle.turnGuidance(atPlaybackTime: 11.5))
    }

    func testDirectionAndTimingFeedbackStaySeparateAndPersist() throws {
        let bundle = fixture(samples: [])
        var note = ModelReviewNote(eventID: "one", time: 10, category: .basicTurns, reviewer: "Reviewer", verdict: .correct)
        note.turnTiming = TurnTimingReview(cue: "turn_now", verdict: .late, start: "9.5", end: "9.8")
        note.reviewed = true
        try note.validate(in: bundle)
        let copy = try JSONDecoder().decode(ModelReviewNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(copy.verdict, .correct)
        XCTAssertEqual(copy.turnTiming?.verdict, .late)
        note.turnTiming?.end = "21"
        XCTAssertThrowsError(try note.validate(in: bundle))
        note.turnTiming = TurnTimingReview(cue: "turn_now", verdict: .early, start: "", end: "")
        XCTAssertFalse(note.canComplete)
        note.turnTiming?.verdict = .unclear
        XCTAssertTrue(note.canComplete)
    }

    private func fixture(samples: [TurnGuidanceSample]) -> ModelReviewBundle {
        ModelReviewBundle(schemaVersion: "racing-trainer-review-v1", title: "Fixture",
            source: ModelReviewSource(filename: "fixture.mp4", sha256: String(repeating: "a", count: 64), duration: 20),
            modelSHA256: String(repeating: "b", count: 64), predictionsSHA256: String(repeating: "c", count: 64),
            events: [ModelReviewEvent(id: "one", time: 10, direction: "right", target: "next_corner", phase: "unknown", reasons: [])],
            turnGuidanceSamples: samples)
    }

    private func road(_ time: Double, sign: Double = 1, curved: Bool = true) -> RoadLineObservation {
        let left = (0..<16).map { i -> RoadPoint in
            let y = 0.45 + Double(i) * 0.02
            let center = 0.5 + (curved ? sign * pow(0.75 - y, 2) : 0)
            return RoadPoint(x: center - 0.10 - (y - 0.45) * 0.25, y: y)
        }
        let right = left.map { RoadPoint(x: $0.x + 0.20 + ($0.y - 0.45) * 0.5, y: $0.y) }
        return RoadLineObservation(capturedAt: time, left: left, right: right, confidence: 0.9, reason: "fixture")
    }

    private func replacingValue(_ observation: CoachModuleObservation?, _ modify: (inout CoachModuleValue) -> Void) -> CoachModuleObservation? {
        guard let observation, var value = observation.value else { return nil }
        modify(&value)
        return CoachModuleObservation(value: value, state: observation.state, confidence: observation.confidence,
            capturedAt: observation.capturedAt, completedAt: observation.completedAt, sourceSessionID: observation.sourceSessionID,
            implementation: observation.implementation, version: observation.version, failureReason: observation.failureReason,
            units: observation.units)
    }

    func testFarBendKeepsStraightAsPrimaryInstruction() {
        var tracker = TurnGuidanceTracker()
        var cue: TurnGuidanceSample?
        for i in 0..<12 { cue = tracker.update(row: row(10 + Double(i) / 10, steps: 12), session: 1) }
        XCTAssertEqual(cue?.primaryDirection, "straight")
        XCTAssertEqual(cue?.title, "Go straight")
        XCTAssertEqual(cue?.upcomingTitle, "Next: Right")
        XCTAssertNotEqual(cue?.stage, .following)
    }

    func testHiddenPlayerGapAndMissingRoadCannotAuthorizeTurnNow() {
        for failure in ["gap", "anchor", "road", "road_stale", "road_opposite", "road_straight"] {
            var tracker = TurnGuidanceTracker()
            for i in 0...18 {
                var input = row(10 + Double(i) / 10, steps: max(2, 14 - i))
                var observations = input.observations
                if failure == "gap" { observations["geometry"] = replacingValue(observations["geometry"]) { $0.playerAnchor = [0.5, 0.93] } }
                if failure == "anchor" { observations["geometry"] = replacingValue(observations["geometry"]) { $0.playerAnchor = nil } }
                if failure == "road" { observations.removeValue(forKey: "road") }
                if failure == "road_stale" { observations["road"] = observations["road"]?.withState(.stale, reason: "fixture") }
                if failure == "road_opposite" { observations["road"] = replacingValue(observations["road"]) { $0.road = road(input.time, sign: -1) } }
                if failure == "road_straight" { observations["road"] = replacingValue(observations["road"]) { $0.road = road(input.time, curved: false) } }
                input = CoachHistoryRow(time: input.time, observations: observations, ages: [:])
                XCTAssertNotEqual(tracker.update(row: input, session: 1).stage, .turnNow, failure)
            }
        }
    }

    func testCurrentBendDoesNotRequireEarlierNowAndStopsOnExit() {
        var tracker = TurnGuidanceTracker()
        let samples = (0..<10).map { tracker.update(row: row(10 + Double($0) / 10, steps: 2), session: 1) }
        XCTAssertTrue(samples.contains { $0.stage == .following })
        XCTAssertFalse(samples.contains { $0.stage == .turnNow })
        var after: TurnGuidanceSample?
        for i in 0..<12 { after = tracker.update(row: row(11 + Double(i) / 10, steps: 35), session: 1) }
        XCTAssertEqual(after?.primaryDirection, "straight")
        XCTAssertNotEqual(after?.stage, .following)
    }

    func testSingleOppositeFrameDoesNotFlipCurrentSteering() {
        var tracker = TurnGuidanceTracker()
        for i in 0..<10 { _ = tracker.update(row: row(10 + Double(i) / 10, steps: 2), session: 1) }
        var observations = row(11, steps: 2).observations
        observations["geometry"] = replacingValue(observations["geometry"]) { $0.path = $0.path?.map { [1 - $0[0], $0[1]] } }
        let cue = tracker.update(row: CoachHistoryRow(time: 11, observations: observations, ages: [:]), session: 1)
        XCTAssertFalse([.turnNow, .following].contains(cue.stage) && cue.direction == "left")
    }

    func testConflictingCurrentRoadWithdrawsDirectionalSteering() {
        var tracker = TurnGuidanceTracker()
        var cue: TurnGuidanceSample?
        for i in 0..<10 {
            let input = row(10 + Double(i) / 10, steps: 2)
            var observations = input.observations
            observations["road"] = replacingValue(observations["road"]) { $0.road = road(input.time, sign: -1) }
            cue = tracker.update(row: CoachHistoryRow(time: input.time, observations: observations, ages: [:]), session: 1)
        }
        XCTAssertEqual(cue?.currentDirection, "unknown")
        XCTAssertFalse([.turnNow, .following].contains(cue!.stage))
    }

    func testNearRoadCurvatureRejectsPerspectiveTiltAndSingleBoundary() {
        XCTAssertEqual(road(1).currentBendDirection, "right")
        XCTAssertEqual(road(1, sign: -1).currentBendDirection, "left")
        XCTAssertEqual(road(1, curved: false).currentBendDirection, "straight")
        let straight = road(1, curved: false)
        let tilted = RoadLineObservation(capturedAt: 1,
            left: straight.left.map { RoadPoint(x: $0.x + $0.y * 0.2, y: $0.y) },
            right: straight.right.map { RoadPoint(x: $0.x + $0.y * 0.2, y: $0.y) }, confidence: 0.9, reason: "fixture")
        XCTAssertEqual(tilted.currentBendDirection, "straight")
        XCTAssertEqual(RoadLineObservation(capturedAt: 1, left: straight.left, right: [], confidence: 0.9,
                                          reason: "fixture").currentBendDirection, "unknown")
    }

    func testCurrentBendHasIndependentUpcomingDirectionAndSimpleTitle() {
        // A nearby right bend followed by a separate left bend.
        let anchor = MinimapPoint(x: 0.5, y: 0.85)
        var path = (0..<14).map { i in [0.5 + Double(i) * 0.009, 0.78 - Double(i) * 0.012] }
        let corner = path.last!
        path += (1...18).map { i in [corner[0] - Double(i) * 0.012, corner[1] - Double(i) * 0.010] }
        var tracker = TurnGuidanceTracker(), cue: TurnGuidanceSample?
        for i in 0..<12 {
            let time = 10 + Double(i) / 10
            var observations = row(time, steps: 2).observations
            observations["geometry"] = replacingValue(observations["geometry"]) {
                $0.path = path; $0.playerAnchor = [anchor.x, anchor.y]
            }
            observations.removeValue(forKey: "road")
            cue = tracker.update(row: CoachHistoryRow(time: time, observations: observations, ages: [:]), session: 1)
        }
        XCTAssertEqual(cue?.title, "Follow the right bend")
        XCTAssertEqual(cue?.primaryDirection, "right")
        XCTAssertEqual(cue?.upcomingTitle, "Next: Left")
        XCTAssertNotEqual(cue?.stage, .turnNow)
    }

    func testMissingSpeedKeepsFreshDirectionButCannotAuthorizeNow() {
        var tracker = TurnGuidanceTracker(), cue: TurnGuidanceSample?
        for i in 0..<20 {
            let input = row(10 + Double(i) / 10, steps: max(2, 14 - i))
            var observations = input.observations
            observations.removeValue(forKey: "speed")
            cue = tracker.update(row: CoachHistoryRow(time: input.time, observations: observations, ages: [:]), session: 1)
            XCTAssertNotEqual(cue?.stage, .turnNow)
        }
        XCTAssertEqual(cue?.primaryDirection, "right")
        XCTAssertEqual(cue?.stage, .following)
    }

    func testNextDoesNotSkipGentleBendForLargerOppositeTurn() {
        var path = [[0.5, 0.78]]
        let angles = Array(repeating: 0.0, count: 5) + (1...12).map { -22.0 * Double($0) / 12 }
            + Array(repeating: -22.0, count: 6) + Array(repeating: 0.0, count: 8)
            + Array(repeating: 45.0, count: 12)
        for angle in angles {
            let p = path.last!, radians = angle * .pi / 180
            path.append([p[0] + sin(radians) * 0.008, p[1] - cos(radians) * 0.008])
        }
        var tracker = TurnGuidanceTracker(), cue: TurnGuidanceSample?
        for i in 0..<12 {
            let time = 10 + Double(i) / 10
            var observations = row(time, steps: 12).observations
            observations["geometry"] = replacingValue(observations["geometry"]) { $0.path = path }
            observations.removeValue(forKey: "road")
            cue = tracker.update(row: CoachHistoryRow(time: time, observations: observations, ages: [:]), session: 1)
        }
        XCTAssertEqual(cue?.title, "Go straight")
        XCTAssertEqual(cue?.upcomingTitle, "Next: Left")
    }
    private func headingRow(_ time: Double, degrees: Double, futureLeft: Bool = false) -> CoachHistoryRow {
        var path = [[0.5, 0.80]]
        for i in 0..<42 {
            let angle = (futureLeft && i >= 15 ? -45 : degrees) * Double.pi / 180
            let previous = path.last!
            path.append([previous[0] + sin(angle) * 0.009, previous[1] - cos(angle) * 0.009])
        }
        var observations = row(time, steps: 12).observations
        observations["geometry"] = replacingValue(observations["geometry"]) { $0.path = path }
        observations.removeValue(forKey: "road")
        return CoachHistoryRow(time: time, observations: observations, ages: [:])
    }

    func testTurnTransitionsToFollowingCurveThenStraightWithoutRearming() {
        for sign in [-1.0, 1.0] {
            var tracker = TurnGuidanceTracker()
            let direction = sign < 0 ? "left" : "right"
            var cue: TurnGuidanceSample?
            for i in 0..<8 { cue = tracker.update(row: headingRow(10 + Double(i) / 10, degrees: sign * 52), session: 1) }
            XCTAssertEqual(cue?.title, "Turn \(direction)")
            for i in 0..<8 { cue = tracker.update(row: headingRow(10.8 + Double(i) / 10, degrees: sign * 22), session: 1) }
            XCTAssertEqual(cue?.title, "Follow the \(direction) bend")
            // The same continuing curve getting steeper is not a second turn-in.
            for i in 0..<6 {
                cue = tracker.update(row: headingRow(11.6 + Double(i) / 10, degrees: sign * 48), session: 1)
                XCTAssertEqual(cue?.title, "Follow the \(direction) bend")
            }
            let exit = (0..<7).map { tracker.update(row: headingRow(12.2 + Double($0) / 10, degrees: 0), session: 1) }
            XCTAssertEqual(exit.last?.title, "Go straight")
            XCTAssertLessThanOrEqual(exit.firstIndex(where: { $0.title == "Go straight" }) ?? 99, 5)
        }
    }

    func testSingleNoisyHeadingDoesNotBlinkCurrentOrNext() {
        var tracker = TurnGuidanceTracker()
        for i in 0..<8 { _ = tracker.update(row: headingRow(10 + Double(i) / 10, degrees: 25, futureLeft: true), session: 1) }
        let before = tracker.update(row: headingRow(10.8, degrees: 25, futureLeft: true), session: 1)
        for (i, degrees) in [0.0, 25, 25, 25, -20, 25, 25, 25].enumerated() {
            let cue = tracker.update(row: headingRow(10.9 + Double(i) / 10, degrees: degrees, futureLeft: true), session: 1)
            XCTAssertEqual(cue.title, before.title)
            XCTAssertEqual(cue.upcomingTitle, "Next: Left")
        }
    }

    func testBriefConfidenceDipKeepsCueButDoesNotRenewEvidenceOrSurviveLoss() {
        var tracker = TurnGuidanceTracker()
        for i in 0..<8 { _ = tracker.update(row: headingRow(10 + Double(i) / 10, degrees: 0), session: 1) }
        let good = tracker.update(row: headingRow(10.8, degrees: 0), session: 1)
        func weak(_ time: Double, state: PerceptionState) -> CoachHistoryRow {
            let input = headingRow(time, degrees: 0)
            return CoachHistoryRow(time: time, observations: input.observations.mapValues { $0.withState(state, reason: "fixture") }, ages: [:])
        }
        let retained = tracker.update(row: weak(10.9, state: .uncertain), session: 1)
        XCTAssertEqual(retained.title, "Go straight")
        XCTAssertEqual(retained.evidenceCapturedAt, good.evidenceCapturedAt)
        XCTAssertLessThanOrEqual(retained.validUntil!, good.time + 0.25)
        XCTAssertFalse(retained.isCueStart)
        XCTAssertEqual(tracker.update(row: weak(11.0, state: .missing), session: 1).stage, .unavailable)
        XCTAssertEqual(tracker.update(row: weak(11.1, state: .stale), session: 1).stage, .unavailable)
    }

    func testUpcomingBendIgnoresSingleOppositeCandidateButAcceptsSustainedChange() {
        var tracker = TurnGuidanceTracker()
        func input(_ time: Double, left: Bool) -> CoachHistoryRow {
            var observations = row(time, steps: 12).observations
            if left {
                observations["geometry"] = replacingValue(observations["geometry"]) {
                    $0.path = $0.path?.map { [1 - $0[0], $0[1]] }
                }
            }
            return CoachHistoryRow(time: time, observations: observations, ages: [:])
        }
        for i in 0..<8 { _ = tracker.update(row: input(10 + Double(i) / 10, left: false), session: 1) }
        XCTAssertEqual(tracker.update(row: input(10.8, left: true), session: 1).upcomingTitle, "Next: Right")
        XCTAssertEqual(tracker.update(row: input(10.9, left: false), session: 1).upcomingTitle, "Next: Right")
        let changed = (0..<6).map { tracker.update(row: input(11 + Double($0) / 10, left: true), session: 1) }
        XCTAssertEqual(changed.last?.upcomingTitle, "Next: Left")
        XCTAssertLessThanOrEqual(changed.firstIndex(where: { $0.upcomingTitle == "Next: Left" }) ?? 99, 4)
    }

    func testRealOppositeBendReplacesCurrentDirectionWithinHalfASecond() {
        var tracker = TurnGuidanceTracker()
        for i in 0..<8 { _ = tracker.update(row: headingRow(10 + Double(i) / 10, degrees: 25), session: 1) }
        let changed = (0..<7).map { tracker.update(row: headingRow(10.8 + Double($0) / 10, degrees: -25), session: 1) }
        XCTAssertEqual(changed.last?.title, "Follow the left bend")
        XCTAssertLessThanOrEqual(changed.firstIndex(where: { $0.primaryDirection == "left" }) ?? 99, 5)
    }

    func testPersistentConfidenceFailureExpiresAndSourceChangeCannotRetain() {
        for failure in ["duration", "source", "future"] {
            var tracker = TurnGuidanceTracker()
            for i in 0..<8 { _ = tracker.update(row: headingRow(10 + Double(i) / 10, degrees: 20), session: 1) }
            var cue: TurnGuidanceSample?
            for i in 0..<6 {
                let time = 10.8 + Double(i) / 10
                var observations = headingRow(time, degrees: 20).observations.mapValues { $0.withState(.uncertain, reason: "fixture") }
                if failure == "future" { observations["geometry"] = row(time, steps: 2, completedAt: time + 1).observations["geometry"] }
                cue = tracker.update(row: CoachHistoryRow(time: time, observations: observations, ages: [:]), session: failure == "source" ? 2 : 1)
                if failure != "duration" { XCTAssertEqual(cue?.stage, .unavailable) }
            }
            XCTAssertEqual(cue?.stage, .unavailable)
        }
    }

}
