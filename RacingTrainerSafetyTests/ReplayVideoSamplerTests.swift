import AVFoundation
import CoreVideo
import XCTest

/// These exercise actual decoding with synthetic blank video, not game footage.
/// They validate timing and missing-data handling, not Motorfest OCR accuracy.
final class ReplayVideoSamplerTests: XCTestCase {
    func testUsesUniqueSourceTimestampsAndKeepsMissingOCRUnreviewed() async throws {
        // Seven source frames per second deliberately do not line up with 5 Hz requests.
        let fixture = try await makeVideo(frameRate: 7, frameCount: 14)
        let progress = SamplerProgressRecorder()
        let start = 0.03, end = 1.03
        let samples = try await ReplayVideoSampler().sample(
            url: fixture.url, start: start, end: end, unit: .kmh
        ) { value in
            await progress.append(value)
        }

        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThanOrEqual(samples.count, 5)
        XCTAssertEqual(Set(samples.map(\.time)).count, samples.count)
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0.time < $1.time })
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample.time, start)
            XCTAssertLessThan(sample.time, end)
            XCTAssertTrue(fixture.frameTimes.contains { abs($0 - sample.time) < 0.000_001 },
                          "\(sample.time) must be a decoded source PTS, not a requested sample time")
            XCTAssertNil(sample.speedKPH)
            XCTAssertEqual(sample.confidence, 0)
            XCTAssertFalse(sample.reviewed)
        }
        let updates = await progress.values
        XCTAssertEqual(updates.first, 0)
        XCTAssertEqual(updates.last, 1)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testExplicitSpeedUnitConversion() {
        XCTAssertEqual(ReplaySpeedUnit.kmh.kilometersPerHour(from: 0), 0)
        XCTAssertEqual(ReplaySpeedUnit.kmh.kilometersPerHour(from: 123), 123)
        XCTAssertEqual(ReplaySpeedUnit.mph.kilometersPerHour(from: 0), 0)
        XCTAssertEqual(ReplaySpeedUnit.mph.kilometersPerHour(from: 60), 96.56064, accuracy: 0.000_001)
        XCTAssertEqual(ReplaySpeedUnit.mph.kilometersPerHour(from: 100), 160.9344, accuracy: 0.000_001)
    }

    func testInvalidRangesFailBeforeReadingVideo() async {
        let absentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-replay-\(UUID().uuidString).mov")
        let invalidRanges: [(Double, Double)] = [
            (-1, 1), (1, 1), (2, 1), (0, 60.01),
            (.nan, 1), (0, .nan), (.infinity, 1), (0, .infinity), (-.infinity, 1)
        ]
        for (start, end) in invalidRanges {
            do {
                _ = try await ReplayVideoSampler().sample(
                    url: absentURL, start: start, end: end, unit: .kmh
                )
                XCTFail("Invalid interval \(start)...\(end) was accepted")
            } catch ReplayVideoSamplerError.invalidRange {
                // Expected: no file read is necessary to reject an invalid interval.
            } catch {
                XCTFail("Expected invalidRange, got \(error)")
            }
        }
    }

    func testRangePastVideoDurationIsRejected() async throws {
        let fixture = try await makeVideo()
        do {
            _ = try await ReplayVideoSampler().sample(
                url: fixture.url, start: 0, end: 2, unit: .kmh
            )
            XCTFail("An interval extending beyond the source should fail")
        } catch ReplayVideoSamplerError.rangeOutsideVideo {
            // Expected.
        }
    }

    func testNonWidescreenFootageIsRejected() async throws {
        let fixture = try await makeVideo(width: 320, height: 240)
        do {
            _ = try await ReplayVideoSampler().sample(
                url: fixture.url, start: 0, end: 0.5, unit: .kmh
            )
            XCTFail("The fixed HUD crop must not be applied to 4:3 footage")
        } catch ReplayVideoSamplerError.unsupportedAspectRatio {
            // Expected.
        }
    }

    func testPreferredTrackTransformIsAppliedBeforeAspectValidation() async throws {
        // Stored portrait pixels become 16:9 only after the track rotation.
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 320, ty: 0)
        let fixture = try await makeVideo(width: 180, height: 320, transform: transform)
        let samples = try await ReplayVideoSampler().sample(
            url: fixture.url, start: 0, end: 0.5, unit: .mph
        )
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.speedKPH == nil && !$0.reviewed })
    }

    func testCancellationAfterFirstFrameDoesNotReturnPartialLabels() async throws {
        let fixture = try await makeVideo()
        let progress = SamplerProgressRecorder()
        // A separate task prevents canceling the XCTest task itself.
        let task = Task {
            try await ReplayVideoSampler().sample(
                url: fixture.url, start: 0, end: 1, unit: .kmh
            ) { value in
                await progress.append(value)
                if value > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must throw instead of publishing partial labels")
        } catch is CancellationError {
            // Expected.
        }
        let updates = await progress.values
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last ?? 0, 0.2, accuracy: 0.000_001)
    }

    private struct VideoFixture {
        let url: URL
        let frameTimes: [Double]
    }

    private enum FixtureError: Error {
        case writerSetup
        case pixelBuffer
        case encoderTimeout
        case appendFailed
        case finishFailed
    }

    private func makeVideo(
        width: Int = 320,
        height: Int = 180,
        frameRate: Int32 = 10,
        frameCount: Int = 10,
        transform: CGAffineTransform = .identity
    ) async throws -> VideoFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayVideoSamplerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("blank.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = false
        // Preserve the deliberately unusual 7 Hz source PTS without rounding to
        // the writer's default movie timescale.
        input.mediaTimeScale = frameRate * 1_000
        input.transform = transform
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw FixtureError.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writerSetup }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }

        var createdBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &createdBuffer) == kCVReturnSuccess,
              let buffer = createdBuffer else { throw FixtureError.pixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var frameTimes: [Double] = []
        for index in 0..<frameCount {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? FixtureError.appendFailed }
                guard Date() < deadline else { throw FixtureError.encoderTimeout }
                try await Task.sleep(for: .milliseconds(1))
            }
            let time = CMTime(value: Int64(index), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? FixtureError.appendFailed
            }
            frameTimes.append(time.seconds)
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: frameRate))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.finishFailed }
        return VideoFixture(url: url, frameTimes: frameTimes)
    }
}

private actor SamplerProgressRecorder {
    private(set) var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}
