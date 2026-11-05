import AppKit
import AVFoundation
import Combine
import CryptoKit
import UniformTypeIdentifiers

@MainActor
final class ModelReviewStore: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var bundle: ModelReviewBundle?
    @Published private(set) var notes: [String: ModelReviewNote] = [:]
    @Published private(set) var selectedID: String?
    @Published var category: ReviewSkillCategory = .basicTurns
    @Published var filter = "all"
    @Published private(set) var currentTime = 0.0
    @Published private(set) var videoURL: URL?
    @Published private(set) var videoReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Open a model test to begin."
    @Published var errorMessage: String?
    @Published private(set) var aiReviews: [AIReviewer: AIReviewSet] = [:]
    @Published private(set) var aiLoadIssues: [String] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress = 0.0
    @Published var showsAnalysisOptions = false
    @Published var analysisStart = "0"
    @Published var analysisEnd = ""
    @Published var analysisProfile = "motorfest-standard-v1"
    @Published var analysisUnit = "km/h"
    @Published var analysisCamera = RoadCameraMode.chase
    @Published private(set) var pendingAnalysisURL: URL?
    private var analysisTask: Task<Void, Never>?
    private var analysisScope: URL?
    private var analysisGeneration = UUID()

    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var scopedVideo: URL?
    private var loadGeneration = UUID()
    private var seekGeneration = UUID()
    private var started = false
    private var lastReviewer = ""

    let storageDirectory: URL
    private let resourceBundle: Bundle

    init(storageDirectory: URL? = nil, resourceBundle: Bundle = .main) {
        self.resourceBundle = resourceBundle
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if let path = Self.argument("--review-storage") {
            self.storageDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.storageDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RacingTrainer/ModelReview", isDirectory: true)
        }
        player.isMuted = true
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite && !self.isSeeking { self.currentTime = max(0, time.seconds) }
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    deinit {
        analysisTask?.cancel()
        analysisScope?.stopAccessingSecurityScopedResource()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        scopedVideo?.stopAccessingSecurityScopedResource()
    }

    var selectedEvent: ModelReviewEvent? { bundle?.events.first { $0.id == selectedID } }
    var playbackEvent: ModelReviewEvent? { bundle?.event(atPlaybackTime: currentTime) }
    var visibleEvents: [ModelReviewEvent] {
        guard category != .advanced else { return [] }
        return (bundle?.events ?? []).filter { event in
            switch filter {
            case "turn_cues": return event.turnGuidance?.isCueStart == true
            case "corner_phases": return event.cornerTechnique?.isPhaseStart == true
            case "answered": return event.hasAnswer(in: category)
            case "unknown": return !event.hasAnswer(in: category)
            case "unreviewed": return notes["\(event.id)|\(category.rawValue)"]?.reviewed != true
            case "ai": return AIReviewer.allCases.contains { aiResponse($0, for: event) != nil }
            default: return true
            }
        }
    }
    var reviewedCount: Int { notes.values.filter { $0.category == category && $0.reviewed }.count }
    var answeredCount: Int { bundle?.events.filter { $0.hasAnswer(in: category) }.count ?? 0 }
    var aiReviewedEvents: [ModelReviewEvent] {
        (bundle?.events ?? []).filter { event in
            AIReviewer.allCases.contains { aiResponse($0, for: event) != nil }
        }
    }
    func aiReviewCount(_ reviewer: AIReviewer) -> Int {
        (bundle?.events ?? []).filter { aiResponse(reviewer, for: $0) != nil }.count
    }
    func showAIReviews() {
        guard !isBusy, !aiReviewedEvents.isEmpty else { return }
        filter = "ai"
        let next = aiReviewedEvents.first { $0.time >= currentTime } ?? aiReviewedEvents[0]
        select(next)
    }
    var currentNote: ModelReviewNote? {
        guard let event = selectedEvent, category != .advanced else { return nil }
        if let saved = notes["\(event.id)|\(category.rawValue)"] { return saved }
        var note = ModelReviewNote(eventID: event.id, time: event.time, category: category, reviewer: lastReviewer)
        if category == .basicTurns, bundle?.turnGuidanceSamples != nil {
            note.turnTiming = TurnTimingReview(cue: event.turnGuidance?.stage == .headsUp ? "heads_up" : "turn_now")
        }
        return note
    }

    func aiResponse(_ reviewer: AIReviewer, for event: ModelReviewEvent) -> AIReviewResponse? {
        guard let source = bundle?.source.sha256 else { return nil }
        return aiReviews[reviewer]?.response(at: event.time, source: source)
    }

    var roadAtPlayhead: RoadLineObservation { bundle?.road(atPlaybackTime: currentTime) ?? .empty }
    var turnAtPlayhead: TurnGuidanceSample? { bundle?.turnGuidance(atPlaybackTime: currentTime) }
    var cornerAtPlayhead: CornerTechniqueSample? { bundle?.cornerTechnique(atPlaybackTime: currentTime) }

    func start() {
        guard !started else { return }
        started = true
        if let input = Self.argument("--analyze-video") {
            analysisStart = Self.argument("--analysis-start") ?? "0"
            analysisEnd = Self.argument("--analysis-end") ?? ""
            analysisProfile = Self.argument("--analysis-profile") ?? "motorfest-standard-v1"
            analysisCamera = RoadCameraMode(rawValue: Self.argument("--analysis-camera") ?? "chase") ?? .chase
            pendingAnalysisURL = URL(fileURLWithPath: input)
            beginAnalysis()
            return
        }
        let test = Self.argument("--review-bundle").map { URL(fileURLWithPath: $0) }
            ?? (FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent("last-test.review.json").path)
                ? storageDirectory.appendingPathComponent("last-test.review.json")
                : resourceBundle.url(forResource: "ReviewPilot", withExtension: "json")
                    ?? storageDirectory.appendingPathComponent("last-test.review.json"))
        guard FileManager.default.fileExists(atPath: test.path), loadTest(url: test) else { return }
        if Self.argument("--review-category") == ReviewSkillCategory.cornerTechnique.rawValue,
           bundle?.cornerTechniqueSamples != nil {
            category = .cornerTechnique
            selectedID = bundle?.events.first(where: { $0.cornerTechnique?.isPhaseStart == true })?.id
                ?? bundle?.events.first?.id
        }
        if let video = Self.argument("--review-video") {
            attachVideo(url: URL(fileURLWithPath: video))
        } else {
            restoreVideo()
        }
    }

    func openTest() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the .review.json file prepared with the model's replay outputs."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = loadTest(url: url)
    }

    @discardableResult
    func loadTest(url: URL) -> Bool {
        guard saveJournal() else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try ModelReviewBundle.decode(data)
            let journalURL = storageDirectory.appendingPathComponent(loaded.storageKey + ".feedback.json")
            var restored: [String: ModelReviewNote] = [:]
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let journal = try Self.decoder.decode(ModelReviewJournal.self, from: Data(contentsOf: journalURL))
                try journal.validate(in: loaded)
                restored = Dictionary(uniqueKeysWithValues: journal.notes.map { ($0.key, $0) })
            }
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: storageDirectory.appendingPathComponent("last-test.review.json"), options: .atomic)
            loadGeneration = UUID()
            resetVideo()
            bundle = loaded
            loadAIReviews(for: loaded)
            category = .basicTurns
            notes = restored
            selectedID = loaded.turnGuidanceSamples == nil ? (aiReviewedEvents.first?.id ?? loaded.events.first?.id)
                : (loaded.events.first(where: { $0.turnGuidance?.stage == .turnNow && $0.turnGuidance?.isCueStart == true })?.id ?? loaded.events.first?.id)
            lastReviewer = restored.values.sorted { $0.updatedAt > $1.updatedAt }.first?.reviewer ?? ""
            filter = loaded.turnGuidanceSamples == nil ? (aiReviewedEvents.isEmpty ? "all" : "ai") : "all"
            errorMessage = nil
            status = "\(loaded.events.count) model moments loaded. Attach \(loaded.source.filename) to review."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadAIReviews(for loaded: ModelReviewBundle) {
        aiReviews = [:]
        aiLoadIssues = []
        for reviewer in AIReviewer.allCases {
            let saved = storageDirectory.appendingPathComponent("\(loaded.source.sha256)-\(reviewer.rawValue).ai-review.json")
            let resource = resourceBundle.url(forResource: "\(reviewer.rawValue).ai-review", withExtension: "json")
            let candidates = [saved, resource].compactMap { $0 }
            var issue: String?
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                do {
                    let review = try AIReviewSet.decode(Data(contentsOf: url))
                    try review.validate()
                    guard review.sourceSHA256 == loaded.source.sha256, review.reviewer == reviewer else { continue }
                    aiReviews[reviewer] = review
                    break
                } catch {
                    issue = "\(reviewer.title) review could not load: \(error.localizedDescription)"
                }
            }
            if aiReviews[reviewer] == nil, let issue { aiLoadIssues.append(issue) }
        }
    }

    func importAIReview() {
        guard let bundle, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "Choose a source-bound ChatGPT or Claude AI review file for this recording."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 16 * 1024 * 1024 else { throw ModelReviewError.invalid("The AI review file is too large.") }
            let review = try AIReviewSet.decode(bytes)
            try review.validate()
            guard review.sourceSHA256 == bundle.source.sha256,
                  review.responses.allSatisfy({ $0.time < bundle.source.duration }) else {
                throw ModelReviewError.invalid("These AI responses belong to a different recording.")
            }
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try Self.encoder.encode(review).write(to: storageDirectory.appendingPathComponent("\(bundle.source.sha256)-\(review.reviewer.rawValue).ai-review.json"), options: .atomic)
            aiReviews[review.reviewer] = review
            aiLoadIssues.removeAll { $0.hasPrefix(review.reviewer.title + " review") }
            errorMessage = nil
            status = "\(review.reviewer.title) responses loaded. Your reviews remain separate."
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseAnalysisVideo() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose an uncropped Motorfest gameplay video to analyze inside the app."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clearAnalysisSelection()
        if url.startAccessingSecurityScopedResource() { analysisScope = url }
        pendingAnalysisURL = url
        showsAnalysisOptions = true
    }

    func clearAnalysisSelection() {
        analysisScope?.stopAccessingSecurityScopedResource(); analysisScope = nil
        pendingAnalysisURL = nil
        showsAnalysisOptions = false
    }

    func beginAnalysis() {
        guard !isBusy, let url = pendingAnalysisURL, saveJournal() else { return }
        guard let start = Double(analysisStart), start.isFinite, start >= 0,
              analysisEnd.trimmingCharacters(in: .whitespaces).isEmpty || Double(analysisEnd).map({ $0.isFinite && $0 > start }) == true else {
            errorMessage = "Enter a valid start and end in seconds, or leave the end blank for the whole video."; return
        }
        let configuration = GuidanceAnalysisConfiguration(start: start, end: Double(analysisEnd),
            hudProfile: analysisProfile, speedUnit: analysisUnit, camera: analysisCamera)
        let output = storageDirectory.appendingPathComponent("analyses/\(UUID().uuidString)", isDirectory: true)
        let generation = UUID(); analysisGeneration = generation
        pause(); showsAnalysisOptions = false; isBusy = true; isAnalyzing = true
        analysisProgress = 0; errorMessage = nil; status = "Starting guidance analysis…"
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearAnalysisSelection(); self.analysisTask = nil }
            do {
                let result = try await GuidanceVideoAnalyzer().analyze(url: url, output: output, configuration: configuration) { [weak self] amount, message in
                    await MainActor.run {
                        guard let self, self.analysisGeneration == generation else { return }
                        self.analysisProgress = amount; self.status = message
                    }
                }
                try Task.checkCancellation()
                guard self.analysisGeneration == generation else { return }
                self.isAnalyzing = false; self.isBusy = false
                if self.loadTest(url: result) { self.attachVideo(url: url) }
            } catch {
                self.isAnalyzing = false; self.isBusy = false
                if error is CancellationError { self.status = "Analysis cancelled. Previous reviews are available." }
                else { self.errorMessage = error.localizedDescription; self.status = "Analysis did not complete." }
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel(); status = "Cancelling analysis…"
    }

    func chooseVideo() {
        guard bundle != nil, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Attach \(bundle!.source.filename). Its file identity will be checked against this test."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachVideo(url: url)
    }

    func attachVideo(url: URL) {
        guard let bundle, !isBusy else { return }
        player.pause()
        isBusy = true
        status = "Checking recording identity…"
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        let token = UUID()
        loadGeneration = token
        Task { [weak self] in
            guard let self else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            var keepAccess = false
            defer {
                if scoped && !keepAccess { url.stopAccessingSecurityScopedResource() }
                if self.loadGeneration == token { self.isBusy = false }
            }
            do {
                let hash = try await Task.detached(priority: .userInitiated) { try Self.fileHash(url) }.value
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard self.loadGeneration == token else { return }
                guard hash == bundle.source.sha256, duration.isFinite,
                      abs(duration - bundle.source.duration) < 0.1 else {
                    throw ModelReviewError.invalid("This recording does not match the model log. Attach the original \(bundle.source.filename).")
                }
                self.resetVideo()
                self.scopedVideo = scoped ? url : nil
                keepAccess = scoped
                self.videoURL = url
                let item = AVPlayerItem(asset: asset)
                self.itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item else { return }
                        let becameReady = !self.videoReady && item.status == .readyToPlay
                        self.videoReady = item.status == .readyToPlay
                        if becameReady, let event = self.selectedEvent { self.seek(to: event.time) }
                        if item.status == .failed { self.errorMessage = item.error?.localizedDescription ?? "Video playback failed." }
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.status = "Ready. Select a timestamp, replay its lead-in, and save your review."
                do {
                    let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try bookmark.write(to: self.storageDirectory.appendingPathComponent(bundle.source.sha256 + ".bookmark"), options: .atomic)
                } catch {
                    self.status += " Reattach the recording if it cannot reopen next time."
                }
            } catch {
                guard self.loadGeneration == token else { return }
                self.errorMessage = error.localizedDescription
                self.status = self.videoURL == nil ? "Attach the matching recording to continue." : "Previous recording remains attached."
            }
        }
    }

    private func restoreVideo() {
        guard let bundle else { return }
        let path = storageDirectory.appendingPathComponent(bundle.source.sha256 + ".bookmark")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: Data(contentsOf: path), options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            attachVideo(url: url)
        } catch { status = "Test restored. Attach \(bundle.source.filename) to resume playback." }
    }

    func select(_ event: ModelReviewEvent) {
        guard !isBusy else { return }
        selectedID = event.id
        seek(to: event.time)
    }

    func seek(to time: Double, playUntil end: Double? = nil) {
        guard videoReady, let bundle, time.isFinite else { return }
        cancelHistory()
        player.pause()
        let target = min(max(0, time), bundle.source.duration)
        let token = UUID()
        seekGeneration = token
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == token else { return }
                self.isSeeking = false
                guard completed else { self.errorMessage = "Could not seek to this timestamp. Try again."; return }
                self.currentTime = target
                if let end, end > target {
                    self.boundaryObserver = self.player.addBoundaryTimeObserver(
                        forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 60000))], queue: .main
                    ) { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.seekGeneration == token else { return }
                            self.seek(to: end)
                        }
                    }
                    self.player.play()
                }
            }
        }
    }

    func replayHistory() {
        guard let event = selectedEvent else { return }
        seek(to: max(0, event.time - 2), playUntil: event.time)
    }

    func replayTurn() {
        guard let event = selectedEvent, let bundle else { return }
        seek(to: max(0, event.time - 6), playUntil: min(bundle.source.duration, event.time + 2))
    }

    func nextTurnCue() {
        guard let events = bundle?.events.filter({ $0.turnGuidance?.isCueStart == true }), !events.isEmpty else { return }
        select(events.first(where: { $0.time > currentTime + 0.05 }) ?? events[0])
    }

    func nextCornerPhase() {
        guard let events = bundle?.events.filter({ $0.cornerTechnique?.isPhaseStart == true }), !events.isEmpty else { return }
        select(events.first(where: { $0.time > currentTime + 0.05 }) ?? events[0])
    }

    func togglePlayback() {
        guard videoReady, !isSeeking else { return }
        cancelHistory()
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    func pause() {
        seekGeneration = UUID()
        player.currentItem?.cancelPendingSeeks()
        isSeeking = false
        player.pause()
        cancelHistory()
        isPlaying = false
    }

    func editNote(_ change: (inout ModelReviewNote) -> Void) {
        guard var note = currentNote else { return }
        change(&note)
        if let event = selectedEvent {
            note.aiReviewSHA256 = Dictionary(uniqueKeysWithValues: AIReviewer.allCases.compactMap { reviewer in
                guard aiResponse(reviewer, for: event) != nil, let review = aiReviews[reviewer] else { return nil }
                return (reviewer.rawValue, review.originalReviewSHA256)
            })
        }
        note.reviewed = false
        note.updatedAt = Date()
        notes[note.key] = note
        lastReviewer = note.reviewer
        _ = saveJournal()
    }

    func completeReview(next: Bool = false) {
        guard var note = currentNote, note.canComplete, videoReady, !isBusy else { return }
        note.reviewed = true
        note.updatedAt = Date()
        notes[note.key] = note
        guard saveJournal() else {
            note.reviewed = false
            notes[note.key] = note
            return
        }
        status = "Review saved at \(reviewTimestamp(note.time))."
        if next, let events = bundle?.events,
           let index = events.firstIndex(where: { $0.id == selectedID }) {
            // Compute against the complete log so an Unreviewed filter cannot skip a row.
            let following = events.dropFirst(index + 1).first { event in
                switch filter {
                case "corner_phases": return event.cornerTechnique?.isPhaseStart == true
                case "answered": return event.hasAnswer(in: category)
                case "unknown": return !event.hasAnswer(in: category)
                case "unreviewed": return notes["\(event.id)|\(category.rawValue)"]?.reviewed != true
                default: return true
                }
            }
            if let following { select(following) }
        }
    }

    @discardableResult
    private func saveJournal() -> Bool {
        guard let bundle else { return true }
        do {
            let journal = makeJournal(bundle)
            try journal.validate(in: bundle)
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try Self.encoder.encode(journal).write(to: storageDirectory.appendingPathComponent(bundle.storageKey + ".feedback.json"), options: .atomic)
            status = "Changes saved locally."
            return true
        } catch {
            errorMessage = "Could not save feedback: \(error.localizedDescription) Your edits remain in this window."
            return false
        }
    }

    func exportFeedback() {
        guard let bundle, saveJournal() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(bundle.source.filename)-feedback.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.encoder.encode(makeJournal(bundle)).write(to: url, options: .atomic)
            status = "Feedback exported."
        } catch { errorMessage = error.localizedDescription }
    }

    private func makeJournal(_ bundle: ModelReviewBundle) -> ModelReviewJournal {
        ModelReviewJournal(schemaVersion: bundle.schemaVersion == "racing-trainer-review-v2" ? "racing-trainer-feedback-v2" : "racing-trainer-feedback-v1",
                           sourceSHA256: bundle.source.sha256, modelSHA256: bundle.modelSHA256,
                           predictionsSHA256: bundle.predictionsSHA256,
                           notes: notes.values.sorted { $0.key < $1.key })
    }

    private func resetVideo() {
        pause()
        seekGeneration = UUID()
        isSeeking = false
        itemObserver = nil
        player.replaceCurrentItem(with: nil)
        scopedVideo?.stopAccessingSecurityScopedResource()
        scopedVideo = nil
        videoURL = nil
        videoReady = false
        currentTime = 0
    }

    private func cancelHistory() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    private static func argument(_ key: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    nonisolated private static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 2 * 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
