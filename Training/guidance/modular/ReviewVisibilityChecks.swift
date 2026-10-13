import Foundation

/// Integration check of the real store against the packaged AI resources.
@main struct ReviewVisibilityChecks {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let resources = Bundle(url: URL(fileURLWithPath: args[0])) else {
            throw ModelReviewError.invalid("Usage: check-review-visibility.sh APP VIDEO_REVIEW NEW_QA_DIRECTORY")
        }
        let directory = URL(fileURLWithPath: args[2])
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Use a new QA directory")
        let store = ModelReviewStore(storageDirectory: directory, resourceBundle: resources)
        precondition(store.loadTest(url: URL(fileURLWithPath: args[1])), store.errorMessage ?? "Load failed")
        precondition(store.aiReviewCount(.chatgpt) == 30 && store.aiReviewCount(.claude) == 30)
        precondition(store.aiLoadIssues.isEmpty)
        let hasTiming = store.bundle?.turnGuidanceSamples != nil
        if hasTiming {
            precondition(store.category == .basicTurns && store.filter == "all")
            precondition(store.selectedEvent?.turnGuidance?.stage == .turnNow)
            precondition(store.currentNote?.turnTiming != nil)
            store.filter = "turn_cues"
            precondition(!store.visibleEvents.isEmpty && store.visibleEvents.allSatisfy { $0.turnGuidance?.isCueStart == true })
            store.editNote { note in
                note.reviewer = "Integration fixture"
                note.verdict = .correct
                note.turnTiming = TurnTimingReview(cue: "turn_now", verdict: .early, start: "88.5", end: "89.0")
            }
            let key = store.currentNote!.key
            precondition(store.loadTest(url: URL(fileURLWithPath: args[1])))
            precondition(store.notes[key]?.verdict == .correct && store.notes[key]?.turnTiming?.verdict == .early)
            print("PASS: Category 1 opens with timing; cue filter and separate direction/timing draft survive reload")
        } else {
            precondition(store.filter == "ai" && store.visibleEvents.count == 30)
            precondition(store.selectedEvent?.time == 50)
        }
        for event in store.aiReviewedEvents {
            precondition(store.aiResponse(.chatgpt, for: event) != nil)
            precondition(store.aiResponse(.claude, for: event) != nil)
        }
        store.filter = "all"
        let at103 = store.visibleEvents.first { $0.time == 103 }!
        let at105 = store.visibleEvents.first { $0.time == 105 }!
        precondition(store.aiResponse(.chatgpt, for: at103) == nil && store.aiResponse(.claude, for: at103) == nil)
        precondition(store.aiResponse(.chatgpt, for: at105) != nil && store.aiResponse(.claude, for: at105) != nil)
        store.showAIReviews()
        precondition(store.filter == "ai" && store.visibleEvents.count == 30)
        print("PASS: packaged ChatGPT 30 / Claude 30; original exact-time comparisons preserved")
        print("PASS: 01:43 has no AI response; 01:45 has both; Show AI Reviews restores the comparison")

        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
        var unrelated = source
        var identity = source["source"] as! [String: Any]
        identity["sha256"] = String(repeating: "a", count: 64)
        unrelated["source"] = identity
        let differentURL = directory.appendingPathComponent("different-source.review.json")
        try JSONSerialization.data(withJSONObject: unrelated).write(to: differentURL)
        precondition(store.loadTest(url: differentURL))
        precondition(store.aiReviewedEvents.isEmpty && store.filter == "all")
        precondition(store.aiReviewCount(.chatgpt) == 0 && store.aiReviewCount(.claude) == 0)
        print("PASS: a different source loads no borrowed AI responses and opens All Moments")
    }
}
