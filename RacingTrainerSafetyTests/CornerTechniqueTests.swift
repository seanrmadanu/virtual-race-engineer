import XCTest

final class CornerTechniqueTests: XCTestCase {
    private func row(_ time: Double, angle: Double, next: String? = nil, capture: Double? = nil,
                     session: Int = 1, speed: Double = 100) -> CoachHistoryRow {
        let capture = capture ?? time
        var path = [MinimapPoint(x: 0.5, y: 0.80)]
        for i in 1..<32 {
            let heading = (i >= 13 && next != nil ? (next == "left" ? -55.0 : 55.0) : angle) * .pi / 180
            let previous = path.last!
            path.append(MinimapPoint(x: previous.x + sin(heading) * 0.012, y: previous.y - cos(heading) * 0.012))
        }
        func observation(_ value: CoachModuleValue, units: String? = nil) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: .fresh, confidence: 0.9, capturedAt: capture,
                completedAt: capture, sourceSessionID: session, implementation: "fixture", version: "1",
                failureReason: nil, units: units)
        }
        return CoachHistoryRow(time: time, observations: [
            "geometry": observation(CoachModuleValue(path: path.map { [$0.x, $0.y] }, playerAnchor: [0.5, 0.85])),
            "minimap": observation(CoachModuleValue(flag: true)),
            "validity": observation(CoachModuleValue(flag: true)),
            "speed": observation(CoachModuleValue(number: speed), units: "km/h")], ages: [:])
    }

    @discardableResult
    private func feed(_ tracker: inout CornerTechniqueTracker, start: Double, count: Int,
                      angle: Double, next: String? = nil) -> CornerTechniqueSample {
        var result: CornerTechniqueSample!
        for i in 0..<count { result = tracker.update(row: row(start + Double(i) / 10, angle: angle, next: next), session: 1) }
        return result
    }

    func testApproachEntryBendExitStraightForBothDirections() throws {
        for side in ["left", "right"] {
            let sign = side == "left" ? -1.0 : 1.0
            var tracker = CornerTechniqueTracker()
            let approach = feed(&tracker, start: 10, count: 8, angle: 0, next: side)
            XCTAssertEqual(approach.phase, .approach); XCTAssertEqual(approach.direction, side)
            let entry = feed(&tracker, start: 10.8, count: 5, angle: sign * 40)
            XCTAssertEqual(entry.phase, .entry); XCTAssertEqual(entry.direction, side)
            XCTAssertEqual(feed(&tracker, start: 11.3, count: 9, angle: sign * 40).phase, .cornering)
            let exit = feed(&tracker, start: 12.2, count: 5, angle: sign * 18)
            XCTAssertEqual(exit.phase, .exit); try exit.validate()
            XCTAssertEqual(feed(&tracker, start: 12.7, count: 14, angle: 0).phase, .straight)
        }
    }

    func testStartingInBendDoesNotInventEntryOrApex() {
        var tracker = CornerTechniqueTracker()
        let sample = feed(&tracker, start: 10, count: 8, angle: 40)
        XCTAssertEqual(sample.phase, .cornering)
        XCTAssertFalse(CornerTechniquePhase.allCases.map(\.rawValue).contains("apex_region"))
    }

    func testCurrentExitKeepsOppositeUpcomingBendSeparate() {
        var tracker = CornerTechniqueTracker()
        feed(&tracker, start: 10, count: 8, angle: -40)
        let exit = feed(&tracker, start: 10.8, count: 6, angle: -18, next: "right")
        XCTAssertEqual(exit.phase, .exit); XCTAssertEqual(exit.direction, "left")
        XCTAssertEqual(exit.upcomingDirection, "right")
    }

    func testBriefDirectionNoiseDoesNotCreateNewEntry() {
        var tracker = CornerTechniqueTracker()
        feed(&tracker, start: 10, count: 8, angle: -35)
        let noise = tracker.update(row: row(10.8, angle: 35), session: 1)
        XCTAssertNotEqual(noise.phase, .entry)
        XCTAssertNotEqual(noise.direction, "right")
        let resumed = tracker.update(row: row(10.9, angle: -35), session: 1)
        XCTAssertEqual(resumed.phase, .cornering); XCTAssertEqual(resumed.direction, "left")
    }

    func testConfirmedOppositeBendStartsSeparateEntry() {
        var tracker = CornerTechniqueTracker()
        feed(&tracker, start: 10, count: 8, angle: -35)
        let entry = feed(&tracker, start: 10.8, count: 5, angle: 35)
        XCTAssertEqual(entry.phase, .entry); XCTAssertEqual(entry.direction, "right")
    }

    func testDuplicateFramesDoNotConfirmOrAdvancePhase() {
        var tracker = CornerTechniqueTracker()
        for i in 0..<6 {
            XCTAssertEqual(tracker.update(row: row(10 + Double(i) / 10, angle: 35, capture: 10), session: 1).phase, .unavailable)
        }
        tracker.reset()
        feed(&tracker, start: 20, count: 5, angle: 0)
        let entry = feed(&tracker, start: 20.5, count: 5, angle: 35)
        XCTAssertEqual(entry.phase, .entry)
        let held = tracker.update(row: row(21.4, angle: 35, capture: 20.9), session: 1)
        XCTAssertEqual(held.phase, .entry); XCTAssertFalse(held.isPhaseStart)
        XCTAssertEqual(held.validUntil, entry.validUntil)
        XCTAssertEqual(tracker.update(row: row(21.6, angle: 35, capture: 20.9), session: 1).phase, .unavailable)
    }

    func testMissingEvidenceResetsProgressAndReacquiresWithoutInventedEntry() {
        var tracker = CornerTechniqueTracker()
        feed(&tracker, start: 10, count: 6, angle: 0)
        XCTAssertEqual(tracker.update(row: CoachHistoryRow(time: 10.6, observations: [:], ages: [:]), session: 1).phase, .unavailable)
        XCTAssertEqual(feed(&tracker, start: 10.7, count: 5, angle: 35).phase, .cornering)
    }

    func testSessionSeekAndLongGapResetPhase() {
        for mode in 0..<3 {
            var tracker = CornerTechniqueTracker()
            feed(&tracker, start: 10, count: 6, angle: 0)
            let time = mode == 1 ? 8.0 : mode == 2 ? 13.0 : 10.6
            let session = mode == 0 ? 2 : 1
            for i in 0..<5 {
                let sample = tracker.update(row: row(time + Double(i) / 10, angle: 35, session: session), session: session)
                XCTAssertNotEqual(sample.phase, .entry)
            }
        }
    }

    func testInvalidEvidenceDoesNotPublishPhase() {
        for key in ["geometry", "speed", "minimap", "validity"] {
            for variant in 0..<7 {
                var tracker = CornerTechniqueTracker()
                feed(&tracker, start: 10, count: 5, angle: 35)
                let input = row(10.5, angle: 35)
                var observations = input.observations
                let good = observations[key]!
                observations[key] = CoachModuleObservation(value: variant == 0 ? nil : good.value,
                    state: variant == 1 ? .uncertain : .fresh,
                    confidence: variant == 2 ? .nan : good.confidence,
                    capturedAt: variant == 3 ? 8 : good.capturedAt,
                    completedAt: variant == 4 ? 11 : good.completedAt,
                    sourceSessionID: variant == 5 ? 2 : 1,
                    implementation: "fixture", version: "1", failureReason: nil,
                    units: variant == 6 && key == "speed" ? "unknown" : good.units)
                if variant == 6 && key != "speed" { continue }
                XCTAssertEqual(tracker.update(row: CoachHistoryRow(time: input.time, observations: observations, ages: [:]), session: 1).phase,
                               .unavailable, "\(key), variant \(variant)")
            }
        }
    }

    func testStoppedAndMalformedPathAreUnavailable() {
        var tracker = CornerTechniqueTracker()
        feed(&tracker, start: 10, count: 6, angle: 35)
        XCTAssertEqual(tracker.update(row: row(10.6, angle: 35, speed: 0), session: 1).phase, .unavailable)
        let input = row(10.7, angle: 35)
        var observations = input.observations
        let good = observations["geometry"]!
        observations["geometry"] = CoachModuleObservation(value: CoachModuleValue(path: [[.nan, 0.8]], playerAnchor: [0.5, 0.85]),
            state: .fresh, confidence: 0.9, capturedAt: good.capturedAt, completedAt: good.completedAt,
            sourceSessionID: 1, implementation: "fixture", version: "1", failureReason: nil)
        XCTAssertEqual(tracker.update(row: CoachHistoryRow(time: input.time, observations: observations, ages: [:]), session: 1).phase, .unavailable)
    }

    private func bundle(_ sample: CornerTechniqueSample? = nil) -> ModelReviewBundle {
        let hash = String(repeating: "a", count: 64)
        let event = ModelReviewEvent(id: "first", time: sample?.time ?? 10, direction: "unknown", target: "unknown",
                                     phase: "unknown", reasons: [], cornerTechnique: sample)
        return ModelReviewBundle(schemaVersion: "racing-trainer-review-v1", title: "Fixture",
            source: ModelReviewSource(filename: "fixture.mp4", sha256: hash, duration: 30),
            modelSHA256: hash, predictionsSHA256: hash, events: [event], cornerTechniqueSamples: sample.map { [$0] })
    }

    func testBundleRoundTripLegacyPlaybackExpiryAndSeparateCorrections() throws {
        var tracker = CornerTechniqueTracker()
        let sample = feed(&tracker, start: 10, count: 6, angle: -35)
        let package = try ModelReviewBundle.decode(JSONEncoder().encode(bundle(sample)))
        XCTAssertEqual(package.events[0].phase, "unknown")
        XCTAssertTrue(package.events[0].hasAnswer(in: .cornerTechnique))
        XCTAssertEqual(package.cornerTechnique(atPlaybackTime: 10.5), sample)
        XCTAssertNil(package.cornerTechnique(atPlaybackTime: 10.49))
        XCTAssertNil(package.cornerTechnique(atPlaybackTime: 10.8))
        XCTAssertNil(package.cornerTechnique(atPlaybackTime: .nan))
        let legacy = try ModelReviewBundle.decode(JSONEncoder().encode(bundle()))
        XCTAssertNil(legacy.cornerTechniqueSamples)
        var note = ModelReviewNote(eventID: "first", time: 10.5, category: .cornerTechnique)
        note.cornerPhaseCorrection = "cornering"
        try note.validate(in: package)
        let decoded = try JSONDecoder().decode(ModelReviewNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decoded.cornerPhase, "cornering"); XCTAssertEqual(decoded.phase, "")
        note.cornerPhaseCorrection = "apex_region"
        XCTAssertThrowsError(try note.validate(in: package))
    }

    func testValidationRejectsUnorderedMismatchedAndFutureSamples() {
        var tracker = CornerTechniqueTracker()
        let sample = feed(&tracker, start: 10, count: 6, angle: -35)
        var duplicate = bundle(sample); duplicate.cornerTechniqueSamples = [sample, sample]
        XCTAssertThrowsError(try duplicate.validate())
        var mismatch = bundle(sample); mismatch.cornerTechniqueSamples = []
        XCTAssertThrowsError(try mismatch.validate())
        let future = CornerTechniqueSample(time: 10, phase: .entry, direction: "left", upcomingDirection: "unknown",
            reason: "fixture", evidenceCapturedAt: 11, validUntil: 11.5, isPhaseStart: true)
        XCTAssertThrowsError(try future.validate())
    }
}
