import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// An offline workspace. It never publishes commands to the live coach.
@MainActor
final class CornerReplayLabStore: ObservableObject {
    let playerClip = ReplayClipController()
    let referenceClip = ReplayClipController()
    @Published private(set) var report: ReplayReport?
    @Published var errorMessage: String?

    init() {
        playerClip.onDataChange = { [weak self] in self?.report = nil }
        referenceClip.onDataChange = { [weak self] in self?.report = nil }
    }

    func compare() {
        playerClip.player.pause()
        referenceClip.player.pause()
        report = ReplayEvaluator.evaluate(player: playerClip.session, reference: referenceClip.session)
    }

    func exportReport() {
        guard let report else { return }
        do { try ReplayJSONFile.save(report, suggestedName: "corner-comparison.json") }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class ReplayClipController: ObservableObject {
    let player = AVPlayer()
    @Published var session = ReplaySession(sourceFileName: "", duration: 0, metadata: .empty) {
        didSet { onDataChange?() }
    }
    @Published private(set) var videoURL: URL?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isBusy = false
    @Published private(set) var isSeeking = false
    @Published private(set) var progress = 0.0
    @Published var rangeStart = 0.0
    @Published var rangeEnd = 15.0
    @Published var unit: ReplaySpeedUnit = .kmh
    @Published var landmarkID = "entry"
    @Published var reviewTime: Double?
    @Published var reviewSpeed = ""
    @Published var errorMessage: String?
    @Published private(set) var status = "Open a gameplay clip or import saved labels."
    var onDataChange: (() -> Void)?

    private let sampler = ReplayVideoSampler()
    private var task: Task<Void, Never>?
    private var observer: Any?
    private var scopedURL: URL?
    private var generation = UUID()
    private var seekGeneration = UUID()
    // Sampling settings belong to the observations, not the editable next-run controls.
    private var sourceFingerprint: String?
    private var referenceExport: ReferenceVideoDataset?

    init() {
        player.isMuted = true
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSeeking, time.seconds.isFinite else { return }
                self.currentTime = max(0, time.seconds)
            }
        }
    }

