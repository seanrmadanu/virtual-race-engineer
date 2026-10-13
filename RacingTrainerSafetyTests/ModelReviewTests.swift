import XCTest

final class ModelReviewTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 64)
    private func bundle(_ events: [ModelReviewEvent]? = nil) -> ModelReviewBundle {
        ModelReviewBundle(schemaVersion: "racing-trainer-review-v1", title: "Test Video",
                          source: ModelReviewSource(filename: "test.mp4", sha256: fixtureHash, duration: 30),
                          modelSHA256: fixtureHash, predictionsSHA256: fixtureHash,
                          events: events ?? [event("first", 10), event("second", 15, direction: "left", target: "next_corner", phase: "approach")])
    }
    private func event(_ id: String, _ time: Double, direction: String = "unknown", target: String = "unknown", phase: String = "unknown") -> ModelReviewEvent {
        ModelReviewEvent(id: id, time: time, direction: direction, target: target, phase: phase, reasons: [])
    }
    func testPackageRoundTripPreservesUnknownsAndFinalAnswers() throws {
        let package = bundle()
        let result = try ModelReviewBundle.decode(JSONEncoder().encode(package))
        XCTAssertEqual(result, package)
        XCTAssertFalse(result.events[0].hasAnswer(in: .basicTurns))
        XCTAssertTrue(result.events[1].hasAnswer(in: .cornerTechnique))
        XCTAssertFalse(result.events[1].hasAnswer(in: .advanced))
    }
    func testPlaybackNeverUsesFutureOutput() {
        let package = bundle()
        XCTAssertNil(package.event(atPlaybackTime: 9.9))
        XCTAssertEqual(package.event(atPlaybackTime: 10)?.id, "first")
        XCTAssertEqual(package.event(atPlaybackTime: 14.9)?.id, "first")
        XCTAssertEqual(package.event(atPlaybackTime: 15)?.id, "second")
        XCTAssertNil(package.event(atPlaybackTime: .nan))
        XCTAssertNil(package.event(atPlaybackTime: 31))
    }
    func testPlaybackHighlightTracksForwardAndBackwardAcrossBoundaries() {
        let package = bundle()
        let positions: [(Double, String?)] = [
            (0, nil), (10, "first"), (14.999, "first"), (15, "second"),
            (29.9, "second"), (30, "second"), (14, "first"), (5, nil), (15, "second")
        ]
        for (time, expectedID) in positions {
            XCTAssertEqual(package.event(atPlaybackTime: time)?.id, expectedID, "At \(time) seconds")
        }
    }
    func testPlaybackHighlightDoesNotCarryAnAnsweredRowThroughUnknownMoments() {
        let package = bundle([
            event("answered", 10, direction: "left", target: "current_corner"),
            event("unknown", 15),
            event("answered-again", 20, direction: "right", target: "next_corner")
        ])
        let visibleIDs = package.events.filter { $0.hasAnswer(in: .basicTurns) }.map(\.id)
        XCTAssertEqual(visibleIDs, ["answered", "answered-again"])
        let current = package.event(atPlaybackTime: 18)
        XCTAssertEqual(current?.id, "unknown")
        XCTAssertFalse(visibleIDs.contains(current!.id))
    }
    func testDuplicateReversedAndOutOfBoundsMomentsRejected() {
        for events in [[event("a", 10), event("a", 15)], [event("a", 15), event("b", 10)],
                       [event("a", 10), event("b", 10)], [event("a", -1)], [event("a", 30)], [event("a", .nan)]] {
            XCTAssertThrowsError(try bundle(events).validate())
        }
    }
    func testContradictoryLabelsRejected() {
        XCTAssertThrowsError(try bundle([event("a", 10, direction: "left", target: "straight_segment")]).validate())
        XCTAssertThrowsError(try bundle([event("a", 10, direction: "left", target: "next_corner", phase: "exit")]).validate())
        XCTAssertThrowsError(try bundle([event("a", 10, direction: "unknown", target: "next_corner")]).validate())
        XCTAssertThrowsError(try bundle([event("a", 10, phase: "made_up")]).validate())
    }
    func testDraftsDoNotBecomeReviewsOrBlindReferences() throws {
        var note = ModelReviewNote(eventID: "first", time: 10, category: .basicTurns)
        XCTAssertFalse(note.reviewed)
        XCTAssertFalse(note.canComplete)
        note.reviewer = "Test Reviewer"
        note.verdict = .wrong
        note.text = "Clear left bend was missed."
        XCTAssertTrue(note.canComplete)
        note.reviewed = true
        try note.validate(in: bundle())
        let copy = try JSONDecoder().decode(ModelReviewNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(note, copy)
        XCTAssertEqual(copy.origin, "human_after_model_output")
        XCTAssertTrue(copy.sawModelAnswers)
    }
    func testFeedbackIsBoundToSourceModelAndReplay() throws {
        let package = bundle()
        let note = ModelReviewNote(eventID: "first", time: 10, category: .basicTurns)
        let journal = ModelReviewJournal(sourceSHA256: fixtureHash, modelSHA256: fixtureHash, predictionsSHA256: fixtureHash, notes: [note])
        XCTAssertNoThrow(try journal.validate(in: package))
        for index in 0..<3 {
            let other = String(repeating: "b", count: 64)
            let invalid = ModelReviewJournal(sourceSHA256: index == 0 ? other : fixtureHash,
                                             modelSHA256: index == 1 ? other : fixtureHash,
                                             predictionsSHA256: index == 2 ? other : fixtureHash, notes: [note])
            XCTAssertThrowsError(try invalid.validate(in: package))
        }
        let duplicates = ModelReviewJournal(sourceSHA256: fixtureHash, modelSHA256: fixtureHash, predictionsSHA256: fixtureHash, notes: [note, note])
        XCTAssertThrowsError(try duplicates.validate(in: package))
    }
    func testFeedbackCannotMoveAcrossTimestampsOrSkills() {
        XCTAssertThrowsError(try ModelReviewNote(eventID: "first", time: 11, category: .basicTurns).validate(in: bundle()))
        XCTAssertThrowsError(try ModelReviewNote(eventID: "first", time: 10, category: .advanced).validate(in: bundle()))
        var note = ModelReviewNote(eventID: "first", time: 10, category: .basicTurns)
        note.reviewed = true
        XCTAssertThrowsError(try note.validate(in: bundle()))
    }
    func testTimestampFormatting() {
        XCTAssertEqual(reviewTimestamp(95), "01:35")
        XCTAssertEqual(reviewTimestamp(3605), "01:00:05")
        XCTAssertEqual(reviewTimestamp(.infinity), "--:--")
    }
}
