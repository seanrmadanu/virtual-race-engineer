import Foundation
import CryptoKit

nonisolated enum AIReviewer: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatgpt, claude
    var id: String { rawValue }
    var title: String { self == .chatgpt ? "ChatGPT" : "Claude" }
}

nonisolated struct AIReviewResponse: Codable, Equatable, Sendable {
    let eventID: String
    let time: Double
    let action: String
    let confidence: String
    let current: String
    let upcoming: String
    let observation: String
    let rationale: String
    let questions: [String]
    let intervalStart: Double?
    let intervalEnd: Double?

    var intervalDescription: String {
        guard intervalStart != nil || intervalEnd != nil else { return "Timing not established" }
        func text(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "unknown" }
        return "\(text(intervalStart)) → \(text(intervalEnd))"
    }
    func summary(in category: ReviewSkillCategory) -> String {
        func direction(_ value: String) -> String {
            let label = value.components(separatedBy: " · ").first ?? ""
            guard !label.isEmpty, label != "Not separately labeled" else { return "Unlabeled" }
            return reviewLabel(label)
        }
        switch category {
        case .basicTurns:
            // These are distinct observations. Never silently substitute the
            // upcoming route for the current bend (or the reverse).
            return "Now: \(direction(current))\nNext: \(direction(upcoming))"
        case .cornerTechnique:
            let components = current.components(separatedBy: " · ")
            return components.count > 1 ? reviewLabel(components[1]) : "Phase unlabeled"
        case .slowdownTiming:
            let earlier = intervalEnd.map { $0 < time } ?? false
            return reviewLabel(action) + (earlier ? " · earlier interval" : "")
        case .advanced:
            return "Not reviewed"
        }
    }
}

/// Review identity belongs to source footage. Prior-run annotations can be
/// compared with a new analysis, but are always shown with their provenance.
nonisolated struct AIReviewSet: Codable, Equatable, Sendable {
    let schema: String
    let reviewer: AIReviewer
    let sourceSHA256: String
    let originalReviewSHA256: String
    let reviewedPipelineSHA256: String
    let origin: String
    let humanApproved: Bool
    let trainingEligible: Bool
    let responses: [AIReviewResponse]

    static func decode(_ data: Data) throws -> Self {
        if let normalized = try? JSONDecoder().decode(Self.self, from: data) { return normalized }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["reviewerType"] as? String == "ai", root["humanApproved"] as? Bool == false,
              root["trainingEligible"] as? Bool == false, let events = root["events"] as? [[String: Any]],
              let origin = root["origin"] as? String else { throw invalid() }
        let blindFormat = root["schema"] as? String == "racing-trainer-blind-ai-review-v1"
        guard blindFormat || root["schemaVersion"] as? String == "racing-trainer-ai-review-v1" else { throw invalid() }
        let reviewer: AIReviewer = blindFormat ? .claude : .chatgpt
        let source = (root["source"] as? [String: Any])?["sha256"] as? String ?? root["sourceSHA256"] as? String ?? ""
        var responses: [AIReviewResponse] = []
        for event in events {
            guard let id = event["eventID"] as? String, let time = event["time"] as? Double else { throw invalid() }
            if blindFormat {
                guard let current = event["currentSituation"] as? [String: Any], let upcoming = event["upcomingRoute"] as? [String: Any],
                      let cue = event["proposedCue"] as? [String: Any], let action = cue["action"] as? String else { throw invalid() }
                let interval = cue["acceptableIntervalSeconds"] as? [String: Any] ?? [:]
                responses.append(AIReviewResponse(eventID: id, time: time, action: action, confidence: cue["confidence"] as? String ?? "unknown",
                    current: [current["direction"], current["phase"]].compactMap { $0 as? String }.joined(separator: " · "),
                    upcoming: [upcoming["direction"], upcoming["routeContinuity"]].compactMap { $0 as? String }.joined(separator: " · "),
                    observation: (current["evidence"] as? String ?? "") + "\n\nUpcoming route: " + (upcoming["evidence"] as? String ?? ""),
                    rationale: (event["timingRationale"] as? String ?? "") + "\n\n" + (cue["basis"] as? String ?? ""),
                    questions: (event["needsHumanDecision"] as? [String: Any])?["questions"] as? [String] ?? [],
                    intervalStart: interval["start"] as? Double, intervalEnd: interval["end"] as? Double))
            } else {
                guard let action = event["proposedAction"] as? String else { throw invalid() }
                let interval = event["candidateWindow"] as? [Double]
                let direction = event["direction"] as? String ?? "unknown", target = event["target"] as? String ?? "unknown"
                responses.append(AIReviewResponse(eventID: id, time: time, action: action, confidence: event["confidence"] as? String ?? "unknown",
                    current: target == "current_corner" || target == "straight_segment" ? direction : "Not separately labeled",
                    upcoming: target == "next_corner" ? direction : "", observation: event["observation"] as? String ?? "",
                    rationale: "Candidate interval from sampled frames; not verified earliest/latest timing.",
                    questions: [event["followUp"] as? String].compactMap { $0 },
                    intervalStart: interval?.first, intervalEnd: interval?.count == 2 ? interval?.last : nil))
            }
        }
        return Self(schema: "racing-trainer-ai-columns-v1", reviewer: reviewer, sourceSHA256: source,
                    originalReviewSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    reviewedPipelineSHA256: root["pipelineSHA256"] as? String ?? root["modelSHA256"] as? String ?? "",
                    origin: origin, humanApproved: false, trainingEligible: false, responses: responses)
    }

    private static func invalid() -> NSError {
        NSError(domain: "AIReview", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose a frozen ChatGPT or Claude raw review, or an AI column export."])
    }

    func validate() throws {
        func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        guard schema == "racing-trainer-ai-columns-v1", hash(sourceSHA256), hash(originalReviewSHA256),
              hash(reviewedPipelineSHA256), !humanApproved, !trainingEligible,
              ["ai_raw_video_blind", "ai_after_model_output"].contains(origin),
              !responses.isEmpty, responses.count <= 100_000,
              Set(responses.map(\.eventID)).count == responses.count,
              Set(responses.map(\.time)).count == responses.count else {
            throw NSError(domain: "AIReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "AI review identity or provenance is invalid."])
        }
        for response in responses {
            guard !response.eventID.isEmpty, response.time.isFinite, response.time >= 0,
                  ["advance_warning", "brake", "lift", "no_cue", "uncertain", "cannot_judge"].contains(response.action),
                  [response.intervalStart, response.intervalEnd].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= response.time }),
                  response.intervalStart == nil || response.intervalEnd == nil || response.intervalStart! <= response.intervalEnd! else {
                throw NSError(domain: "AIReview", code: 2, userInfo: [NSLocalizedDescriptionKey: "AI review contains invalid timestamps or intervals."])
            }
        }
    }

    func response(at time: Double, source: String) -> AIReviewResponse? {
        guard source == sourceSHA256 else { return nil }
        // Exact source moment only: never borrow the nearest AI response.
        return responses.first { abs($0.time - time) < 0.000001 }
    }
}
