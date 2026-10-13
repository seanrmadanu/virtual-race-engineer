import AVKit
import SwiftUI

/// One place to inspect recorded model decisions and write timestamped feedback.
struct ModelReviewView: View {
    @ObservedObject var store: ModelReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("Skill Category", selection: $store.category) {
                ForEach(ReviewSkillCategory.allCases.filter { $0 != .slowdownTiming || store.bundle?.schemaVersion == "racing-trainer-review-v2" }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(store.category.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if store.bundle != nil {
                HSplitView {
                    playbackPane.frame(minWidth: 400, idealWidth: 600)
                    if store.category == .advanced {
                        advancedPane.frame(minWidth: 340, idealWidth: 420)
                    } else {
                        reviewPane.frame(minWidth: 590, idealWidth: 680)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Test a Gameplay Video", systemImage: "play.rectangle.on.rectangle")
                } description: {
                    Text("Analyze a Motorfest video, then watch the guidance and road markings at each timestamp. Your reviews save with that recording and analysis run.")
                } actions: {
                    Button("Analyze Video…", action: store.chooseAnalysisVideo).buttonStyle(.borderedProminent).disabled(store.isBusy)
                    Button("Open Saved Test…", action: store.openTest).disabled(store.isBusy)
                }
            }
        }
        .padding(18)
        .font(.body)
        .frame(minWidth: 1060, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Model Review")
        .navigationSubtitle(store.bundle?.source.filename ?? "Racing Trainer")
        .toolbar {
            Button("Analyze Video…", systemImage: "video.badge.waveform", action: store.chooseAnalysisVideo).disabled(store.isBusy)
            Button("Open Test…", systemImage: "folder", action: store.openTest).disabled(store.isBusy)
            Button("Import AI Review…", systemImage: "text.badge.plus", action: store.importAIReview)
                .disabled(store.bundle == nil || store.isBusy)
            Button("Attach Video…", systemImage: "film", action: store.chooseVideo)
                .disabled(store.bundle == nil || store.isBusy)
            Button("Export Reviews…", systemImage: "square.and.arrow.up", action: store.exportFeedback)
                .disabled(store.bundle == nil || store.notes.isEmpty || store.isBusy)
        }
        .onAppear { store.start() }
        .onDisappear { store.pause() }
        .onChange(of: store.category) { _, _ in store.pause() }
        .sheet(isPresented: $store.showsAnalysisOptions, onDismiss: {
            if !store.isAnalyzing { store.clearAnalysisSelection() }
        }) { analysisOptions }
    }

    private var analysisOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Analyze Gameplay").font(.title2.bold())
            Text(store.pendingAnalysisURL?.lastPathComponent ?? "Choose a video").foregroundStyle(.secondary)
            Form {
                TextField("Start (seconds)", text: $store.analysisStart)
                TextField("End (blank = video end)", text: $store.analysisEnd)
                Picker("HUD Layout", selection: $store.analysisProfile) {
                    Text("Standard Motorfest HUD").tag("motorfest-standard-v1")
                    Text("Reference Recording HUD").tag("reference-video2-v1")
                    Text("Unconfirmed Layout").tag("unconfirmed")
                }
                Picker("Speed Unit", selection: $store.analysisUnit) {
                    Text("km/h").tag("km/h")
                    Text("mph").tag("mph")
                    Text("Unknown").tag("unknown")
                }
                Picker("Road Camera", selection: $store.analysisCamera) {
                    ForEach(RoadCameraMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Text("Use the layout and camera visible in the recording. For a camera change, analyze separate ranges. White-line bounds are experimental; unclear markings remain unavailable.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: store.clearAnalysisSelection).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Analyze", action: store.beginAnalysis).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }

    private func aiLogCell(_ reviewer: AIReviewer, event: ModelReviewEvent) -> some View {
        let response = store.aiResponse(reviewer, for: event)
        let summary = response?.summary(in: store.category) ?? "No review at this time"
        return Text(summary)
            .foregroundStyle(response == nil ? .secondary : .primary)
            .lineLimit(2).frame(width: 140, alignment: .leading)
            .help(response?.observation ?? "No \(reviewer.title) response for this exact source timestamp.")
            .accessibilityLabel("\(reviewer.title): \(summary)")
    }

    private func aiComparison(_ event: ModelReviewEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Reviews · \(reviewTimestamp(event.time))").font(.headline)
            Text("Reference opinions for this source moment. Your verdict is saved separately.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                aiCard(.chatgpt, event: event)
                aiCard(.claude, event: event)
            }
        }
    }

    private func aiCard(_ reviewer: AIReviewer, event: ModelReviewEvent) -> some View {
        GroupBox(reviewer.title) {
            VStack(alignment: .leading, spacing: 8) {
                if let response = store.aiResponse(reviewer, for: event), let review = store.aiReviews[reviewer] {
                    Text(reviewLabel(response.action)).font(.headline)
                    Text("Confidence: \(response.confidence)").font(.callout)
                    Text("Current: \(response.current.isEmpty ? "Not separately labeled" : response.current)")
                    Text("Upcoming: \(response.upcoming.isEmpty ? "Not separately labeled" : response.upcoming)")
                    Text(response.intervalDescription).monospacedDigit().font(.callout)
                    if let end = response.intervalEnd, end < event.time {
                        Label("Cue interval ends before this timestamp", systemImage: "clock.badge.exclamationmark")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text(review.origin == "ai_raw_video_blind" ? "Blind raw-video review" : "Review after model output")
                        .font(.caption).foregroundStyle(.secondary)
                    if review.reviewedPipelineSHA256 != store.bundle?.modelSHA256 {
                        Text("Reference from an earlier app analysis").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Review Details") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(response.observation)
                            Text(response.rationale)
                            if !response.questions.isEmpty {
                                Text("Open Questions").font(.headline)
                                ForEach(Array(response.questions.enumerated()), id: \.offset) { _, question in
                                    Text("• \(question)")
                                }
                            }
                        }.padding(.top, 6).textSelection(.enabled)
                    }
                } else {
                    Text("No review at \(reviewTimestamp(event.time))").font(.headline)
                    if store.aiReviewCount(reviewer) > 0 {
                        Text("\(reviewer.title) reviewed \(store.aiReviewCount(reviewer)) specific moments in this test.")
                            .foregroundStyle(.secondary)
                        Button("Go to an AI Review", action: store.showAIReviews).disabled(store.isBusy)
                    } else {
                        Text("No matching \(reviewer.title) reviews are loaded for this test. Use Import AI Review to add them.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.bundle?.title ?? "Model Review").font(.title2.bold())
                    Text("Watch a moment. Check the answer. Leave your review.").foregroundStyle(.secondary)
                }
                Spacer()
                if let bundle = store.bundle, store.category != .advanced {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(store.reviewedCount) / \(bundle.events.count) Reviewed").font(.headline).monospacedDigit()
                        Text("Model answered \(store.answeredCount) / \(bundle.events.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                            .help("How often the model answered. Accuracy has not been measured.")
                    }
                }
            }
            if let bundle = store.bundle {
                HStack(alignment: .firstTextBaseline) {
                    Label("ChatGPT: \(store.aiReviewCount(.chatgpt)) reviews · Claude: \(store.aiReviewCount(.claude)) reviews",
                          systemImage: "text.bubble")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if store.filter != "ai", !store.aiReviewedEvents.isEmpty {
                        Button("Show AI Reviews", action: store.showAIReviews).disabled(store.isBusy)
                    }
                }
                Text("AI reviews cover \(store.aiReviewedEvents.count) of \(bundle.events.count) timestamps. The app analyzes every second; AI responses appear only at the moments each reviewer inspected.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(store.aiLoadIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Text(store.status).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if store.isAnalyzing {
                HStack {
                    ProgressView(value: store.analysisProgress).frame(maxWidth: 500)
                    Text("\(Int(store.analysisProgress * 100))%").monospacedDigit()
                    Button("Cancel Analysis", action: store.cancelAnalysis)
                }
            }
        }
    }

    private var playbackPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.videoURL != nil {
                    ModelReviewPlayer(player: store.player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            GeometryReader { proxy in
                                RoadLineOverlay(observation: store.roadAtPlayhead, time: store.currentTime,
                                    videoRect: CGRect(origin: .zero, size: proxy.size))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Gameplay recording")
                    playbackControls
                    if store.category == .basicTurns { turnGuidanceReadout }
                    Label(store.bundle?.roadObservations == nil ? "Analyze this video to inspect white road markings"
                        : store.roadAtPlayhead.isFresh(at: store.currentTime) ? store.roadAtPlayhead.reason : "Waiting for fresh road markings",
                          systemImage: "road.lanes")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView {
                        Label("Attach the Recording", systemImage: "film")
                    } description: {
                        Text(store.bundle?.source.filename ?? "Select the matching gameplay video.")
                    } actions: {
                        Button("Attach Video…", action: store.chooseVideo).disabled(store.isBusy)
                    }
                    .frame(height: 300)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if let event = store.playbackEvent {
                            Text("Model Log · \(reviewTimestamp(event.time))").font(.headline)
                            Text(event.summary(in: store.category)).font(.title3.weight(.semibold))
                            Text(event.diagnostics == nil ? "Recorded output at this timestamp. Samples are five seconds apart."
                                : store.bundle?.turnGuidanceSamples != nil ? "Experimental turn timing · 10 Hz cues · exact cue onsets in the log."
                                : store.bundle?.roadObservations != nil ? "Experimental guidance · 10 Hz module samples · one review moment per second."
                                : "Frozen development pilot · selected moments from a 10 Hz module history.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No Model Sample Yet").font(.headline)
                            Text("Play the video or select a timestamp in the log.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let event = store.selectedEvent {
                    aiComparison(event)
                    if let diagnostics = event.diagnostics { moduleDiagnostics(diagnostics, time: event.time) }
                }
                DisclosureGroup("How to Judge This Category") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use the road, minimap and two-second history. Ignore the steering-wheel inset.")
                        if store.category == .basicTurns {
                            Text("Check the turn direction first. Then judge the heads-up and Turn Now separately: early, correctly timed, late, or missed. Mark the interval where the cue should occur. A bend being exited and the next turn can have different directions.")
                        } else if store.category == .cornerTechnique {
                            Text("Approach means before the bend; entry means beginning it; exit means unwinding out of it. Leave uncertain phases unknown. Apex is available for your notes but is not trained in this model.")
                        }
                        Text("Use Unusable View for camera orbits, cutscenes or obstructed footage. Unknown is a model answer worth reviewing too.")
                        Text("Your feedback is saved after you have seen the model output; it supports error review. Independent accuracy needs a separate blind check.")
                    }.foregroundStyle(.secondary).padding(.top, 6)
                }
            }.padding(.trailing, 12)
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(reviewPreciseTimestamp(store.currentTime)).monospacedDigit().frame(minWidth: 60)
                Slider(value: Binding(get: { store.currentTime }, set: { store.seek(to: $0) }),
                       in: 0...max(store.bundle?.source.duration ?? 0, 0.01))
                    .accessibilityLabel("Video Position")
                Text(reviewTimestamp(store.bundle?.source.duration ?? 0)).monospacedDigit()
            }
            HStack {
                Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill",
                       action: store.togglePlayback)
                Button("Replay 2 Seconds", systemImage: "arrow.counterclockwise", action: store.replayHistory)
                    .disabled(store.selectedEvent == nil)
                    .help("Play the two seconds before the selected moment, then pause at its timestamp.")
                Spacer()
                if let selected = store.selectedEvent {
                    Button("Go to \(reviewTimestamp(selected.time))") { store.seek(to: selected.time) }
                }
            }
            if store.category == .basicTurns {
                HStack {
                    Button("−0.1 s") { store.seek(to: store.currentTime - 0.1) }
                    Button("+0.1 s") { store.seek(to: store.currentTime + 0.1) }
                    Button("Replay Turn", action: store.replayTurn)
                        .help("Play six seconds before and two seconds after the selected moment.")
                    Spacer()
                    Button("Next Cue", action: store.nextTurnCue)
                        .disabled(store.bundle?.turnGuidanceSamples == nil)
                }
            }
        }
        .controlSize(.large)
        .disabled(!store.videoReady || store.isBusy)
    }

    private var turnGuidanceReadout: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Turn Guidance", systemImage: "arrow.triangle.turn.up.right.diamond").font(.headline)
                    Spacer()
                    Text("Experimental timing").font(.caption).foregroundStyle(.secondary)
                }
                Text(store.turnAtPlayhead?.title ?? "Analyze this video to test turn timing")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(store.turnAtPlayhead?.stage == .turnNow ? Color.green : Color.primary)
                    .accessibilityAddTraits(.updatesFrequently)
                Text(store.turnAtPlayhead?.reason ?? "This saved run contains direction labels only.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var reviewPane: some View {
        let playbackID = store.videoReady ? store.playbackEvent?.id : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Timestamp Log").font(.headline)
                Spacer()
                Picker("Show", selection: $store.filter) {
                    Text("All Moments").tag("all")
                    Text("AI Reviewed").tag("ai")
                    Text("Turn Cues").tag("turn_cues")
                    Text("Model Answered").tag("answered")
                    Text("Model Unknown").tag("unknown")
                    Text("Unreviewed").tag("unreviewed")
                }.frame(maxWidth: 215)
            }
            if store.category == .basicTurns {
                Text("App shows navigation cues. AI Now/Next describe current and upcoming bends; their frozen reviews do not label these new turn-in cues.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let playbackID, let event = store.playbackEvent,
               !store.visibleEvents.contains(where: { $0.id == playbackID }) {
                HStack {
                    Text("Current moment \(reviewTimestamp(event.time)) is hidden by this filter.")
                        .foregroundStyle(.secondary)
                    Button("Show All") { store.filter = "all" }
                }
            }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Time").frame(width: 74, alignment: .leading)
                    Text("App").frame(width: 102, alignment: .leading)
                    Text("ChatGPT").frame(width: 140, alignment: .leading)
                    Text("Claude").frame(width: 140, alignment: .leading)
                    Spacer(minLength: 0)
                }.font(.callout.weight(.semibold)).padding(.horizontal, 12)
                List(store.visibleEvents) { event in
                    let isAtPlayhead = event.id == playbackID
                    let isReviewing = event.id == store.selectedID
                    Button { store.select(event) } label: {
                        HStack(spacing: 8) {
                            Text(reviewPreciseTimestamp(event.time)).monospacedDigit().foregroundStyle(.tint)
                                .fontWeight(isAtPlayhead ? .bold : .regular)
                                .frame(width: 74, alignment: .leading)
                            Text(event.summary(in: store.category))
                                .frame(width: 102, alignment: .leading).lineLimit(2)
                            aiLogCell(.chatgpt, event: event)
                            aiLogCell(.claude, event: event)
                            Spacer(minLength: 0)
                            if isAtPlayhead {
                                Label("Now", systemImage: "play.fill")
                                    .font(.caption.weight(.semibold))
                                    .help("The model sample at the current video position.")
                            }
                            if isReviewing {
                                Image(systemName: "pencil.circle")
                                    .help("Reviewing this moment. Playback does not move your notes.")
                                    .accessibilityLabel("Reviewing")
                            }
                            if store.notes["\(event.id)|\(store.category.rawValue)"]?.reviewed == true {
                                Image(systemName: "checkmark.circle.fill").accessibilityLabel("Reviewed")
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isAtPlayhead ? Color.accentColor.opacity(0.22)
                        : (isReviewing ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear))
                    .accessibilityLabel("\(reviewTimestamp(event.time)), \(event.summary(in: store.category))")
                    .accessibilityValue([isAtPlayhead ? "At playhead" : nil,
                                         isReviewing ? "Reviewing" : nil].compactMap { $0 }.joined(separator: ", "))
                    .id(event.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 160, idealHeight: 240, maxHeight: 280)
                .overlay {
                    if store.visibleEvents.isEmpty { Text("No moments match this filter.").foregroundStyle(.secondary) }
                }
                .onChange(of: store.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: playbackID, initial: true) { _, id in
                    // Follow the actual sample, never the previous row surviving a filter.
                    // No animated scrolling or editor selection changes during playback.
                    if let id, store.visibleEvents.contains(where: { $0.id == id }) {
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: store.visibleEvents.map(\.id)) { _, ids in
                    if let playbackID, ids.contains(playbackID) { proxy.scrollTo(playbackID) }
                }
                }
            }
            Divider()
            if let event = store.selectedEvent, let note = store.currentNote {
                noteEditor(event: event, note: note)
            }
        }.padding(.leading, 12)
    }

    private func noteEditor(event: ModelReviewEvent, note: ModelReviewNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your Review · \(reviewPreciseTimestamp(event.time))").font(.headline)
                        Spacer()
                        Text(note.reviewed ? "Saved" : "Draft").foregroundStyle(.secondary)
                    }
                    Text("Model: \(event.summary(in: store.category))").textSelection(.enabled)
                    if store.category == .basicTurns, event.turnGuidance != nil {
                        Text("Route: \(reviewLabel(event.direction)) · \(reviewLabel(event.target))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    TextField("Your Name", text: noteBinding(\.reviewer))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Reviewer Name")
                    Picker(store.category == .basicTurns ? "Direction Verdict" : "Verdict", selection: Binding(get: { note.verdict }, set: { value in store.editNote { $0.verdict = value } })) {
                        ForEach(ReviewVerdict.allCases) { Text($0.title).tag($0) }
                    }
                    if store.category == .basicTurns {
                        correctionPicker("Direction", key: \.direction, choices: ModelReviewBundle.directions)
                        correctionPicker("Corner", key: \.target, choices: ModelReviewBundle.targets)
                        turnTimingEditor(note)
                    } else if store.category == .slowdownTiming {
                        slowdownEditor(note)
                    } else {
                        correctionPicker("Phase", key: \.phase, choices: ModelReviewBundle.phases)
                    }
                    Text("What did you see?").font(.headline)
                    TextEditor(text: noteBinding(\.text))
                        .font(.body).frame(minHeight: 80, idealHeight: 100)
                        .padding(4).background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                        .accessibilityLabel("Review Notes")
                    Text("Edits save locally as a draft. Add your name and verdict, then save the review.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 8)
            }
            HStack {
                Button("Save Review") { store.completeReview() }
                Button("Save & Next") { store.completeReview(next: true) }.buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(!note.canComplete || !store.videoReady || store.isBusy)
        }
    }

    private func noteBinding(_ key: WritableKeyPath<ModelReviewNote, String>) -> Binding<String> {
        Binding(get: { store.currentNote?[keyPath: key] ?? "" }, set: { value in store.editNote { $0[keyPath: key] = value } })
    }

    private func turnTimingBinding(_ key: WritableKeyPath<TurnTimingReview, String>) -> Binding<String> {
        Binding(get: { (store.currentNote?.turnTiming ?? TurnTimingReview())[keyPath: key] }, set: { value in
            store.editNote { note in
                var timing = note.turnTiming ?? TurnTimingReview()
                timing[keyPath: key] = value; note.turnTiming = timing
            }
        })
    }

    private func turnTimingEditor(_ note: ModelReviewNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Turn Timing").font(.headline)
            Picker("Cue to Review", selection: turnTimingBinding(\.cue)) {
                Text("Upcoming-turn heads-up").tag("heads_up")
                Text("Turn now").tag("turn_now")
                Text("No cue needed").tag("no_cue")
                Text("Cannot judge").tag("uncertain")
            }
            Picker("Timing Verdict", selection: Binding(get: { note.turnTiming?.verdict ?? .pending }, set: { value in
                store.editNote { note in
                    var timing = note.turnTiming ?? TurnTimingReview()
                    timing.verdict = value; note.turnTiming = timing
                }
            })) {
                ForEach(ReviewVerdict.allCases) { Text($0.title).tag($0) }
            }
            Text("Acceptable cue interval · seconds from video start").font(.callout)
            HStack {
                TextField("Start", text: turnTimingBinding(\.start)).accessibilityLabel("Turn Timing Start Seconds")
                Button("Use Playhead") { turnTimingBinding(\.start).wrappedValue = String(format: "%.1f", store.currentTime) }
                TextField("End", text: turnTimingBinding(\.end)).accessibilityLabel("Turn Timing End Seconds")
                Button("Use Playhead") { turnTimingBinding(\.end).wrappedValue = String(format: "%.1f", store.currentTime) }
            }.textFieldStyle(.roundedBorder)
            Text("For a missed cue, mark when it should have happened. Use Unsure when the footage cannot establish turn-in timing.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func slowdownBinding(_ key: WritableKeyPath<SlowdownReview, String>) -> Binding<String> {
        Binding(get: { (store.currentNote?.slowdown ?? SlowdownReview())[keyPath: key] }, set: { value in
            store.editNote { note in
                var timing = note.slowdown ?? SlowdownReview()
                timing[keyPath: key] = value; note.slowdown = timing
            }
        })
    }

    private func slowdownEditor(_ note: ModelReviewNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Your Cue", selection: slowdownBinding(\.action)) {
                Text("Choose Your Label").tag("")
                ForEach(SlowdownReview.actions, id: \.self) { Text(reviewLabel($0)).tag($0) }
            }
            Text("Acceptable cue interval · seconds from video start").font(.headline)
            HStack {
                TextField("Start, e.g. 95.0", text: slowdownBinding(\.start)).accessibilityLabel("Acceptable Start Seconds")
                TextField("End, e.g. 97.0", text: slowdownBinding(\.end)).accessibilityLabel("Acceptable End Seconds")
            }.textFieldStyle(.roundedBorder)
            Text("For no cue, enter the interval that needs no advice. Use Uncertain when video cannot establish the action. Slowing down does not prove braking.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if note.slowdown?.isComplete != true {
                Text("Choose a label and valid interval, or mark the example uncertain.").foregroundStyle(.secondary)
            }
        }
    }

    private func moduleDiagnostics(_ diagnostics: ModuleReviewDiagnostics, time: Double) -> some View {
        GroupBox("Evidence for Selected Review · \(reviewTimestamp(time))") {
            VStack(alignment: .leading, spacing: 10) {
                if let suggested = diagnostics.suggestedLabel {
                    Text("Label Hypothesis: \(reviewLabel(suggested)) · Unreviewed").font(.headline)
                    Text(diagnostics.suggestedRationale ?? "Check this proposal yourself before accepting it.")
                        .foregroundStyle(.secondary)
                }
                Text("Proposal: \(reviewLabel(diagnostics.proposedCue)) · Guard: \(reviewLabel(diagnostics.cue))").font(.headline)
                Text("\(diagnostics.origin): \(diagnostics.proposalReason)").textSelection(.enabled)
                Text("Suppression: \(diagnostics.suppressionReasons.isEmpty ? "None" : diagnostics.suppressionReasons.joined(separator: ", "))")
                Text("Legacy policy comparison: \(diagnostics.legacyPolicy)").foregroundStyle(.secondary)
                Text("Scores below are module diagnostics, not measured accuracy. Camera checks and physical calibration are incomplete.")
                    .foregroundStyle(.secondary)
                ForEach(diagnostics.modules) { module in
                    DisclosureGroup("\(module.name.capitalized): \(module.value) \(module.units) · \(module.state)") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Score \(module.confidence, specifier: "%.3f") · \(module.confidenceKind)")
                            Text("Age: \(module.age.map { String(format: "%.3f s", $0) } ?? "Missing") · Version: \(module.version)")
                            Text("Failure: \(module.failure ?? "None reported")")
                            ForEach(module.evidence.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(module.evidence[key] ?? "")").textSelection(.enabled)
                            }
                            if let captured = module.capturedAt {
                                Button("Show Evidence Frame · \(reviewTimestamp(captured))") { store.seek(to: captured) }
                                    .disabled(!store.videoReady)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func correctionPicker(_ title: String, key: WritableKeyPath<ModelReviewNote, String>, choices: [String]) -> some View {
        Picker("Your \(title)", selection: noteBinding(key)) {
            Text("No Correction Specified").tag("")
            ForEach(choices, id: \.self) { Text(reviewLabel($0)).tag($0) }
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Category 3 · Planned", systemImage: "flag.checkered").font(.title3.bold())
            Text("This category will cover braking technique, linked corners, grip management and traffic decisions.")
            Text("The current model produces basic direction and coarse corner phases. Advanced outputs will appear here when a trained version supports them.")
                .foregroundStyle(.secondary)
            Button("Review Basic Turns") { store.category = .basicTurns }
            Spacer()
        }.padding(20)
    }
}

/// Keep the AppKit player linked explicitly; also supplies native seek/volume controls.
private struct ModelReviewPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ModelReviewCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: ModelReviewStore

    var body: some Commands {
        CommandMenu("Model Review") {
            Button("Show Model Review") { openWindow(id: "model-review") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open Test…") { openWindow(id: "model-review"); store.openTest() }.disabled(store.isBusy)
            Button("Analyze Video…") { openWindow(id: "model-review"); store.chooseAnalysisVideo() }.disabled(store.isBusy)
            Button("Import AI Review…", action: store.importAIReview).disabled(store.bundle == nil || store.isBusy)
            Button("Cancel Analysis", action: store.cancelAnalysis).disabled(!store.isAnalyzing)
            Button("Attach Video…", action: store.chooseVideo).disabled(store.bundle == nil || store.isBusy)
            Button("Export Reviews…", action: store.exportFeedback).disabled(store.bundle == nil || store.notes.isEmpty)
            Divider()
            Button("Play / Pause", action: store.togglePlayback).disabled(!store.videoReady)
            Button("Replay Selected Moment", action: store.replayHistory).disabled(!store.videoReady || store.selectedEvent == nil)
            Button("Save Review") { store.completeReview() }.disabled(store.currentNote?.canComplete != true || !store.videoReady)
            Button("Save & Next") { store.completeReview(next: true) }.disabled(store.currentNote?.canComplete != true || !store.videoReady)
        }
    }
}
