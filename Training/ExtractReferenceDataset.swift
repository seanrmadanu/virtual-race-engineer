import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Standalone offline extraction. This tool never trains a model, assigns expert
/// actions, or uses a player recording. Automatic speed observations remain unreviewed.
@main
enum ExtractReferenceDataset {
    private static let usage = """
    Usage: extract-reference-videos.sh --input PATH --output DIRECTORY --unit kmh|mph [--start SECONDS] [--end SECONDS]

    Reads one local .mp4, .mov or .m4v, or those files directly inside a directory.
    The source HUD unit is REQUIRED and must be checked visually before running.
    --start defaults to 0; --end defaults to each recording's duration.
    Use --start/--end for a short pilot before processing a complete recording.

    Output: one reference-only JSON per source, with streamed SHA256 provenance,
    source presentation timestamps and unreviewed speed observations in km/h.
    Sampling is 5 Hz in chunks of at most 60 seconds, capped at 100,000 samples/source.
    Requires uncropped 16:9 Motorfest footage with the standard visible speed HUD.
    Existing output files are never overwritten. Use a new output directory for a new run.
    SHA256 groups identical bytes only; edited copies still require provenance review.
    No player clips, route labels, car labels, action labels or trained model are produced.
    Exit status: 0 success, 1 one or more source failures, 2 invalid arguments/setup.
    """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        do {
            let options = try Options(arguments: arguments)
            let files = try sourceFiles(at: options.input)
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
            log("Reference extraction: \(files.count) source(s), explicit HUD unit \(options.unit.rawValue).")
            log("Automatic observations are unreviewed; this command does not train a model.")
            var succeeded = 0
            var failed = 0
            var totalSamples = 0
            for (index, file) in files.enumerated() {
                do {
                    log("[\(index + 1)/\(files.count)] \(file.lastPathComponent): hashing source...")
                    let dataset = try await extract(file, options: options)
                    let hash = dataset.sourceSHA256!
                    let outputName = file.deletingPathExtension().lastPathComponent + "-" + hash.prefix(12) + ".json"
                    let destination = options.output.appendingPathComponent(outputName)
                    try writeNewDataset(dataset, to: destination)
                    let recognized = dataset.samples.filter { $0.speedKPH != nil }.count
                    log("  Saved \(destination.path): \(dataset.samples.count) samples, \(recognized) OCR candidates, all unreviewed.")
                    totalSamples += dataset.samples.count
                    succeeded += 1
                } catch {
                    failed += 1
                    log("  FAILED \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            log("Summary: \(succeeded) succeeded, \(failed) failed, \(totalSamples) samples saved.")
            if failed > 0 { exit(1) }
        } catch {
            log("Error: \(error.localizedDescription)\n\n\(usage)")
            exit(2)
        }
    }

    private static func extract(_ file: URL, options: Options) async throws -> ReferenceVideoDataset {
        let before = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash = try streamedSHA256(file)
        let destination = options.output.appendingPathComponent(
            file.deletingPathExtension().lastPathComponent + "-" + hash.prefix(12) + ".json"
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtractionError("Output already exists: \(destination.lastPathComponent). Choose a new output directory.")
        }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else {
            throw ExtractionError("The source has no finite positive duration.")
        }
        let end = options.end ?? duration
        guard end > options.start && end <= duration else {
            throw ExtractionError("Requested interval \(options.start)...\(end) is outside the \(duration)-second source.")
        }
        let expectedCount = ceil((end - options.start) * ReplayVideoSampler.sampleRate)
        guard expectedCount <= Double(ReferenceVideoDataset.maximumSampleCount) else {
            throw ExtractionError("The selected range exceeds 100,000 samples. Use a shorter --start/--end interval.")
        }

        let sampler = ReplayVideoSampler()
        var samples: [ReplaySpeedSample] = []
        samples.reserveCapacity(Int(expectedCount))
        var seenTimes: Set<Double> = []
        var chunkStart = options.start
        while chunkStart < end {
            let chunkEnd = min(end, chunkStart + ReplayVideoSampler.maxDuration)
            log(String(format: "  Sampling source %.3f–%.3f s of %.3f s...", chunkStart, chunkEnd, end))
            do {
                let chunk = try await sampler.sample(
                    url: file, start: chunkStart, end: chunkEnd, unit: options.unit
                )
                for sample in chunk where seenTimes.insert(sample.time).inserted {
                    // Explicitly preserve automatic status even if the shared sampler evolves.
                    samples.append(ReplaySpeedSample(time: sample.time, speedKPH: sample.speedKPH,
                                                     confidence: sample.confidence, reviewed: false))
                }
            } catch ReplayVideoSamplerError.noFrames {
                // A short trailing interval can fall between source presentation times.
                log("  No source frame timestamp fell inside this chunk.")
            }
            log(String(format: "  %.1f%% complete; %d source observations.",
                       (chunkEnd - options.start) / (end - options.start) * 100, samples.count))
            chunkStart = chunkEnd
        }
        guard !samples.isEmpty else { throw ExtractionError("No source frames were extracted.") }
        let after = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize &&
              before.contentModificationDate == after.contentModificationDate else {
            throw ExtractionError("The source file changed during extraction; no dataset was saved.")
        }
        let dataset = ReferenceVideoDataset(
            sourceFileName: file.lastPathComponent,
            duration: duration,
            sourceSpeedUnit: options.unit.rawValue,
            rangeStart: options.start,
            rangeEnd: end,
            sourceSHA256: hash,
            sourceGroupID: "sha256:\(hash)",
            samplingHz: ReplayVideoSampler.sampleRate,
            samples: samples.sorted { $0.time < $1.time }
        )
        try dataset.validate()
        return dataset
    }

    private static func streamedSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceFiles(at input: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw ExtractionError("Input does not exist: \(input.path)")
        }
        let supported = Set(["mp4", "mov", "m4v"])
        let candidates = isDirectory.boolValue
            ? try FileManager.default.contentsOfDirectory(at: input,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            : [input]
        let files = try candidates.filter {
            guard supported.contains($0.pathExtension.lowercased()) else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.path < $1.path }
        guard !files.isEmpty else {
            throw ExtractionError("No .mp4, .mov or .m4v files found directly at the input path.")
        }
        return files
    }

    private static func writeNewDataset(_ dataset: ReferenceVideoDataset, to destination: URL) throws {
        try dataset.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dataset)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".reference-extraction-\(UUID().uuidString).json")
        // The completed staging file is published in the same directory. Creating
        // its hard link is atomic and fails if another run already owns the name.
        try data.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.linkItem(at: staging, to: destination)
    }

