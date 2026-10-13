import CoreVideo
import XCTest

final class ShadowCaptureTests: XCTestCase {
    let source = ShadowSource(kind: .syntheticTest, identifier: "fixture", name: "Synthetic only")

    final class Clock {
        private let lock = NSLock()
        private var value = 10.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
    }
    final class Sink: ShadowRecordingSink {
        var samples: [ShadowSample] = []
        var events: [String] = []
        var closeReasons: [String] = []
        var shouldFail = false
        var onRecord: (() -> Void)?
        func record(_ sample: ShadowSample, pixels: CVPixelBuffer) throws {
            onRecord?()
            if shouldFail { throw NSError(domain: "fixture", code: 1) }
            samples.append(sample)
        }
        func event(_ type: String, at: Double, generation: Int, reason: String) throws { events.append(reason) }
        func close(reason: String) throws { closeReasons.append(reason) }
    }
    func pixels() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 18, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
    func values(_ ticket: ShadowTicket, _ time: Double) -> [String: CoachModuleObservation] {
        func obs(_ value: CoachModuleValue) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: .fresh, confidence: 0.9, capturedAt: ticket.receivedAt,
                completedAt: time, sourceSessionID: ticket.generation, implementation: "fixture", version: "1", failureReason: nil)
        }
        return ["geometry": obs(CoachModuleValue(direction: "right", severity: "sharp", timing: "soon", turnDistance: 0.2)),
                "minimap": obs(CoachModuleValue(flag: true)), "validity": obs(CoachModuleValue(flag: true))]
    }
    func pipeline(_ clock: Clock, _ sink: Sink, analyze: ShadowCapturePipeline.Analyze? = nil) -> ShadowCapturePipeline {
        ShadowCapturePipeline(configuration: ShadowRunConfiguration(), sink: sink, clock: clock.now,
            startWatchdog: false, resetModules: {}, analyze: analyze ?? { [self] _, ticket, time in values(ticket, time) })
    }

    func testOldSourceTokenCannotEnterNewSession() {
        var gate = ShadowCaptureGate(); let old = gate.begin(source)
        let ticket = gate.reserve(sourceToken: old, pts: 1, receivedAt: 10, now: 10)!
        let new = gate.begin(ShadowSource(kind: .syntheticTest, identifier: "new", name: "new"))
        XCTAssertNil(gate.reserve(sourceToken: old, pts: 2, receivedAt: 10.1, now: 10.1))
        XCTAssertNil(gate.reserve(sourceToken: new, pts: 0, receivedAt: 10.1, now: 10.1))
        XCTAssertFalse(gate.finish(ticket, at: 10.1))
        XCTAssertNotNil(gate.reserve(sourceToken: new, pts: 0.1, receivedAt: 10.2, now: 10.2))
    }
    func testRateLimitAndBoundedWork() {
        var gate = ShadowCaptureGate(); let token = gate.begin(source)
        let ticket = gate.reserve(sourceToken: token, pts: 0, receivedAt: 10, now: 10)!
        XCTAssertNil(gate.reserve(sourceToken: token, pts: 0.02, receivedAt: 10.02, now: 10.02))
        XCTAssertTrue(gate.finish(ticket, at: 10.03))
        XCTAssertNil(gate.reserve(sourceToken: token, pts: 0.04, receivedAt: 10.04, now: 10.04))
        XCTAssertNotNil(gate.reserve(sourceToken: token, pts: 0.1, receivedAt: 10.1, now: 10.1))
        XCTAssertEqual(gate.dropped["worker_busy"], 1); XCTAssertEqual(gate.dropped["rate_limit"], 1)
    }
    func testInvalidAndStaleDeliveryDoesNotSchedule() {
        var gate = ShadowCaptureGate(); let token = gate.begin(source)
        for (pts, arrival, now) in [(Double.nan, 10.0, 10.0), (-1, 10, 10), (1, 11, 10), (1, 10, 10.3)] {
            XCTAssertNil(gate.reserve(sourceToken: token, pts: pts, receivedAt: arrival, now: now))
        }
    }
    func testDuplicateFrameInvalidatesPendingWorkAndCannotRefreshAge() {
        var gate = ShadowCaptureGate(); let token = gate.begin(source)
        let ticket = gate.reserve(sourceToken: token, pts: 1, receivedAt: 10, now: 10)!
        XCTAssertNil(gate.reserve(sourceToken: token, pts: 1, receivedAt: 10.1, now: 10.1))
        XCTAssertFalse(gate.finish(ticket, at: 10.1))
        XCTAssertEqual(gate.lastArrival, 10)
        XCTAssertTrue(gate.watchdog(now: 11))
        XCTAssertNil(gate.reserve(sourceToken: token, pts: 1, receivedAt: 11, now: 11))
        XCTAssertNotNil(gate.reserve(sourceToken: token, pts: 1.1, receivedAt: 11.1, now: 11.1))
    }
    func testBackwardClockJumpAndArrivalGapInvalidateGeneration() {
        for (nextPTS, nextTime) in [(0.5, 10.1), (10.0, 10.1), (2.0, 11.0)] {
            var gate = ShadowCaptureGate(); let token = gate.begin(source)
            let ticket = gate.reserve(sourceToken: token, pts: 1, receivedAt: 10, now: 10)!
            XCTAssertTrue(gate.finish(ticket, at: 10))
            _ = gate.reserve(sourceToken: token, pts: nextPTS, receivedAt: nextTime, now: nextTime)
            XCTAssertGreaterThan(gate.generation, ticket.generation)
        }
    }
    func testWatchdogExpiresWithoutNewFramesAndAllowsCleanRecovery() throws {
        let clock = Clock(), sink = Sink(), pixels = try pixels()
        let runtime = pipeline(clock, sink); let token = runtime.begin(source)
        runtime.receive(pixels, sourcePTS: 0, receivedAt: 10, sourceToken: token); runtime.flush()
        clock.set(11); runtime.poll(); runtime.flush()
        XCTAssertTrue(sink.events.contains("capture_interruption"))
        runtime.receive(pixels, sourcePTS: 1, receivedAt: 11, sourceToken: token); runtime.flush()
        XCTAssertEqual(sink.samples.count, 2)
        XCTAssertNotEqual(sink.samples[0].generation, sink.samples[1].generation)
        XCTAssertTrue(sink.samples[1].row.observations.values.allSatisfy { $0.capturedAt >= 11 })
        runtime.stop(); runtime.flush()
    }
    func testLateCompletionAndSourceSwitchCannotPublishOldMeasurements() throws {
        let clock = Clock(), sink = Sink(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let runtime = pipeline(clock, sink, analyze: { [self] _, ticket, time in
            entered.signal(); _ = release.wait(timeout: .now() + 5); return values(ticket, time)
        })
        let token = runtime.begin(source)
        runtime.receive(try pixels(), sourcePTS: 0, receivedAt: 10, sourceToken: token)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        runtime.invalidate("seek"); _ = runtime.begin(source)
        release.signal(); runtime.flush()
        XCTAssertTrue(sink.samples.isEmpty)
        runtime.stop(); runtime.flush()
    }
    func testStaleCompletionNeverCreatesSample() throws {
        let clock = Clock(), sink = Sink()
        let runtime = pipeline(clock, sink, analyze: { [self] _, ticket, time in
            clock.set(11); return values(ticket, time)
        })
        let token = runtime.begin(source)
        runtime.receive(try pixels(), sourcePTS: 0, receivedAt: 10, sourceToken: token); runtime.flush()
        XCTAssertTrue(sink.samples.isEmpty)
        runtime.stop(); runtime.flush()
    }
    func testSlowStorageDoesNotQueueAnotherFrame() throws {
        let clock = Clock(), sink = Sink(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        sink.onRecord = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        let runtime = pipeline(clock, sink); let token = runtime.begin(source)
        runtime.receive(try pixels(), sourcePTS: 0, receivedAt: 10, sourceToken: token)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        clock.set(10.1); runtime.receive(try pixels(), sourcePTS: 0.1, receivedAt: 10.1, sourceToken: token)
        release.signal(); runtime.flush()
        XCTAssertEqual(sink.samples.count, 1)
        runtime.stop(); runtime.flush()
    }
    func testShadowOnlyNoCalibrationAndRecorderFailureStopsWork() throws {
        let clock = Clock(), sink = Sink()
        let tested = pipeline(clock, sink); let token = tested.begin(source)
        tested.receive(try pixels(), sourcePTS: 0, receivedAt: 10, sourceToken: token); tested.flush()
        XCTAssertFalse(try XCTUnwrap(sink.samples.first).decision.learnedLiveEnabled)
        XCTAssertFalse(sink.samples.contains { [.brake, .lift, .noCue].contains($0.decision.acceptedCue) })
        sink.shouldFail = true; clock.set(10.2)
        tested.receive(try pixels(), sourcePTS: 0.2, receivedAt: 10.2, sourceToken: token); tested.flush()
        XCTAssertNotNil(tested.lastError); XCTAssertEqual(tested.begin(source), -1)
    }
    func testRecorderDoesNotOverwriteAndFinalizesTraceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try ShadowSessionRecorder(root: root, configuration: ShadowRunConfiguration())
        let second = try ShadowSessionRecorder(root: root, configuration: ShadowRunConfiguration())
        XCTAssertNotEqual(first.directory, second.directory)
        try first.event("reset", at: 10, generation: 1, reason: "test")
        try first.close(reason: "test_finished"); try second.close(reason: "test_finished")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: first.directory.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["status"] as? String, "closed")
        XCTAssertEqual((manifest["traceSHA256"] as? String)?.count, 64)
        XCTAssertEqual(manifest["cuesEmitted"] as? Bool, false)
    }

    func testDurationAndStorageBoundsStopRecording() throws {
        let clock = Clock(), sink = Sink()
        var config = ShadowRunConfiguration(); config.maximumDuration = 1; config.maximumBytes = 1_048_576
        let runtime = ShadowCapturePipeline(configuration: config, sink: sink, clock: clock.now,
            startWatchdog: false, resetModules: {}, analyze: { _, _, _ in [:] })
        _ = runtime.begin(source); clock.set(12); runtime.poll(); runtime.flush(); runtime.flush()
        XCTAssertEqual(runtime.begin(source), -1); XCTAssertTrue(sink.closeReasons.contains("duration_limit"))
        let recorder = try ShadowSessionRecorder(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), configuration: config)
        XCTAssertThrowsError(try recorder.event("oversized", at: 1, generation: 1, reason: String(repeating: "x", count: 1_048_576)))
        try recorder.close(reason: "recording_failed")
        let trace = try Data(contentsOf: recorder.directory.appendingPathComponent("observations.jsonl"))
        XCTAssertTrue(trace.isEmpty)
    }
}