    deinit {
        task?.cancel()
        if let observer { player.removeTimeObserver(observer) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    var reviewedCount: Int { session.samples.filter(\.reviewed).count }
    var canReview: Bool {
        guard let reviewTime else { return false }
        // The UI observer is throttled. Never let its cached position authorize
        // a label after a native player scrub, failed load, or interrupted seek.
        let actualTime = player.currentTime().seconds
        return videoURL != nil && !isBusy && !isSeeking &&
            player.currentItem?.status == .readyToPlay && player.rate == 0 &&
            actualTime.isFinite && abs(actualTime - reviewTime) < 0.01
    }

    func openVideo(attach: Bool = false) {
        guard !isBusy else { return }
        if !attach && !confirmReplace() { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = attach
            ? "Select the original recording for these labels. Filename and duration must match; confirm that it is the exact same edit."
            : "Choose uncropped 16:9 Motorfest footage with the standard HUD. This replaces this pane's labels."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url: url, attach: attach)
    }

    private func loadVideo(url: URL, attach: Bool) {
        cancelWork()
        let token = generation
        isBusy = true
        errorMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        task = Task { [weak self] in
            guard let self else {
                if accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
            var keepAccess = false
            defer { if accessed && !keepAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                try Task.checkCancellation()
                guard generation == token else { return }
                guard duration.isFinite, duration > 0 else { throw ReplayLabError.invalidVideo }
                if attach && (url.lastPathComponent != session.sourceFileName || abs(duration - session.duration) > 0.05) {
                    throw ReplayLabError.wrongVideo
                }
                let fingerprint = try await Task.detached(priority: .utility) {
                    try Self.fingerprint(of: url)
                }.value
                try Task.checkCancellation()
                guard generation == token else { return }
                if attach, let expected = sourceFingerprint, expected != fingerprint {
                    throw ReplayLabError.wrongVideo
                }
                player.pause()
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                scopedURL?.stopAccessingSecurityScopedResource()
                scopedURL = accessed ? url : nil
                keepAccess = accessed
                videoURL = url
                sourceFingerprint = fingerprint
                currentTime = 0
                if !attach {
                    referenceExport = nil
                    session = ReplaySession(sourceFileName: url.lastPathComponent, duration: duration, metadata: .empty)
                    rangeStart = 0
                    rangeEnd = min(duration, 15)
                } else {
                    rangeStart = session.samples.first?.time ?? 0
                    rangeEnd = min(duration, rangeStart + 15)
                }
                reviewTime = nil
                status = "Video ready. Check the HUD unit, then choose a corner interval (up to 60 seconds)."
                isBusy = false
            } catch {
                guard generation == token else { return }
                isBusy = false
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func seek(to time: Double) {
        guard videoURL != nil, time.isFinite else { return }
        player.pause()
        let safeTime = min(max(time, 0), session.duration)
        let token = UUID()
        seekGeneration = token
        isSeeking = true
        player.seek(to: CMTime(seconds: safeTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == token else { return }
                self.isSeeking = false
                if finished {
                    let actualTime = self.player.currentTime().seconds
                    if actualTime.isFinite { self.currentTime = actualTime }
                }
            }
        }
    }

    func sampleVideo() {
        guard let url = videoURL, !isBusy else { return }
        if !session.samples.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace speed samples?"
            alert.informativeText = "This removes this pane's existing speed reviews. Export labels first if you want to keep them. Landmarks stay unchanged."
            alert.addButton(withTitle: "Replace Samples")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        cancelWork()
        let token = generation
        let start = rangeStart, end = rangeEnd, selectedUnit = unit
        isBusy = true
        progress = 0
        errorMessage = nil
        reviewTime = nil
        player.pause()
        status = "Reading source frames. OCR is not reviewed ground truth."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try await sampler.sample(url: url, start: start, end: end, unit: selectedUnit) { [weak self] value in
                    await self?.updateProgress(value, generation: token)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                session.samples = samples
                var descriptor = ReferenceVideoDataset(
                    sourceFileName: session.sourceFileName, duration: session.duration,
                    sourceSpeedUnit: selectedUnit.rawValue, rangeStart: start, rangeEnd: end
                )
                descriptor.sourceSHA256 = sourceFingerprint
                descriptor.sourceGroupID = sourceFingerprint.map { "sha256:\($0)" }
                referenceExport = descriptor
                isBusy = false
                status = "\(samples.count) source-timestamped observations ready to export. Review is optional for data preparation; comparisons require reviewed readings."
                if let first = samples.first { selectSample(first) }
            } catch {
                guard generation == token else { return }
                isBusy = false
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelWork() {
        generation = UUID()
        seekGeneration = UUID()
        task?.cancel()
        task = nil
        isBusy = false
        isSeeking = false
    }

    private func updateProgress(_ value: Double, generation token: UUID) {
        guard generation == token else { return }
        progress = value
    }

    func addLandmark() {
        let key = landmarkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard videoURL != nil, !key.isEmpty, !isBusy, !isSeeking else { return }
        player.pause()
        let actualTime = player.currentTime().seconds
        guard player.currentItem?.status == .readyToPlay, actualTime.isFinite,
              (0...session.duration).contains(actualTime) else { return }
        currentTime = actualTime
        guard !session.landmarks.contains(where: { $0.id == key || abs($0.time - actualTime) < 0.001 }) else {
            errorMessage = "Use a unique landmark name and a distinct timestamp. Remove the old marker before moving it."
            return
        }
        session.landmarks.append(ReplayLandmark(id: key, time: actualTime))
        session.landmarks.sort { $0.time < $1.time }
        landmarkID = key == "entry" ? "apex" : key == "apex" ? "exit" : ""
    }

    func selectSample(_ sample: ReplaySpeedSample) {
        reviewTime = sample.time
        reviewSpeed = sample.speedKPH.map { String(format: "%.1f", $0) } ?? ""
        seek(to: sample.time)
    }

    func reviewSample(missing: Bool = false) {
        guard canReview, let time = reviewTime,
              let index = session.samples.firstIndex(where: { $0.time == time }) else { return }
        let speed = missing ? nil : Double(reviewSpeed)
        if !missing && (speed == nil || !speed!.isFinite || !(0...500).contains(speed!)) {
            errorMessage = "Enter the visible speed converted to km/h (0–500), or mark the frame unreadable."
            return
        }
        session.samples[index] = ReplaySpeedSample(time: time, speedKPH: speed, confidence: missing ? 0 : 1, reviewed: true)
        if index + 1 < session.samples.count { selectSample(session.samples[index + 1]) }
    }

    func importLabels() {
        guard !isBusy, confirmReplace() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64_000_000 else { throw ReplayLabError.largeFile }
            let data = try Data(contentsOf: url)
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let observations: ReferenceVideoDataset?
            let imported: ReplaySession
            if fields?["sourceSpeedUnit"] != nil {
                let dataset = try JSONDecoder().decode(ReferenceVideoDataset.self, from: data)
                observations = dataset
                // Unknown compatibility metadata stays empty. It never becomes proof
                // that two recordings can be compared just because both are unknown.
                imported = ReplaySession(sourceFileName: dataset.sourceFileName, duration: dataset.duration,
                                         metadata: ReplayMetadata(sourceGroupID: dataset.sourceGroupID ?? ""),
                                         samples: dataset.samples)
            } else {
                observations = nil
                imported = try JSONDecoder().decode(ReplaySession.self, from: data)
            }
            cancelWork()
            player.pause()
            player.replaceCurrentItem(with: nil)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            videoURL = nil
            session = imported
            referenceExport = observations
            sourceFingerprint = observations?.sourceSHA256
            if let observations {
                unit = ReplaySpeedUnit(rawValue: observations.sourceSpeedUnit) ?? .kmh
                rangeStart = observations.rangeStart
                rangeEnd = min(observations.rangeEnd, rangeStart + 60)
            }
            currentTime = 0
            reviewTime = nil
            status = "Data imported. Attach the original video only if you want to inspect or correct samples."
        } catch { errorMessage = error.localizedDescription }
    }

    func exportLabels() {
        do {
            try session.validate()
            try ReplayJSONFile.save(session, suggestedName: "\(session.sourceFileName)-labels.json")
        } catch { errorMessage = error.localizedDescription }
    }

    func exportObservations() {
        do {
            guard var dataset = referenceExport, !session.samples.isEmpty else {
                throw ReplayValidationError(message: "Sample this video or import a reference dataset first. Existing comparison labels can still be exported in comparison mode.")
            }
            dataset.samples = session.samples
            try dataset.validate()
            try ReplayJSONFile.save(dataset, suggestedName: "\(session.sourceFileName)-observations.json")
        } catch { errorMessage = error.localizedDescription }
    }

    private nonisolated static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func confirmReplace() -> Bool {
        guard !session.samples.isEmpty || !session.landmarks.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace this clip's labels?"
        alert.informativeText = "Labels remain in memory until exported. Export first if you need to keep this work."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private enum ReplayLabError: LocalizedError {
    case invalidVideo, wrongVideo, largeFile
    var errorDescription: String? {
        switch self {
        case .invalidVideo: "The recording has no finite, positive duration."
        case .wrongVideo: "This video's filename, duration or available file fingerprint differs from the imported data. Attach the original, unedited recording."
        case .largeFile: "The JSON file is larger than the 64 MB observation-import limit."
        }
    }
}

@MainActor
private enum ReplayJSONFile {
    static func save<T: Encodable>(_ value: T, suggestedName: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
}