    private static func log(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    private struct ExtractionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct Options {
        let input: URL
        let output: URL
        let unit: ReplaySpeedUnit
        let start: Double
        let end: Double?

        init(arguments: [String]) throws {
            var flags: [String: String] = [:]
            let allowed: Set<String> = ["--input", "--output", "--unit", "--start", "--end"]
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard allowed.contains(flag) else { throw ExtractionError("Unknown argument: \(flag)") }
                guard flags[flag] == nil else { throw ExtractionError("Repeated argument: \(flag)") }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ExtractionError("Missing value for \(flag)")
                }
                flags[flag] = arguments[index + 1]
                index += 2
            }
            guard let inputPath = flags["--input"], !inputPath.isEmpty,
                  let outputPath = flags["--output"], !outputPath.isEmpty,
                  let unitText = flags["--unit"], let unit = ReplaySpeedUnit(rawValue: unitText) else {
                throw ExtractionError("--input, --output and an explicit --unit kmh|mph are required.")
            }
            let startText = flags["--start"] ?? "0"
            guard let start = Double(startText), start.isFinite, start >= 0 else {
                throw ExtractionError("--start must be a finite nonnegative number of seconds.")
            }
            var end: Double?
            if let endText = flags["--end"] {
                guard let value = Double(endText), value.isFinite, value > start else {
                    throw ExtractionError("--end must be finite and greater than --start.")
                }
                end = value
            }
            self.input = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath).standardizedFileURL
            self.output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath).standardizedFileURL
            self.unit = unit
            self.start = start
            self.end = end
        }
    }
}
