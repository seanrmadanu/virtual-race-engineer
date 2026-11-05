import XCTest

final class LinkedTurnTests: XCTestCase {
    private func path(sign: Double = -1, linked: Bool = true, lead: Int = 10) -> [[Double]] {
        var headings = Array(repeating: 0.0, count: lead)
        headings += (1...14).map { Double($0) * 4 * sign }
        headings += Array(repeating: 56 * sign, count: 8)
        if linked { headings += (1...22).map { (56 - Double($0) * 4) * sign } }
        headings += Array(repeating: headings.last!, count: 8)
        var points = [[0.5, 0.90]]
        for angle in headings {
            let p = points.last!, radians = angle * .pi / 180
            points.append([p[0] + sin(radians) * 0.01, p[1] - cos(radians) * 0.01])
        }
        return points
    }
    private func row(_ time: Double, sign: Double = -1, linked: Bool = true, capture: Double? = nil,
                     session: Int = 1, points: [[Double]]? = nil, anchor: [Double] = [0.5, 0.95]) -> CoachHistoryRow {
        func observation(_ value: CoachModuleValue) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: .fresh, confidence: 0.9,
                capturedAt: capture ?? time, completedAt: capture ?? time, sourceSessionID: session,
                implementation: "fixture", version: "1", failureReason: nil)
        }
        return CoachHistoryRow(time: time, observations: [
            "geometry": observation(CoachModuleValue(path: points ?? path(sign: sign, linked: linked), playerAnchor: anchor)),
            "minimap": observation(CoachModuleValue(flag: true)),
            "validity": observation(CoachModuleValue(flag: true))], ages: [:])
    }
    @discardableResult private func feed(_ tracker: inout LinkedTurnTracker, start: Double = 10,
                                         sign: Double = -1, linked: Bool = true) -> LinkedTurnSample {
        var result: LinkedTurnSample!
        for i in 0..<5 { result = tracker.update(row: row(start + Double(i) / 10, sign: sign, linked: linked), session: 1) }
        return result
    }
    private func bundle(_ sample: LinkedTurnSample? = nil) -> ModelReviewBundle {
        let hash = String(repeating: "b", count: 64)
        return ModelReviewBundle(schemaVersion: "racing-trainer-review-v1", title: "Fixture",
            source: ModelReviewSource(filename: "fixture.mp4", sha256: hash, duration: 30),
            modelSHA256: hash, predictionsSHA256: hash,
            events: [ModelReviewEvent(id: "first", time: sample?.time ?? 10, direction: "unknown", target: "unknown",
                phase: "unknown", reasons: [], linkedTurns: sample)], linkedTurnSamples: sample.map { [$0] })
    }

    func testBothLinkedDirectionsAndDistanceOrderWithoutSpeed() throws {
        for sign in [-1.0, 1.0] {
            var tracker = LinkedTurnTracker()
            let sample = feed(&tracker, sign: sign)
            XCTAssertEqual(sample.pattern, sign < 0 ? .leftRight : .rightLeft)
            XCTAssertEqual(sample.distances.count, 2)
            if sample.distances.count == 2 { XCTAssertGreaterThanOrEqual(sample.distances[1] - sample.distances[0], 0.08) }
            XCTAssertFalse(sample.isSequenceStart)
            try sample.validate()
        }
    }
    func testOneLongCornerDoesNotInventASecondBend() {
        for sign in [-1.0, 1.0] {
            var tracker = LinkedTurnTracker()
            XCTAssertEqual(feed(&tracker, sign: sign, linked: false).pattern, sign < 0 ? .left : .right)
        }
    }
    func testAngledStraightDoesNotBecomeTurnSequence() {
        var tracker = LinkedTurnTracker()
        let points = (0..<35).map { [0.5 + Double($0) * 0.006, 0.9 - Double($0) * 0.008] }
        var sample: LinkedTurnSample!
        for i in 0..<5 { sample = tracker.update(row: row(10 + Double(i) / 10, points: points), session: 1) }
        XCTAssertEqual(sample.pattern, .noneVisible)
    }
    func testDistinctCapturesAndElapsedConfirmationRequired() {
        var tracker = LinkedTurnTracker()
        for i in 0..<5 {
            XCTAssertEqual(tracker.update(row: row(10 + Double(i) / 10, capture: 10), session: 1).pattern, .unavailable)
        }
        tracker.reset()
        for i in 0..<20 {
            XCTAssertEqual(tracker.update(row: row(20 + Double(i) / 1000), session: 1).pattern, .unavailable)
        }
    }
    func testDuplicateCannotRenewExpiryOrCreateSequenceStart() {
        var tracker = LinkedTurnTracker()
        let original = feed(&tracker)
        let held = tracker.update(row: row(10.9, capture: 10.4), session: 1)
        XCTAssertEqual(held.pattern, original.pattern)
        XCTAssertEqual(held.validUntil, original.validUntil)
        XCTAssertFalse(held.isSequenceStart)
        XCTAssertEqual(tracker.update(row: row(11.1, capture: 10.4), session: 1).pattern, .unavailable)
    }
    func testContradictionWithdrawsThenRequiresReconfirmation() {
        var tracker = LinkedTurnTracker()
        feed(&tracker)
        XCTAssertEqual(tracker.update(row: row(10.5, sign: 1), session: 1).pattern, .unavailable)
        XCTAssertEqual(tracker.update(row: row(10.6), session: 1).pattern, .unavailable)
        XCTAssertEqual(feed(&tracker, start: 10.7).pattern, .leftRight)
    }
    func testSessionSeekLongGapAndSparseCaptureReset() {
        for mode in 0..<4 {
            var tracker = LinkedTurnTracker(); feed(&tracker)
            let time = [10.5, 8, 12, 10.9][mode], session = mode == 0 ? 2 : 1
            XCTAssertEqual(tracker.update(row: row(time, session: session), session: session).pattern, .unavailable)
        }
    }
    func testRouteDistanceJumpDoesNotReuseConfirmation() {
        var tracker = LinkedTurnTracker(); feed(&tracker)
        XCTAssertEqual(tracker.update(row: row(10.5, points: path(lead: 22)), session: 1).pattern, .unavailable)
    }
    func testMissingUncertainStaleFutureAndMismatchedEvidenceWithdraws() {
        for key in ["geometry", "minimap", "validity"] {
            for variant in 0..<8 {
                var tracker = LinkedTurnTracker(); feed(&tracker)
                var observations = row(10.5).observations
                let good = observations[key]!
                observations[key] = CoachModuleObservation(value: variant == 0 ? nil : good.value,
                    state: variant == 1 ? .uncertain : .fresh, confidence: variant == 2 ? .nan : good.confidence,
                    capturedAt: variant == 3 ? 8 : variant == 6 ? 10.1 : good.capturedAt,
                    completedAt: variant == 4 ? 11 : good.completedAt, sourceSessionID: variant == 5 ? 2 : 1,
                    implementation: "fixture", version: "1", failureReason: nil)
                if variant == 7 { observations.removeValue(forKey: key) }
                XCTAssertEqual(tracker.update(row: CoachHistoryRow(time: 10.5, observations: observations, ages: [:]), session: 1).pattern,
                               .unavailable, "\(key), variant \(variant)")
            }
        }
    }
    func testMalformedDisconnectedRouteAndOutOfOrderCapture() {
        for points in [[[Double.nan, 0.8]], [[0.5, 0.9, 1]], path().map { [$0[0] + 2, $0[1]] }] {
            var tracker = LinkedTurnTracker()
            XCTAssertEqual(tracker.update(row: row(10, points: points), session: 1).pattern, .unavailable)
        }
        var tracker = LinkedTurnTracker(); feed(&tracker)
        XCTAssertEqual(tracker.update(row: row(10.5, anchor: [0.1, 0.95]), session: 1).pattern, .unavailable)
        feed(&tracker, start: 11)
        XCTAssertEqual(tracker.update(row: row(11.5, capture: 11.3), session: 1).pattern, .unavailable)
    }
    func testRoundTripCausalPlaybackAndLegacyBundles() throws {
        var tracker = LinkedTurnTracker(); let sample = feed(&tracker)
        let b = try ModelReviewBundle.decode(JSONEncoder().encode(bundle(sample)))
        XCTAssertEqual(b.linkedTurns(atPlaybackTime: 10.4), sample)
        XCTAssertNil(b.linkedTurns(atPlaybackTime: 10.39)); XCTAssertNil(b.linkedTurns(atPlaybackTime: 10.7))
        XCTAssertNil(b.linkedTurns(atPlaybackTime: .nan))
        XCTAssertNil(try ModelReviewBundle.decode(JSONEncoder().encode(bundle())).linkedTurnSamples)
        XCTAssertTrue(b.events[0].hasAnswer(in: .advanced))
        XCTAssertEqual(b.events[0].direction, "unknown")
    }
    func testCorrectionIsSeparateAndCannotAttachToOtherCategoriesOrLegacy() throws {
        var tracker = LinkedTurnTracker(); let b = bundle(feed(&tracker))
        var note = ModelReviewNote(eventID: "first", time: 10.4, category: .advanced)
        note.linkedTurnCorrection = "right_left"
        try note.validate(in: b)
        let decoded = try JSONDecoder().decode(ModelReviewNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decoded.linkedTurnPattern, "right_left"); XCTAssertEqual(decoded.direction, "")
        XCTAssertFalse(decoded.reviewed); XCTAssertEqual(decoded.origin, "human_after_model_output")
        note.linkedTurnCorrection = "brake"; XCTAssertThrowsError(try note.validate(in: b))
        var other = ModelReviewNote(eventID: "first", time: 10.4, category: .basicTurns)
        other.linkedTurnCorrection = "right_left"; XCTAssertThrowsError(try other.validate(in: b))
        let legacy = ModelReviewNote(eventID: "first", time: 10, category: .advanced)
        XCTAssertThrowsError(try legacy.validate(in: bundle()))
    }
    func testRejectsUnorderedStreamMismatchedEventsAndInvalidSamples() {
        var tracker = LinkedTurnTracker(); let sample = feed(&tracker)
        var duplicate = bundle(sample); duplicate.linkedTurnSamples = [sample, sample]
        XCTAssertThrowsError(try duplicate.validate())
        var mismatch = bundle(sample); mismatch.linkedTurnSamples = []
        XCTAssertThrowsError(try mismatch.validate())
        for distances in [[0.1, 0.11], [0.3, 0.1], [Double.nan, 0.4], [0.1]] {
            let invalid = LinkedTurnSample(time: 10, pattern: .leftRight, distances: distances, reason: "fixture",
                evidenceCapturedAt: 10, validUntil: 10.5, isSequenceStart: true)
            XCTAssertThrowsError(try invalid.validate())
        }
        let future = LinkedTurnSample(time: 10, pattern: .left, distances: [0.1], reason: "fixture",
            evidenceCapturedAt: 11, validUntil: 11.5, isSequenceStart: false)
        XCTAssertThrowsError(try future.validate())
    }
}
