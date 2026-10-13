import XCTest

final class TurnGuidanceTests: XCTestCase {
    private func row(_ time: Double, steps: Int, session: Int = 1, speed: Double = 100,
                     state: PerceptionState = .fresh, completedAt: Double? = nil) -> CoachHistoryRow {
        let path = (0..<40).map { i in
            [0.5 + Double(max(0, i - steps)) * 0.018, 0.85 - Double(min(i, steps)) * 0.018]
        }
        func observation(_ value: CoachModuleValue, units: String? = nil) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: state, confidence: 0.9, capturedAt: time,
                completedAt: completedAt ?? time, sourceSessionID: session, implementation: "fixture", version: "1",
                failureReason: nil, units: units)
        }
        return CoachHistoryRow(time: time, observations: [
            "geometry": observation(CoachModuleValue(direction: "right", path: path)),
            "minimap": observation(CoachModuleValue(flag: true)),
            "validity": observation(CoachModuleValue(flag: true)),
            "speed": observation(CoachModuleValue(number: speed), units: "km/h")
        ], ages: [:])
    }

    func testApproachGivesHeadsUpThenSingleTurnNow() {
        var tracker = TurnGuidanceTracker()
        let samples = (0...12).map { tracker.update(row: row(10 + Double($0) / 10, steps: 14 - $0), session: 1) }
        XCTAssertTrue(samples.contains { $0.stage == .headsUp })
        XCTAssertTrue(samples.contains { $0.stage == .turnNow }, "\(samples)")
        XCTAssertEqual(samples.filter { $0.stage == .turnNow && $0.isCueStart }.count, 1)
        if let firstNow = samples.firstIndex(where: { $0.stage == .turnNow }),
           let firstWarning = samples.firstIndex(where: { $0.stage == .headsUp }) {
            XCTAssertGreaterThan(firstNow, firstWarning)
        }
        let repeated = tracker.update(row: row(11.3, steps: 2), session: 1)
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
}
