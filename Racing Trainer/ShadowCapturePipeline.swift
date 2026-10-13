import CoreVideo
import Foundation

nonisolated struct ShadowRunConfiguration: Codable, Sendable {
    var hudProfile = "unconfirmed"
    var speedUnit: String? = nil
    var carSetupID = "unconfirmed"
    var recordHUDImages = false
    var maximumBytes = 512 * 1024 * 1024
    var maximumDuration = 30.0 * 60
}

nonisolated struct ShadowSample: Encodable, Sendable {
    let type = "sample"
    let generation: Int
    let sequence: Int
    let source: ShadowSource
    let sourcePTS: Double
    let receivedAt: Double
    let completedAt: Double
    let frameWidth: Int
    let frameHeight: Int
    // Persist each causal row once. The runtime still maintains the complete 20-row history.
    let row: CoachHistoryRow
    let decision: SlowdownDecision
    let dropped: [String: Int]
    var evidenceImages: [String] = []
    var evidenceImageSHA256: [String: String] = [:]
}

nonisolated protocol ShadowRecordingSink: AnyObject {
    func record(_ sample: ShadowSample, pixels: CVPixelBuffer) throws
    func event(_ type: String, at: Double, generation: Int, reason: String) throws
    func close(reason: String) throws
}

/// No publisher or cue-delivery API: the only output is an isolated recording sink.
/// One retained frame and one utility worker. Dropped work never queues behind OCR.
nonisolated final class ShadowCapturePipeline: @unchecked Sendable {
    // Retain the capture pool buffer until the serial, read-only worker finishes.
    // Neither this pipeline nor its analyzer/sink mutates the pixel storage.
    private struct RetainedFrame: @unchecked Sendable { let pixels: CVPixelBuffer }
    typealias Analyze = (CVPixelBuffer, ShadowTicket, Double) -> [String: CoachModuleObservation]
    private let lock = NSLock()
    private var gate = ShadowCaptureGate()
    private var failure: String?
    private var closed = false
    private let worker = DispatchQueue(label: "com.racingtrainer.modular-shadow", qos: .utility)
    private let configuration: ShadowRunConfiguration
    private let analyze: Analyze
    private let resetModules: () -> Void
    private let sink: ShadowRecordingSink
    private let clock: () -> Double
    private var history = CoachObservationHistory()
    private var workerGeneration = -1
    private var timer: DispatchSourceTimer?
    private let createdAt: Double

    init(configuration: ShadowRunConfiguration, sink: ShadowRecordingSink,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         startWatchdog: Bool = true, resetModules: @escaping () -> Void, analyze: @escaping Analyze) {
        self.configuration = configuration; self.sink = sink; self.clock = clock
        self.resetModules = resetModules; self.analyze = analyze; createdAt = clock()
        if startWatchdog {
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.checkInterruption() }
            self.timer = timer; timer.resume()
        }
    }

    deinit { timer?.cancel(); try? sink.close(reason: "pipeline_deinitialized") }

    var lastError: String? { lock.lock(); defer { lock.unlock() }; return failure }

    @discardableResult
    func begin(_ source: ShadowSource) -> Int {
        lock.lock()
        guard !closed else { lock.unlock(); return -1 }
        let token = gate.begin(source)
        let generation = gate.generation
        enqueueReset("source_changed", generation: generation)
        lock.unlock()
        return token
    }

    func invalidate(_ reason: String) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        gate.reset(reason, stop: true); let token = gate.generation
        enqueueReset(reason, generation: token)
        lock.unlock()
    }

    /// The caller owns a token for the selected source. Delayed callbacks retain the old token.
    func receive(_ pixels: CVPixelBuffer, sourcePTS: Double, receivedAt: Double, sourceToken: Int) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
            gate.drop("unsupported_pixel_format"); lock.unlock(); return
        }
        let ticket = gate.reserve(sourceToken: sourceToken, pts: sourcePTS, receivedAt: receivedAt, now: clock())
        lock.unlock()
        guard let ticket else { return }
        let frame = RetainedFrame(pixels: pixels)
        worker.async { [self, frame] in
            autoreleasepool { process(frame.pixels, ticket: ticket) }
        }
    }

    func poll() { worker.async { [self] in checkInterruption() } }

    // Runs on the serial worker, including when no new frames arrive.
    private func checkInterruption() {
        let now = clock()
        lock.lock()
        let didReset = !closed && gate.watchdog(now: now)
        let generation = gate.generation
        let expired = !closed && now - createdAt >= configuration.maximumDuration
        lock.unlock()
        if expired { stop(reason: "duration_limit"); return }
        if didReset {
            history.reset(reason: "capture_interruption"); resetModules(); workerGeneration = generation
            do { try sink.event("reset", at: now, generation: generation, reason: "capture_interruption") }
            catch { fail(error) }
        }
    }

    /// Completion checks use the internal generation, not the stable source-owner token.
    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && gate.generation == token && gate.source != nil
    }

    func stop(reason: String = "stopped") {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; gate.reset(reason, stop: true)
        lock.unlock()
        worker.async { [self] in
            timer?.cancel(); timer = nil; history.reset(reason: reason); resetModules()
            do { try sink.close(reason: reason) } catch { fail(error) }
        }
    }

    /// Test/command-line barrier only. Never call this from a capture or UI callback.
    func flush() { worker.sync {} }

    private func enqueueReset(_ reason: String, generation: Int) {
        let time = clock()
        worker.async { [self] in
            history.reset(reason: reason); resetModules(); workerGeneration = generation
            do { try sink.event("reset", at: time, generation: generation, reason: reason) }
            catch { fail(error) }
        }
    }

    private func process(_ pixels: CVPixelBuffer, ticket: ShadowTicket) {
        guard isCurrent(ticket.generation) else {
            lock.lock(); _ = gate.finish(ticket, at: clock()); lock.unlock(); return
        }
        if workerGeneration != ticket.generation {
            history.reset(reason: "generation_changed"); resetModules(); workerGeneration = ticket.generation
            do { try sink.event("reset", at: ticket.receivedAt, generation: ticket.generation, reason: "ingress_discontinuity") }
            catch { fail(error); return }
        }
        let startedAt = clock()
        guard startedAt - createdAt < configuration.maximumDuration,
              startedAt - ticket.receivedAt <= 0.25 else {
            lock.lock(); _ = gate.finish(ticket, at: startedAt + 1); lock.unlock(); return
        }
        let values = analyze(pixels, ticket, startedAt)
        let completedAt = clock()
        lock.lock()
        let accepted = !closed && gate.completionIsCurrent(ticket, at: completedAt)
        let dropped = gate.dropped
        lock.unlock()
        // Retain the busy slot through disk I/O too. Slow storage must not queue more frames.
        defer { lock.lock(); _ = gate.finish(ticket, at: completedAt); lock.unlock() }
        guard accepted else { history.reset(reason: "discarded_completion"); resetModules(); return }
        history.append(values, frameTime: ticket.receivedAt, session: ticket.generation)
        let rows = history.sample(at: completedAt)
        guard let row = rows.last else { return }
        // No calibration or learned model is loaded by this recorder.
        let proposal = SlowdownRules.propose(row: row, calibration: nil,
            carSetup: configuration.carSetupID, hud: configuration.hudProfile)
        let decision = SlowdownEvidenceGuard.apply(proposal, row: row, session: ticket.generation,
            calibration: nil, carSetup: configuration.carSetupID, hud: configuration.hudProfile)
        let sample = ShadowSample(generation: ticket.generation, sequence: ticket.sequence, source: ticket.source,
            sourcePTS: ticket.sourcePTS, receivedAt: ticket.receivedAt, completedAt: completedAt,
            frameWidth: CVPixelBufferGetWidth(pixels), frameHeight: CVPixelBufferGetHeight(pixels),
            row: row, decision: decision, dropped: dropped)
        do { try sink.record(sample, pixels: pixels) } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        lock.lock(); failure = error.localizedDescription; closed = true; gate.reset("recording_failed", stop: true); lock.unlock()
        timer?.cancel(); timer = nil; history.reset(reason: "recording_failed"); resetModules()
        try? sink.close(reason: "recording_failed")
        NSLog("Modular shadow recording stopped: %@. Existing coach is unchanged.", error.localizedDescription)
    }
}
