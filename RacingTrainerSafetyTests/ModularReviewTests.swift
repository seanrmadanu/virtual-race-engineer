import XCTest

final class ModularReviewTests: XCTestCase {
    private func bundle() -> ModelReviewBundle {
        let modules = ["speed", "minimap", "geometry", "validity"].map {
            ModuleReviewDiagnostic(name: $0, value: "Missing", units: "unknown", state: "missing", confidence: 0,
                confidenceKind: "heuristic_not_probability", age: nil, capturedAt: nil, version: "1", failure: "missing", evidence: [:])
        }
        let diagnostics = ModuleReviewDiagnostics(cue: "cannot_judge", proposedCue: "advance_warning", proposalReason: "fixture",
            origin: "rules-math-v1", suppressionReasons: ["speed_missing"], legacyPolicy: "hold", modules: modules,
            suggestedLabel: "uncertain", suggestedRationale: "Synthetic fixture")
        return ModelReviewBundle(schemaVersion: "racing-trainer-review-v2", title: "Fixture", source: ModelReviewSource(
            filename: "fixture.mp4", sha256: String(repeating: "a", count: 64), duration: 100),
            modelSHA256: String(repeating: "b", count: 64), predictionsSHA256: String(repeating: "c", count: 64),
            events: [ModelReviewEvent(id: "one", time: 10, direction: "unknown", target: "unknown", phase: "unknown", reasons: [], diagnostics: diagnostics)])
    }

    func testV2DiagnosticsRoundTrip() throws {
        let source = bundle()
        XCTAssertEqual(try ModelReviewBundle.decode(JSONEncoder().encode(source)), source)
        XCTAssertFalse(source.events[0].hasAnswer(in: .slowdownTiming))
    }

    func testTimingRequiresExplicitLabelAndValidInterval() {
        var note = ModelReviewNote(eventID: "one", time: 10, category: .slowdownTiming, reviewer: "QA", verdict: .correct)
        XCTAssertFalse(note.canComplete)
        note.slowdown = SlowdownReview(action: "brake", start: "11", end: "9")
        XCTAssertFalse(note.canComplete)
        note.slowdown = SlowdownReview(action: "brake", start: "9", end: "11")
        XCTAssertTrue(note.canComplete)
        note.reviewed = true
        XCTAssertNoThrow(try note.validate(in: bundle()))
        note.slowdown = SlowdownReview(action: "brake", start: "9", end: "100")
        XCTAssertThrowsError(try note.validate(in: bundle()))
    }

    func testUncertainAndCannotJudgeSaveWithoutInventedTiming() {
        for label in ["uncertain", "cannot_judge"] {
            var note = ModelReviewNote(eventID: "one", time: 10, category: .slowdownTiming, reviewer: "QA", verdict: .unclear)
            note.slowdown = SlowdownReview(action: label); note.reviewed = true
            XCTAssertTrue(note.canComplete)
            XCTAssertNoThrow(try note.validate(in: bundle()))
        }
    }

    func testNewVerdictsRoundTripAndV1NoteHasNoTimingFields() throws {
        for verdict in [ReviewVerdict.early, .late, .missed] {
            XCTAssertEqual(try JSONDecoder().decode(ReviewVerdict.self, from: JSONEncoder().encode(verdict)), verdict)
        }
        let note = ModelReviewNote(eventID: "one", time: 10, category: .basicTurns)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        object.removeValue(forKey: "slowdown")
        let decoded = try JSONDecoder().decode(ModelReviewNote.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.slowdown)
        XCTAssertEqual(decoded.origin, "human_after_model_output")
    }
}
