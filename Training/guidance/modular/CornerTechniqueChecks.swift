import AppKit
import Foundation
import SwiftUI

/// Exercises the actual review store and readout with a newly analyzed recording.
/// All feedback stays in the caller's new QA directory and remains a draft.
@main struct CornerTechniqueChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else {
            throw ModelReviewError.invalid("Usage: check-corner-technique.sh REVIEW_JSON VIDEO NEW_QA_DIRECTORY")
        }
        let directory = URL(fileURLWithPath: args[2])
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Use a new QA directory")
        let store = ModelReviewStore(storageDirectory: directory)
        let url = URL(fileURLWithPath: args[0])
        precondition(store.loadTest(url: url), store.errorMessage ?? "Load failed")
        guard let samples = store.bundle?.cornerTechniqueSamples, !samples.isEmpty else {
            throw ModelReviewError.invalid("No Category 2 samples in this run")
        }
        store.category = .cornerTechnique
        store.filter = "corner_phases"
        precondition(!store.visibleEvents.isEmpty)
        precondition(store.visibleEvents.allSatisfy { $0.cornerTechnique?.isPhaseStart == true })
        let first = store.visibleEvents[0]
        store.select(first)
        store.editNote { note in
            note.reviewer = "Automated draft fixture"
            note.cornerPhaseCorrection = "cornering"
            note.verdict = .unclear
        }
        let key = store.currentNote!.key
        store.category = .basicTurns
        precondition(store.currentNote?.cornerPhase == nil)
        precondition(store.loadTest(url: url), store.errorMessage ?? "Reload failed")
        store.category = .cornerTechnique; store.filter = "corner_phases"
        precondition(store.notes[key]?.cornerPhase == "cornering" && store.notes[key]?.reviewed == false)
        print("PASS phase filter and separate Category 2 draft persistence; no reviewed labels created")

        store.attachVideo(url: URL(fileURLWithPath: args[1]))
        for _ in 0..<400 {
            if store.videoReady && !store.isSeeking { break }
            if let error = store.errorMessage { throw ModelReviewError.invalid(error) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(store.videoReady, store.status)
        store.select(first)
        for _ in 0..<200 {
            if !store.isSeeking { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(abs(store.currentTime - first.time) < 0.03)
        precondition(store.cornerAtPlayhead == first.cornerTechnique)
        let expected = store.visibleEvents.first { $0.time > first.time + 0.05 } ?? first
        store.nextCornerPhase()
        for _ in 0..<200 {
            if !store.isSeeking { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(store.selectedEvent?.id == expected.id)
        precondition(store.cornerAtPlayhead == expected.cornerTechnique)
        store.select(first)
        for _ in 0..<200 {
            if !store.isSeeking { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(store.cornerAtPlayhead == first.cornerTechnique)
        store.pause()
        print("PASS original-video identity, Next Phase navigation, backward seek, and playhead phase synchronization")

        let examples = CornerTechniquePhase.allCases.compactMap { phase in samples.first { $0.phase == phase } }
        let view = VStack(spacing: 12) {
            ForEach(examples, id: \.phase) { sample in
                CornerTechniqueReadout(sample: sample, hasAnalysis: true)
            }
        }.padding(20).frame(width: 640).background(Color(nsColor: .windowBackgroundColor))
        // ImageRenderer omits AppKit-backed GroupBox content in a CLI. Render
        // an owned, off-screen hosting view instead; no running-app capture.
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        precondition(size.width >= 640 && size.height > 400)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ModelReviewError.invalid("Could not render the readout preview")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ModelReviewError.invalid("Could not encode the readout preview")
        }
        try data.write(to: directory.appendingPathComponent("corner-technique-readouts.png"))
        print("Rendered real phase readouts from this recording")
    }
}
