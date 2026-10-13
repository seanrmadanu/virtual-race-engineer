import Foundation
import CryptoKit

/// Read-only smoke check using the same decoder as the native review screen.
/// This validates packaging and provenance, not the proposed gameplay labels.
@main
enum ValidatePilot {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ModelReviewError.invalid(message) }
    }

    static func digest(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 4, "Usage: validate-pilot BUNDLE VIDEO TRACE")
        let bundle = try ModelReviewBundle.decode(Data(contentsOf: URL(fileURLWithPath: args[1])))
        try require(bundle.schemaVersion == "racing-trainer-review-v2", "Expected the modular v2 pilot.")
        try require(bundle.events.count == 30, "Expected 30 pilot events.")
        try require(try digest(args[2]) == bundle.source.sha256, "Recording identity does not match.")
        try require(try digest(args[3]) == bundle.predictionsSHA256, "Trace identity does not match.")
        let roundTrip = try ModelReviewBundle.decode(JSONEncoder().encode(bundle))
        try require(roundTrip == bundle, "The bundle did not survive native serialization.")
        for event in bundle.events {
            try require(bundle.event(atPlaybackTime: event.time)?.id == event.id, "Timestamp lookup failed.")
            let before = bundle.event(atPlaybackTime: max(0, event.time - 0.01))
            try require(before == nil || before!.time <= max(0, event.time - 0.01), "Lookup exposed a future event.")
        }
        print("PASS: native v2 decode, 30 events, recording/trace hashes, round trip, causal timestamp lookup")
        print("Labels remain unreviewed. This check did not write feedback or train a model.")
    }
}
