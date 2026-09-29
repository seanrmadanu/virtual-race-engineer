import AVKit
import SwiftUI

/// First dataset/evaluation milestone, deliberately separate from live guidance.
struct CornerReplayLab: View {
    @ObservedObject var store: CornerReplayLabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Corner Replay Lab").font(.title2.bold())
                    Text("Offline reference comparison · no driving commands")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Compare reviewed samples", action: store.compare)
                    .buttonStyle(.borderedProminent)
                Button("Export report…", action: store.exportReport)
                    .disabled(store.report == nil)
            }

            Text("1. Load clips and identify the same car/setup and corner.  2. Mark matching entry, apex and exit landmarks.  3. Sample and review speeds, then compare.")
                .font(.callout)
            Text("Landmark timing is only approximate alignment—not measured road position. Reference speed is not an optimal target. Export labels before quitting; video files are not copied.")
                .font(.caption).foregroundStyle(.secondary)

            HSplitView {
                ReplayClipPane(title: "Player recording", clip: store.playerClip)
                ReplayClipPane(title: "Reference recording", clip: store.referenceClip)
            }
            .frame(minHeight: 400)

            if let report = store.report {
                ReplayReportView(report: report) { row in
                    store.playerClip.seek(to: row.time)
                    if let time = row.referenceTime { store.referenceClip.seek(to: time) }
                }
                .frame(height: 230)
            } else {
                Label("Compare after labeling. Any label or metadata edit clears the previous report.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 1100, minHeight: 780)
        .alert("Replay Lab", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onDisappear {
            store.playerClip.player.pause()
            store.referenceClip.player.pause()
        }
    }
}

private struct ReplayClipPane: View {
    let title: String
    @ObservedObject var clip: ReplayClipController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Menu("File") {
                        Button("Open video…") { clip.openVideo() }
                        Button("Import labels…", action: clip.importLabels)
                        Button("Attach original video…") { clip.openVideo(attach: true) }
                            .disabled(clip.session.sourceFileName.isEmpty)
                        Divider()
                        Button("Export labels…", action: clip.exportLabels)
                            .disabled(clip.session.sourceFileName.isEmpty)
                    }
                    .disabled(clip.isBusy)
                }
                if clip.videoURL != nil {
                    VideoPlayer(player: clip.player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(minHeight: 200)
                    HStack {
                        Text(seconds(clip.currentTime)).monospacedDigit()
                        Slider(value: Binding(get: { clip.currentTime }, set: { clip.seek(to: $0) }),
                               in: 0...max(clip.session.duration, 0.01))
                            .accessibilityLabel("\(title) video time")
                        Text(seconds(clip.session.duration)).monospacedDigit()
                    }
                    .font(.caption)
                } else {
                    ContentUnavailableView {
                        Label("No video attached", systemImage: "film")
                    } description: {
                        Text(clip.session.sourceFileName.isEmpty ? "Use a full, uncropped 16:9 recording." : clip.session.sourceFileName)
                    } actions: {
                        Button("Open video…") { clip.openVideo() }
                        if !clip.session.sourceFileName.isEmpty {
                            Button("Attach original…") { clip.openVideo(attach: true) }
                        }
                    }
                    .frame(height: 220)
                }
                Text(clip.session.sourceFileName.isEmpty ? "No recording selected" : clip.session.sourceFileName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(clip.session.sourceFileName)

                GroupBox("Recording identity") {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow { Text("Route"); TextField("e.g. island-route-01", text: $clip.session.metadata.routeID) }
                        GridRow { Text("Corner"); TextField("e.g. corner-03", text: $clip.session.metadata.cornerID) }
                        GridRow { Text("Car + setup"); TextField("Same car, tune, assists, conditions", text: $clip.session.metadata.setupID) }
                        GridRow { Text("Source group"); TextField("Original recording ID (for dataset splits)", text: $clip.session.metadata.sourceGroupID) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .padding(4)
                }

                landmarks
                sampling
                if !clip.session.samples.isEmpty { review }
                Text(clip.status).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 490)
        .alert("\(title)", isPresented: Binding(get: { clip.errorMessage != nil }, set: { if !$0 { clip.errorMessage = nil } })) {
            Button("OK") { clip.errorMessage = nil }
        } message: { Text(clip.errorMessage ?? "") }
    }

    private var landmarks: some View {
        GroupBox("Matching landmarks") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pause at the same visible place in both clips. Use identical names in the same order (at least two).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Landmark name", text: $clip.landmarkID).textFieldStyle(.roundedBorder)
                    Button("Mark here", action: clip.addLandmark)
                        .disabled(clip.videoURL == nil || clip.isBusy || clip.isSeeking)
                }
                ForEach(clip.session.landmarks) { landmark in
                    HStack {
                        Button("\(landmark.id) · \(seconds(landmark.time))") { clip.seek(to: landmark.time) }
                            .buttonStyle(.link)
                        Spacer()
                        Button {
                            clip.session.landmarks.removeAll { $0.id == landmark.id }
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).help("Remove \(landmark.id)")
                            .disabled(clip.isBusy)
                    }
                }
            }.padding(4)
        }
    }

    private var sampling: some View {
        GroupBox("Read speed from video") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Video HUD unit", selection: $clip.unit) {
                        ForEach(ReplaySpeedUnit.allCases) { unit in Text(unit.label).tag(unit) }
                    }.frame(maxWidth: 220)
                    Spacer()
                    Text("5 samples/sec").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("From")
                    TextField("seconds", value: $clip.rangeStart, format: .number.precision(.fractionLength(2)))
                    Text("to")
                    TextField("seconds", value: $clip.rangeEnd, format: .number.precision(.fractionLength(2)))
                    Text("sec")
                    Button("Start here") {
                        clip.rangeStart = clip.currentTime
                        clip.rangeEnd = min(clip.session.duration, clip.currentTime + 15)
                    }
                }.textFieldStyle(.roundedBorder)
                Text("Select the unit visible in the video; it is not detected automatically. Existing labels are always stored in km/h. Sampling replaces them with unreviewed readings.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Sample interval", action: clip.sampleVideo)
                        .disabled(clip.videoURL == nil || clip.isBusy)
                    if clip.isBusy {
                        ProgressView(value: clip.progress).frame(width: 120)
                        Button("Cancel", action: clip.cancelWork)
                    }
                    Spacer()
                    Text("\(clip.reviewedCount)/\(clip.session.samples.count) reviewed")
                        .font(.caption).monospacedDigit()
                }
            }.padding(4)
        }
    }

    private var review: some View {
        GroupBox("Verify each sample against the video HUD") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(clip.reviewTime.map { "At \(seconds($0))" } ?? "Select a sample")
                        .font(.caption).monospacedDigit()
                    TextField("Speed in km/h", text: $clip.reviewSpeed)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                    Text("km/h").font(.caption)
                    Spacer()
                }
                HStack {
                    Button("Confirm & next") { clip.reviewSample() }.disabled(!clip.canReview)
                    Button("Unreadable & next") { clip.reviewSample(missing: true) }.disabled(!clip.canReview)
                }
                Text("Pause on the selected frame. Correct the value first if needed. For mph footage, multiply the HUD reading by 1.609344. No bulk approval.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(clip.session.samples) { sample in
                            Button {
                                clip.selectSample(sample)
                            } label: {
                                HStack {
                                    Image(systemName: sample.reviewed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(sample.reviewed ? Color.green : Color.secondary)
                                    Text(seconds(sample.time)).monospacedDigit()
                                    Spacer()
                                    Text(sample.speedKPH.map { String(format: "%.1f km/h", $0) } ?? "Unreadable")
                                    Text(sample.reviewed ? "Reviewed" : "OCR only")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 5)
                                .background(clip.reviewTime == sample.time ? Color.accentColor.opacity(0.12) : .clear)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 150)
            }.padding(4)
        }
    }
}

