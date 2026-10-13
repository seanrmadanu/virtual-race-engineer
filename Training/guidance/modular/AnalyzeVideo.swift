import Foundation

/// CLI regression entry point for the exact native analyzer used by Model Review.
@main struct AnalyzeVideo {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 5, let start = Double(args[2]), let end = Double(args[3]) else {
            throw ModelReviewError.invalid("Usage: analyze-video.sh VIDEO NEW_OUTPUT START END HUD_PROFILE [cancel]")
        }
        let task = Task {
            try await GuidanceVideoAnalyzer().analyze(url: URL(fileURLWithPath: args[0]),
                output: URL(fileURLWithPath: args[1]),
                configuration: GuidanceAnalysisConfiguration(start: start, end: end, hudProfile: args[4])) { amount, status in
                    print("\(Int(amount * 100))% \(status)")
                }
        }
        if args.last == "cancel" {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            task.cancel()
        }
        do { print("Saved: \(try await task.value.path)") }
        catch is CancellationError {
            guard args.last == "cancel" else { throw CancellationError() }
            print("PASS cancellation: no completed bundle")
        }
    }
}