private struct ReplayReportView: View {
    let report: ReplayReport
    let onSelect: (ReplayComparison) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Comparison timeline").font(.headline)
                Spacer()
                Text("\(report.summary.comparableCount)/\(report.summary.totalCount) comparable")
                if let gap = report.summary.meanAbsoluteSpeedGapKPH {
                    Text(String(format: "Mean absolute speed gap: %.1f km/h", gap))
                }
            }.font(.callout)
            Text("±10 km/h is a provisional comparison band, not a braking threshold. Below reference does not mean accelerate. Click a row to inspect both clips.")
                .font(.caption).foregroundStyle(.secondary)
            if !report.notes.isEmpty {
                Text(report.notes.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .help(report.notes.joined(separator: "\n"))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.rows) { row in
                        Button { onSelect(row) } label: {
                            HStack(spacing: 12) {
                                Text(seconds(row.time)).frame(width: 68, alignment: .leading)
                                Text(row.playerKPH.map { String(format: "Player %.1f", $0) } ?? "Player —").frame(width: 110, alignment: .leading)
                                Text(row.referenceKPH.map { String(format: "Ref %.1f", $0) } ?? "Ref —").frame(width: 100, alignment: .leading)
                                Text(row.deltaKPH.map { String(format: "%+.1f km/h", $0) } ?? "—").frame(width: 100, alignment: .leading)
                                Text(label(row.status)).frame(width: 120, alignment: .leading)
                                    .foregroundStyle(row.status == .withheld ? Color.secondary : Color.primary)
                                Text(row.reason).foregroundStyle(.secondary).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .font(.caption).monospacedDigit().padding(.vertical, 5).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private func label(_ status: ReplayComparisonStatus) -> String {
        switch status {
        case .withheld: "Withheld"
        case .aboveReference: "Above reference"
        case .belowReference: "Below reference"
        case .nearReference: "Near reference"
        }
    }
}

private func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
