import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("guidance.hudProfile") private var guidanceHUDProfile = "motorfest-standard-v1"
    @AppStorage("guidance.speedUnit") private var guidanceSpeedUnit = "km/h"
    @State private var loadedArgumentVideo = false
    @State private var loadedArgumentStart = false

    @ObservedObject var captureDevices:
        CaptureDeviceManager

    @StateObject private var captureSession:
        CaptureSessionManager

    @StateObject private var videoFilePlayback:
        VideoFilePlaybackController

    @State private var noConnectionAnimator =
        NoConnectionAnimator()

    @State private var isVideoFullscreen =
        false

    @State private var videoFullscreenOwnsNativeFullscreen =
        false

    @AppStorage("preview.showsAnalyzerOverlay")
    private var showsAnalyzerDebug =
        false

    @AppStorage("preview.showsHUDRegions")
    private var showsHUDRegions =
        false

    @AppStorage("window.showsSidebar")
    private var showsSidebar =
        true

    @State private var gameVolume =
        0.80

    @State private var trainerVolume =
        0.65

    @State private var gameMuted =
        false

    @State private var trainerMuted =
        false

    init(
        captureDevices:
            CaptureDeviceManager
    ) {
        _captureDevices =
            ObservedObject(
                wrappedValue:
                    captureDevices
            )

        let captureSession =
            CaptureSessionManager()

        _captureSession =
            StateObject(
                wrappedValue:
                    captureSession
            )

        _videoFilePlayback =
            StateObject(
                wrappedValue:
                    VideoFilePlaybackController(
                        frameAnalyzer:
                            captureSession
                                .frameAnalyzer,
                        minimapDatasetRecorder:
                            captureSession
                                .minimapDatasetRecorder,
                        shadowPipeline: captureSession.shadowPipeline
                    )
            )
    }

    // MARK: - Source Information

    private var isUsingVideoFile:
        Bool {

        videoFilePlayback
            .hasLoadedVideo
    }

    private var isCurrentSourceReady:
        Bool {

        isUsingVideoFile
        ? videoFilePlayback
            .isReady
        : captureSession
            .isReceivingVideo
    }

    private var currentVideoError:
        String? {

        isUsingVideoFile
        ? videoFilePlayback
            .errorMessage
        : captureSession
            .errorMessage
    }

    private var hasAvailableInputSource:
        Bool {

        isUsingVideoFile ||
        !captureDevices
            .videoDevices
            .isEmpty
    }

    private var hasActiveInputSource:
        Bool {

        isUsingVideoFile ||
        captureDevices
            .activeDeviceID != nil
    }

    private var sourceStatusText:
        String {

        if isUsingVideoFile {
            let fileName =
                videoFilePlayback
                    .loadedFileName ??
                "Test Video"

            if videoFilePlayback
                .errorMessage != nil {

                return
                    "Test Video: \(fileName) — Error"
            }

            guard videoFilePlayback
                    .isReady else {

                return
                    "Test Video: \(fileName) — Loading"
            }

            return videoFilePlayback
                .isPlaying
            ? "Test Video: \(fileName) — Playing"
            : "Test Video: \(fileName) — Paused"
        }

        if captureDevices
            .cameraPermissionDenied {

            return
                "Source: Camera access denied"
        }

        guard let sourceName =
                captureDevices
                    .activeSourceName else {

            return
                "Source: No active connection"
        }

        if captureSession
            .errorMessage != nil {

            return
                "Source: \(sourceName) — Error"
        }

        if captureSession
            .isReceivingVideo {

            return
                "Source: \(sourceName) — Active"
        }

        return
            "Source: \(sourceName) — Connecting"
    }

    private var sourceStatusColor:
        Color {

        if currentVideoError != nil {

            return .red
        }

        if !isUsingVideoFile,
           captureDevices
            .cameraPermissionDenied {

            return .red
        }

        if isCurrentSourceReady {

            return .green
        }

        if hasActiveInputSource {
            return .yellow
        }

        return .secondary
    }

    private var gameAudioStatusText:
        String {

        if isUsingVideoFile {
            guard let fileName =
                    videoFilePlayback
                        .loadedFileName else {

                return
                    "Test-video audio unavailable"
            }

            return
                "Playing audio from \(fileName)"
        }

        if captureDevices
            .audioPermissionDenied {

            return
                "Audio access denied"
        }

        if let audioError =
            captureSession
                .audioErrorMessage {

            return audioError
        }

        guard let sourceName =
                captureDevices
                    .activeAudioSourceName else {

            if captureDevices
                .audioDevices
                .isEmpty {

                return
                    "No audio inputs detected"
            }

            return
                "Select an audio input in Settings"
        }

        if captureSession
            .isGameAudioAvailable {

            return
                "\(sourceName) → \(captureDevices.activeAudioOutputName)"
        }

        return
            "Connecting to \(sourceName)…"
    }

    // MARK: - Main View

    var body: some View {
        ZStack {
            if isVideoFullscreen {
                GameplayPreview(
                    captureSession:
                        captureSession,
                    videoFilePlayback:
                        videoFilePlayback,
                    showsAnalyzerDebug:
                        showsAnalyzerDebug,
                    showsHUDRegions:
                        showsHUDRegions,
                    hasAvailableInputSource:
                        hasAvailableInputSource,
                    sourceStatusText:
                        sourceStatusText,
                    sourceStatusColor:
                        sourceStatusColor,
                    isFullscreen:
                        true,
                    isGameMuted:
                        gameMuted,
                    gameVolume:
                        $gameVolume,
                    animator:
                        noConnectionAnimator,
                    onOpenVideoFile:
                        openVideoFile,
                    onUseLiveCapture:
                        useLiveCapture,
                    onMuteToggle:
                        toggleGameMute,
                    onRefresh:
                        refreshAllSources,
                    onFullscreenToggle:
                        exitVideoFullscreen
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )

            } else {
                normalLayout
            }
        }
        .background(Color.black)

        .onAppear {
            captureDevices.start()

            captureSession.setGameAudio(
                volume:
                    gameVolume,
                muted:
                    gameMuted
            )

            videoFilePlayback.setAudio(
                volume:
                    gameVolume,
                muted:
                    gameMuted
            )

            applySelectedAudioOutput()
            if !loadedArgumentVideo {
                loadedArgumentVideo = true
                let args = CommandLine.arguments
                if let index = args.firstIndex(of: "--guidance-profile"), index + 1 < args.count,
                   ["motorfest-standard-v1", "reference-video2-v1"].contains(args[index + 1]) {
                    guidanceHUDProfile = args[index + 1]
                }
                if let index = args.firstIndex(of: "--guidance-speed-unit"), index + 1 < args.count,
                   ["km/h", "mph", "unknown"].contains(args[index + 1]) {
                    guidanceSpeedUnit = args[index + 1]
                }
                if let index = args.firstIndex(of: "--test-video"), index + 1 < args.count {
                    captureSession.pauseLiveSourcesForTestPlayback()
                    videoFilePlayback.load(url: URL(fileURLWithPath: args[index + 1]))
                }
            }
        }
        .onChange(of: guidanceHUDProfile) { _, _ in captureSession.frameAnalyzer.reset() }
        .onChange(of: guidanceSpeedUnit) { _, _ in captureSession.frameAnalyzer.reset() }
        .onReceive(videoFilePlayback.$isReady) { ready in
            let args = CommandLine.arguments
            guard ready, !loadedArgumentStart, let index = args.firstIndex(of: "--test-start"),
                  index + 1 < args.count, let time = Double(args[index + 1]), time.isFinite, time >= 0 else { return }
            loadedArgumentStart = true
            videoFilePlayback.seek(to: time)
        }

        .onReceive(
            captureDevices
                .$activeDeviceID
                .removeDuplicates()
        ) { deviceID in
            guard !isUsingVideoFile else {
                return
            }

            captureSession.configureVideo(
                device:
                    captureDevices.device(
                        withID:
                            deviceID
                    )
            )
        }

        .onReceive(
            captureDevices
                .$activeAudioDeviceID
                .removeDuplicates()
        ) { deviceID in
            guard !isUsingVideoFile else {
                return
            }

            captureSession.configureAudio(
                device:
                    captureDevices
                        .audioDevice(
                            withID:
                                deviceID
                        )
            )
        }

        .onReceive(
            captureDevices
                .$selectedAudioOutputDeviceUID
                .removeDuplicates()
        ) { outputDeviceUID in
            guard !isUsingVideoFile else {
                return
            }

            captureSession
                .setAudioOutputDevice(
                    uniqueID:
                        outputDeviceUID
                            .isEmpty
                        ? nil
                        : outputDeviceUID
                )
        }

        .onChange(
            of: gameVolume
        ) { _, newVolume in
            captureSession.setGameAudio(
                volume:
                    newVolume,
                muted:
                    gameMuted
            )

            videoFilePlayback.setAudio(
                volume:
                    newVolume,
                muted:
                    gameMuted
            )
        }

        .onChange(
            of: gameMuted
        ) { _, newMutedValue in
            captureSession.setGameAudio(
                volume:
                    gameVolume,
                muted:
                    newMutedValue
            )

            videoFilePlayback.setAudio(
                volume:
                    gameVolume,
                muted:
                    newMutedValue
            )
        }

        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        NSWindow
                        .willEnterFullScreenNotification
                )
        ) { _ in
            noConnectionAnimator.pause()
        }

        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        NSWindow
                        .didEnterFullScreenNotification
                )
        ) { _ in
            noConnectionAnimator.resume()
        }

        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        NSWindow
                        .willExitFullScreenNotification
                )
        ) { _ in
            noConnectionAnimator.pause()
        }

        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        NSWindow
                        .didExitFullScreenNotification
                )
        ) { _ in
            isVideoFullscreen =
                false

            videoFullscreenOwnsNativeFullscreen =
                false

            DispatchQueue.main.async {
                noConnectionAnimator.resume()
            }
        }
    }

    // MARK: - Windowed Layout

    private var normalLayout:
        some View {

        HStack(spacing: 0) {
            GameplayPreview(
                captureSession:
                    captureSession,
                videoFilePlayback:
                    videoFilePlayback,
                showsAnalyzerDebug:
                    showsAnalyzerDebug,
                showsHUDRegions:
                    showsHUDRegions,
                hasAvailableInputSource:
                    hasAvailableInputSource,
                sourceStatusText:
                    sourceStatusText,
                sourceStatusColor:
                    sourceStatusColor,
                isFullscreen:
                    false,
                isGameMuted:
                    gameMuted,
                gameVolume:
                    $gameVolume,
                animator:
                    noConnectionAnimator,
                onOpenVideoFile:
                    openVideoFile,
                onUseLiveCapture:
                    useLiveCapture,
                onMuteToggle:
                    toggleGameMute,
                onRefresh:
                    refreshAllSources,
                onFullscreenToggle:
                    enterVideoFullscreen
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .layoutPriority(1)

            if showsSidebar {
                Divider()

                ScrollView(
                    .vertical,
                    showsIndicators:
                        true
                ) {
                    AudioMixerView(
                        gameVolume:
                            $gameVolume,
                        trainerVolume:
                            $trainerVolume,
                        gameMuted:
                            $gameMuted,
                        trainerMuted:
                            $trainerMuted,
                        gameAudioAvailable:
                            isUsingVideoFile
                            ? videoFilePlayback
                                .isReady
                            : captureSession
                                .isGameAudioAvailable,
                        gameAudioStatus:
                            gameAudioStatusText,
                        analyzer:
                            captureSession
                                .frameAnalyzer,
                        datasetRecorder:
                            captureSession
                                .minimapDatasetRecorder
                    )
                }
                .frame(
                    width: 320
                )
                .frame(
                    maxHeight: .infinity,
                    alignment: .top
                )
                .background(
                    Color(
                        nsColor:
                            .controlBackgroundColor
                    )
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(
            Color(
                nsColor:
                    .windowBackgroundColor
            )
        )
        .navigationTitle("Racing Trainer")
        .navigationSubtitle(sourceStatusText)
        .toolbar {
            windowToolbar
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var windowToolbar:
        some ToolbarContent {

        ToolbarItemGroup {
            sourceMenu

            Menu {
                Text("Category 1 · Turns & Timing")
                Text("Turn timing and wheel angles are experimental")
                Picker("HUD Layout", selection: $guidanceHUDProfile) {
                    Text("Standard Motorfest HUD").tag("motorfest-standard-v1")
                    Text("Reference Recording HUD").tag("reference-video2-v1")
                }
                Picker("Speed Unit", selection: $guidanceSpeedUnit) {
                    Text("km/h").tag("km/h")
                    Text("mph").tag("mph")
                    Text("Unconfirmed").tag("unknown")
                }
            } label: {
                Label("Guidance", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .help("Turn timing and wheel targets use the selected input HUD layout and speed unit")

            Menu {
                Button("Model Review") {
                    videoFilePlayback.pause()
                    openWindow(id: "model-review")
                }
                Button("Corner Replay Lab") {
                    videoFilePlayback.pause()
                    openWindow(id: "corner-replay-lab")
                }
            } label: {
                Label("Replay", systemImage: "play.rectangle.on.rectangle")
            }
            .help("Review timestamped model outputs or compare corner recordings")

            Button {
                refreshAllSources()
            } label: {
                Label(
                    isUsingVideoFile
                    ? "Restart Test Video"
                    : "Refresh Sources",
                    systemImage:
                        "arrow.clockwise"
                )
            }
            .help(
                isUsingVideoFile
                ? "Restart Test Video"
                : "Refresh Video and Audio Sources"
            )
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            OverlayViewMenu {
                Label(
                    "View",
                    systemImage:
                        "eye"
                )
                .labelStyle(.titleAndIcon)
            }

            HUDLayoutMenu {
                Label(
                    "Layout",
                    systemImage:
                        "rectangle.3.group"
                )
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button {
                enterVideoFullscreen()
            } label: {
                Label(
                    "Video Full Screen",
                    systemImage:
                        "arrow.up.left.and.arrow.down.right"
                )
            }
            .help("Enter Video Full Screen")

            Toggle(
                isOn:
                    $showsSidebar.animation()
            ) {
                Label(
                    "Sidebar",
                    systemImage:
                        "sidebar.right"
                )
            }
            .help(
                showsSidebar
                ? "Hide Sidebar"
                : "Show Sidebar"
            )

            SettingsLink {
                Label(
                    "Settings",
                    systemImage:
                        "gearshape"
                )
            }
            .help("Open Settings")
        }
    }

    private var sourceMenu:
        some View {

        Menu {
            Button {
                useLiveCapture()
            } label: {
                Label(
                    "Use Live Capture",
                    systemImage:
                        "video"
                )
            }
            .disabled(
                !isUsingVideoFile
            )

            Button {
                openVideoFile()
            } label: {
                Label(
                    "Open Video File…",
                    systemImage:
                        "folder"
                )
            }

            Divider()

            Button {
                showYouTubeTestingInfo()
            } label: {
                Label(
                    "Using a YouTube Video…",
                    systemImage:
                        "play.rectangle"
                )
            }
        } label: {
            Label(
                isUsingVideoFile
                ? "Test Video"
                : "Live Input",
                systemImage:
                    isUsingVideoFile
                    ? "play.rectangle.fill"
                    : "video.fill"
            )
        }
        .help("Choose Live Capture or a Test Video")
    }

    // MARK: - Preview Controls

    private func toggleGameMute() {
        gameMuted.toggle()
    }

    private func openVideoFile() {
        let panel =
            NSOpenPanel()

        panel.title =
            "Open a Motorfest Test Video"

        panel.message =
            "Choose an uncropped 16:9 gameplay recording so the HUD and minimap stay in their normal positions."

        panel.prompt =
            "Open Video"

        panel.canChooseDirectories =
            false

        panel.canChooseFiles =
            true

        panel.allowsMultipleSelection =
            false

        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie
        ]

        guard panel.runModal() ==
                .OK,
              let url =
                panel.url else {
            return
        }

        captureSession
            .pauseLiveSourcesForTestPlayback()

        videoFilePlayback.load(
            url:
                url
        )

        videoFilePlayback.setAudio(
            volume:
                gameVolume,
            muted:
                gameMuted
        )
    }

    private func useLiveCapture() {
        guard isUsingVideoFile else {
            return
        }

        videoFilePlayback.unload()

        let outputUID =
            captureDevices
                .selectedAudioOutputDeviceUID

        captureSession.refreshSources(
            videoDevice:
                captureDevices
                    .activeDevice,
            audioDevice:
                captureDevices
                    .activeAudioDevice,
            audioOutputUniqueID:
                outputUID.isEmpty
                ? nil
                : outputUID
        )
    }

    private func showYouTubeTestingInfo() {
        let alert =
            NSAlert()

        alert.alertStyle =
            .informational

        alert.messageText =
            "Use a local video for analyzer testing"

        alert.informativeText =
            "A YouTube watch link plays inside YouTube's web player, but it does not give Racing Trainer the raw video frames required by the minimap analyzer. Use a video you own, make a permitted clean full-screen 16:9 recording and open it here, or send the full-screen browser video through OBS Virtual Camera and use Live Capture."

        alert.addButton(
            withTitle:
                "Choose Video File"
        )

        alert.addButton(
            withTitle:
                "Cancel"
        )

        if alert.runModal() ==
            .alertFirstButtonReturn {

            openVideoFile()
        }
    }

    private func refreshAllSources() {
        if isUsingVideoFile {
            videoFilePlayback.restart()
            return
        }

        captureDevices
            .refreshDevicesWithRetry()

        let outputUID =
            captureDevices
                .selectedAudioOutputDeviceUID

        captureSession.refreshSources(
            videoDevice:
                captureDevices
                    .activeDevice,
            audioDevice:
                captureDevices
                    .activeAudioDevice,
            audioOutputUniqueID:
                outputUID.isEmpty
                ? nil
                : outputUID
        )
    }

    private func applySelectedAudioOutput() {
        let outputUID =
            captureDevices
                .selectedAudioOutputDeviceUID

        captureSession
            .setAudioOutputDevice(
                uniqueID:
                    outputUID.isEmpty
                    ? nil
                    : outputUID
            )
    }

    // MARK: - Video Fullscreen

    private func enterVideoFullscreen() {
        noConnectionAnimator.pause()

        let window =
            NSApp.keyWindow ??
            NSApp.mainWindow

        let windowIsAlreadyFullscreen =
            window?
                .styleMask
                .contains(
                    .fullScreen
                ) ??
            false

        isVideoFullscreen =
            true

        if windowIsAlreadyFullscreen {
            videoFullscreenOwnsNativeFullscreen =
                false

            DispatchQueue.main.async {
                noConnectionAnimator.resume()
            }

        } else {
            videoFullscreenOwnsNativeFullscreen =
                true

            DispatchQueue.main.async {
                window?
                    .toggleFullScreen(
                        nil
                    )
            }
        }
    }

    private func exitVideoFullscreen() {
        noConnectionAnimator.pause()

        let window =
            NSApp.keyWindow ??
            NSApp.mainWindow

        let windowIsCurrentlyFullscreen =
            window?
                .styleMask
                .contains(
                    .fullScreen
                ) ??
            false

        let shouldExitNativeFullscreen =
            videoFullscreenOwnsNativeFullscreen &&
            windowIsCurrentlyFullscreen

        isVideoFullscreen =
            false

        videoFullscreenOwnsNativeFullscreen =
            false

        if shouldExitNativeFullscreen {
            DispatchQueue.main.async {
                window?
                    .toggleFullScreen(
                        nil
                    )
            }

        } else {
            DispatchQueue.main.async {
                noConnectionAnimator.resume()
            }
        }
    }
}

// MARK: - Gameplay Preview

struct GameplayPreview: View {
    @ObservedObject var captureSession:
        CaptureSessionManager

    @ObservedObject var videoFilePlayback:
        VideoFilePlaybackController

    let showsAnalyzerDebug:
        Bool

    let showsHUDRegions:
        Bool

    let hasAvailableInputSource:
        Bool

    let sourceStatusText:
        String

    let sourceStatusColor:
        Color

    let isFullscreen:
        Bool

    let isGameMuted:
        Bool

    @Binding var gameVolume:
        Double

    let animator:
        NoConnectionAnimator

    let onOpenVideoFile:
        () -> Void

    let onUseLiveCapture:
        () -> Void

    let onMuteToggle:
        () -> Void

    let onRefresh:
        () -> Void

    let onFullscreenToggle:
        () -> Void

    @AppStorage(VideoPlacement.storageKey)
    private var videoPlacement =
        VideoPlacement.center

    /// Aspect ratio of the incoming feed; 16:9 until a frame arrives.
    private var videoAspectRatio:
        CGFloat {

        frameAnalyzer.frameWidth > 0 &&
        frameAnalyzer.frameHeight > 0
        ? CGFloat(frameAnalyzer.frameWidth) /
          CGFloat(frameAnalyzer.frameHeight)
        : 16.0 / 9.0
    }

    /// The fitted video's frame inside the preview, matching the
    /// Video Position setting.
    private func videoRect(
        in size: CGSize
    ) -> CGRect {

        var rect =
            AVMakeRect(
                aspectRatio:
                    CGSize(
                        width: videoAspectRatio,
                        height: 1
                    ),
                insideRect:
                    CGRect(
                        origin: .zero,
                        size: size
                    )
            )

        switch videoPlacement {
        case .top:
            rect.origin.y = 0
        case .bottom:
            rect.origin.y =
                size.height - rect.height
        case .center:
            break
        }

        return rect
    }

    // MARK: Auto-hiding controls

    /// Seconds without pointer movement before the controls fade out.
    private static let controlsHideDelay:
        Duration = .seconds(2.5)

    @State private var controlsVisible =
        true

    @State private var isPointerOverControls =
        false

    @State private var hideControlsTask:
        Task<Void, Never>?

    private var isUsingVideoFile:
        Bool {

        videoFilePlayback
            .hasLoadedVideo
    }

    /// Paused video keeps its controls up so it can be resumed.
    private var keepsControlsVisible:
        Bool {

        isPointerOverControls ||
        (isUsingVideoFile &&
         !videoFilePlayback.isPlaying)
    }

    private func revealControls() {
        if !controlsVisible {
            withAnimation(
                .easeOut(duration: 0.2)
            ) {
                controlsVisible = true
            }
        }

        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()

        hideControlsTask = Task {
            try? await Task.sleep(
                for: Self.controlsHideDelay
            )

            guard !Task.isCancelled,
                  !keepsControlsVisible else {
                return
            }

            withAnimation(
                .easeIn(duration: 0.35)
            ) {
                controlsVisible = false
            }

            if isFullscreen {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private func trackControlsHover(
        _ isHovering: Bool
    ) {
        isPointerOverControls = isHovering

        if !isHovering {
            scheduleControlsHide()
        }
    }

    private var isReceivingVideo:
        Bool {

        isUsingVideoFile
        ? videoFilePlayback
            .isReady
        : captureSession
            .isReceivingVideo
    }

    private var errorMessage:
        String? {

        isUsingVideoFile
        ? videoFilePlayback
            .errorMessage
        : captureSession
            .errorMessage
    }

    private var frameAnalyzer:
        FrameAnalyzer {

        captureSession
            .frameAnalyzer
    }

    private var minimapDatasetRecorder:
        MinimapDatasetRecorder {

        captureSession
            .minimapDatasetRecorder
    }

    var body: some View {
        Group {
            if isFullscreen {
                previewContent
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

            } else {
                previewContent
                    .aspectRatio(
                        16.0 / 9.0,
                        contentMode:
                            .fit
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment:
                            videoPlacement
                                .alignment
                    )
            }
        }
        .background(Color.black)
        .clipped()
    }

    private var previewContent:
        some View {

        GeometryReader { geometry in
            let availablePanelHeight =
                max(
                    180,
                    geometry.size.height - 32
                )

            ZStack(
                alignment:
                    .bottomTrailing
            ) {
                Color.black

                // Video and the overlays drawn in video coordinates share one
                // container, pinned per the Video Position setting.
                ZStack {
                    if isUsingVideoFile {
                        VideoFilePreview(
                            player:
                                videoFilePlayback
                                    .player
                        )
                    } else {
                        CaptureVideoPreview(
                            session:
                                captureSession
                                    .session
                        )
                    }

                    if showsAnalyzerDebug,
                       isReceivingVideo {

                        MinimapRouteMaskOverlay(
                            analyzer:
                                frameAnalyzer,
                            normalizedRect:
                                MotorfestHUDLayout
                                    .minimapAnalysisRect
                        )
                        .allowsHitTesting(
                            false
                        )
                    }

                    if showsHUDRegions,
                       isReceivingVideo {

                        HUDRegionOverlay(
                            frameWidth:
                                frameAnalyzer.frameWidth,
                            frameHeight:
                                frameAnalyzer.frameHeight,
                            regions:
                                MotorfestHUDLayout
                                    .debugRegions
                        )
                        .allowsHitTesting(false)
                    }
                }
                .aspectRatio(
                    videoAspectRatio,
                    contentMode:
                        .fit
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment:
                        videoPlacement
                            .alignment
                )

                if let errorMessage {
                    CaptureErrorView(
                        message:
                            errorMessage
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )

                } else if
                    !hasAvailableInputSource {

                    BouncingNoConnectionView(
                        animator:
                            animator
                    )

                } else if
                    !isReceivingVideo {

                    ConnectingSourceView()
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .center
                        )
                }

                if showsAnalyzerDebug {
                    if isFullscreen {
                        DraggableFullscreenPanel(
                            containerSize:
                                geometry.size,
                            initialAlignment:
                                .topLeading
                        ) {
                            FrameDebugView(
                                analyzer:
                                    frameAnalyzer,
                                maximumHeight:
                                    min(
                                        620,
                                        availablePanelHeight
                                    ),
                                allowsDragging:
                                    true
                            )
                        }
                        .zIndex(20)

                        DraggableFullscreenPanel(
                            containerSize:
                                geometry.size,
                            initialAlignment:
                                .topTrailing
                        ) {
                            DatasetMetadataCounterView(
                                store:
                                    minimapDatasetRecorder
                                        .routeMaskDatasetStore,
                                isOverlay:
                                    true
                            )
                        }
                        .zIndex(20)

                    }
                }

                if isReceivingVideo {

                    TrainerCoachHUD(
                        analyzer:
                            frameAnalyzer,
                        containerSize:
                            geometry.size,
                        videoRect:
                            videoRect(
                                in:
                                    geometry.size
                            )
                    )
                    .zIndex(10)
                }

                // In the window, route status lives in the sidebar's
                // Tools & Diagnostics section; only warnings stay on video.
                let showsRouteBadge =
                    isFullscreen && showsAnalyzerDebug

                let formatWarning =
                    isUsingVideoFile
                    ? videoFilePlayback
                        .formatWarning
                    : nil

                if isReceivingVideo,
                   showsRouteBadge || formatWarning != nil {

                    VStack(spacing: 8) {
                        if showsRouteBadge {
                            RouteDetectionStatusBadge(
                                analyzer:
                                    frameAnalyzer
                            )
                        }

                        if let formatWarning {

                            VideoFormatWarningView(
                                message:
                                    formatWarning
                            )
                        }
                    }
                    .frame(
                        maxWidth:
                            min(
                                440,
                                max(
                                    240,
                                    geometry.size.width - 32
                                )
                            )
                    )
                    .padding(
                        .top,
                        TrainerCoachHUD
                            .bannerBottom(
                                for:
                                    geometry.size
                            ) + 10
                    )
                    .padding(
                        .horizontal,
                        16
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .zIndex(10)
                }

                if isUsingVideoFile,
                   videoFilePlayback
                    .isReady {

                    VideoFilePlaybackControls(
                        playback:
                            videoFilePlayback
                    )
                    .onHover(perform: trackControlsHover)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .padding(
                        .bottom,
                        68
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
                    .zIndex(30)
                }

                if isFullscreen {
                    sourceStatusOverlay
                        .padding(16)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomLeading
                        )
                        .zIndex(30)
                }

                // The window's toolbar carries these controls; full screen
                // has no toolbar, so they float over the video there.
                if isFullscreen {
                    previewControlButtons
                        .onHover(perform: trackControlsHover)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .padding(
                            .trailing,
                            18
                        )
                        .padding(
                            .bottom,
                            18
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                        .zIndex(30)
                }
            }
            .frame(
                width:
                    geometry.size.width,
                height:
                    geometry.size.height
            )
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    revealControls()
                case .ended:
                    scheduleControlsHide()
                }
            }
            .onChange(
                of: videoFilePlayback.isPlaying
            ) {
                revealControls()
            }
            .onAppear {
                scheduleControlsHide()
            }
            .onDisappear {
                hideControlsTask?.cancel()
            }
        }
    }

    private var sourceStatusOverlay:
        some View {

        HStack(spacing: 7) {
            Circle()
                .fill(
                    sourceStatusColor
                )
                .frame(
                    width: 8,
                    height: 8
                )

            Text(sourceStatusText)
                .font(
                    .system(
                        size: 11,
                        weight: .medium
                    )
                )
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(
            .horizontal,
            10
        )
        .padding(
            .vertical,
            7
        )
        .background(
            Color.black.opacity(0.62),
            in:
                RoundedRectangle(
                    cornerRadius: 8
                )
        )
        .allowsHitTesting(false)
    }

    private var previewControlButtons:
        some View {

        HStack(spacing: 8) {
            Menu {
                Button {
                    onUseLiveCapture()
                } label: {
                    Label(
                        "Use Live Capture",
                        systemImage:
                            "video"
                    )
                }
                .disabled(
                    !isUsingVideoFile
                )

                Button {
                    onOpenVideoFile()
                } label: {
                    Label(
                        "Open Video File…",
                        systemImage:
                            "folder"
                    )
                }
            } label: {
                Image(
                    systemName:
                        isUsingVideoFile
                        ? "play.rectangle.fill"
                        : "video.fill"
                )
                .font(
                    .system(
                        size: 15,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .menuStyle(.borderlessButton)
            .help(
                "Choose Live Capture or a Test Video"
            )
            .accessibilityLabel(
                "Choose Live Capture or a Test Video"
            )

            HUDLayoutMenu {
                Image(
                    systemName:
                        "rectangle.3.group"
                )
                .font(
                    .system(
                        size: 15,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(
                "Layout"
            )

            HoverVolumeButton(
                volume:
                    $gameVolume,
                isMuted:
                    isGameMuted,
                onMuteToggle:
                    onMuteToggle,
                onHoverChange:
                    trackControlsHover
            )

            Button {
                onRefresh()
            } label: {
                Image(
                    systemName:
                        "arrow.clockwise"
                )
                .font(
                    .system(
                        size: 15,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.bordered)
            .help(
                isUsingVideoFile
                ? "Restart Test Video"
                : "Refresh Video and Audio Sources"
            )
            .accessibilityLabel(
                isUsingVideoFile
                ? "Restart Test Video"
                : "Refresh Video and Audio Sources"
            )

            OverlayViewMenu {
                Label(
                    "View",
                    systemImage:
                        "eye"
                )
                .labelStyle(.titleAndIcon)
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )
                .frame(
                    height: 28
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                onFullscreenToggle()
            } label: {
                Image(
                    systemName:
                        isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(
                    .system(
                        size: 16,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(
                .borderedProminent
            )
            .help(
                isFullscreen
                ? "Exit Video Full Screen"
                : "Enter Video Full Screen"
            )
            .accessibilityLabel(
                isFullscreen
                ? "Exit Video Full Screen"
                : "Enter Video Full Screen"
            )
        }
        .fixedSize()
    }
}

// MARK: - Draggable Fullscreen Panels

private enum FullscreenPanelAnchor {
    case topLeading
    case topTrailing
}

private struct DraggablePanelSizePreferenceKey:
    PreferenceKey {

    static var defaultValue:
        CGSize = .zero

    static func reduce(
        value:
            inout CGSize,
        nextValue:
            () -> CGSize
    ) {
        let nextSize =
            nextValue()

        if nextSize != .zero {
            value = nextSize
        }
    }
}

private struct DraggableFullscreenPanel<Content: View>:
    View {

    let containerSize:
        CGSize

    let initialAlignment:
        FullscreenPanelAnchor

    let margin:
        CGFloat

    private let content:
        Content

    @State private var panelSize:
        CGSize = .zero

    @State private var restingPosition:
        CGPoint?

    @GestureState private var dragTranslation:
        CGSize = .zero

    init(
        containerSize:
            CGSize,
        initialAlignment:
            FullscreenPanelAnchor,
        margin:
            CGFloat = 16,
        @ViewBuilder content:
            () -> Content
    ) {
        self.containerSize =
            containerSize

        self.initialAlignment =
            initialAlignment

        self.margin =
            margin

        self.content =
            content()
    }

    private var displayedPosition:
        CGPoint {

        let startingPosition =
            restingPosition ??
            initialPosition(
                inside:
                    containerSize,
                panelSize:
                    panelSize
            )

        return clampedPosition(
            CGPoint(
                x:
                    startingPosition.x +
                    dragTranslation.width,
                y:
                    startingPosition.y +
                    dragTranslation.height
            ),
            inside:
                containerSize,
            panelSize:
                panelSize
        )
    }

    var body:
        some View {

        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key:
                                DraggablePanelSizePreferenceKey.self,
                            value:
                                geometry.size
                        )
                }
            }
            .overlay(
                alignment:
                    .top
            ) {
                Capsule()
                    .fill(
                        Color.white.opacity(0.38)
                    )
                    .frame(
                        width: 28,
                        height: 3
                    )
                    .padding(
                        .top,
                        5
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .position(displayedPosition)
            .simultaneousGesture(
                DragGesture(
                    minimumDistance:
                        4
                )
                .updating(
                    $dragTranslation
                ) { value, state, _ in
                    state =
                        value.translation
                }
                .onEnded { value in
                    let startingPosition =
                        restingPosition ??
                        initialPosition(
                            inside:
                                containerSize,
                            panelSize:
                                panelSize
                        )

                    restingPosition =
                        clampedPosition(
                            CGPoint(
                                x:
                                    startingPosition.x +
                                    value.translation.width,
                                y:
                                    startingPosition.y +
                                    value.translation.height
                            ),
                            inside:
                                containerSize,
                            panelSize:
                                panelSize
                        )
                }
            )
            .onPreferenceChange(
                DraggablePanelSizePreferenceKey.self
            ) { newPanelSize in
                panelSize =
                    newPanelSize

                if let restingPosition {
                    self.restingPosition =
                        clampedPosition(
                            restingPosition,
                            inside:
                                containerSize,
                            panelSize:
                                newPanelSize
                        )
                }
            }
            .onChange(
                of:
                    containerSize
            ) { _, newContainerSize in
                if let restingPosition {
                    self.restingPosition =
                        clampedPosition(
                            restingPosition,
                            inside:
                                newContainerSize,
                            panelSize:
                                panelSize
                        )
                }
            }
            .help(
                "Drag to reposition this panel"
            )
    }

    private func initialPosition(
        inside containerSize:
            CGSize,
        panelSize:
            CGSize
    ) -> CGPoint {

        let proposedX:
            CGFloat

        switch initialAlignment {
        case .topLeading:
            proposedX =
                margin +
                panelSize.width / 2

        case .topTrailing:
            proposedX =
                containerSize.width -
                margin -
                panelSize.width / 2
        }

        return clampedPosition(
            CGPoint(
                x:
                    proposedX,
                y:
                    margin +
                    panelSize.height / 2
            ),
            inside:
                containerSize,
            panelSize:
                panelSize
        )
    }

    private func clampedPosition(
        _ proposedPosition:
            CGPoint,
        inside containerSize:
            CGSize,
        panelSize:
            CGSize
    ) -> CGPoint {

        let minimumX =
            margin +
            panelSize.width / 2

        let maximumX =
            containerSize.width -
            margin -
            panelSize.width / 2

        let minimumY =
            margin +
            panelSize.height / 2

        let maximumY =
            containerSize.height -
            margin -
            panelSize.height / 2

        let clampedX:
            CGFloat

        if minimumX <= maximumX {
            clampedX =
                min(
                    max(
                        proposedPosition.x,
                        minimumX
                    ),
                    maximumX
                )
        } else {
            clampedX =
                containerSize.width / 2
        }

        let clampedY:
            CGFloat

        if minimumY <= maximumY {
            clampedY =
                min(
                    max(
                        proposedPosition.y,
                        minimumY
                    ),
                    maximumY
                )
        } else {
            clampedY =
                containerSize.height / 2
        }

        return CGPoint(
            x:
                clampedX,
            y:
                clampedY
        )
    }
}

// MARK: - HUD Region Debug Overlay

struct HUDRegionOverlay: View {
    let frameWidth:
        Int

    let frameHeight:
        Int

    let regions:
        [GameplayHUDRegion]

    var body: some View {
        GeometryReader { geometry in
            let frameRect =
                aspectFitRect(
                    sourceSize:
                        sourceFrameSize,
                    inside:
                        geometry.size
                )

            ZStack(
                alignment: .topLeading
            ) {
                ForEach(regions) { region in
                    let displayedRect =
                        displayRect(
                            for:
                                region.normalizedRect,
                            inside:
                                frameRect
                        )

                    RoundedRectangle(
                        cornerRadius: 6
                    )
                    .stroke(
                        regionColor(
                            for:
                                region.kind
                        ),
                        style:
                            StrokeStyle(
                                lineWidth: 2,
                                dash: [8, 5]
                            )
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: 6
                        )
                        .fill(
                            regionColor(
                                for:
                                    region.kind
                            )
                            .opacity(0.08)
                        )
                    )
                    .frame(
                        width:
                            displayedRect.width,
                        height:
                            displayedRect.height
                    )
                    .overlay(
                        regionLabel(
                            region
                        ),
                        alignment:
                            .topLeading
                    )
                    .position(
                        x:
                            displayedRect.midX,
                        y:
                            displayedRect.midY
                    )
                }
            }
            .frame(
                width:
                    geometry.size.width,
                height:
                    geometry.size.height,
                alignment:
                    .topLeading
            )
        }
    }

    private var sourceFrameSize:
        CGSize {

        guard frameWidth > 0,
              frameHeight > 0 else {
            return CGSize(
                width: 16,
                height: 9
            )
        }

        return CGSize(
            width:
                frameWidth,
            height:
                frameHeight
        )
    }

    private func aspectFitRect(
        sourceSize: CGSize,
        inside containerSize: CGSize
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let widthScale =
            containerSize.width /
            sourceSize.width

        let heightScale =
            containerSize.height /
            sourceSize.height

        let scale =
            min(
                widthScale,
                heightScale
            )

        let fittedSize =
            CGSize(
                width:
                    sourceSize.width *
                    scale,
                height:
                    sourceSize.height *
                    scale
            )

        return CGRect(
            x:
                (containerSize.width -
                 fittedSize.width) /
                2,
            y:
                (containerSize.height -
                 fittedSize.height) /
                2,
            width:
                fittedSize.width,
            height:
                fittedSize.height
        )
    }

    private func displayRect(
        for normalizedRect: CGRect,
        inside frameRect: CGRect
    ) -> CGRect {
        CGRect(
            x:
                frameRect.minX +
                normalizedRect.minX *
                frameRect.width,
            y:
                frameRect.minY +
                normalizedRect.minY *
                frameRect.height,
            width:
                normalizedRect.width *
                frameRect.width,
            height:
                normalizedRect.height *
                frameRect.height
        )
    }

    private func regionLabel(
        _ region: GameplayHUDRegion
    ) -> some View {
        Text(region.name.uppercased())
            .font(
                .system(
                    size: 10,
                    weight: .bold,
                    design: .monospaced
                )
            )
            .foregroundStyle(.black)
            .padding(
                .horizontal,
                6
            )
            .padding(
                .vertical,
                4
            )
            .background(
                regionColor(
                    for:
                        region.kind
                )
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 4
                )
            )
            .padding(4)
    }

    private func regionColor(
        for kind:
            GameplayHUDRegion.Kind
    ) -> Color {
        switch kind {
        case .speedometer:
            return .yellow

        case .speedOCR:
            return .green

        case .minimap:
            return .cyan

        case .checkpoint:
            return .orange
        }
    }
}

// MARK: - Minimap Route Mask Overlay

struct MinimapRouteMaskOverlay:
    View {

    @ObservedObject var analyzer:
        FrameAnalyzer

    let normalizedRect:
        CGRect

    var body:
        some View {

        GeometryReader { geometry in
            let frameRect =
                aspectFitRect(
                    sourceSize:
                        sourceFrameSize,
                    inside:
                        geometry.size
                )

            let displayedRect =
                displayRect(
                    for:
                        normalizedRect,
                    inside:
                        frameRect
                )

            if analyzer.yellowRouteDetected,
               !analyzer
                .coachSnapshot
                .trackingApplied,
               let routeMaskImage =
                analyzer.routeMaskImage {

                Image(
                    decorative:
                        routeMaskImage,
                    scale:
                        1,
                    orientation:
                        .up
                )
                .resizable()
                .interpolation(
                    .medium
                )
                .frame(
                    width:
                        displayedRect.width,
                    height:
                        displayedRect.height
                )
                .position(
                    x:
                        displayedRect.midX,
                    y:
                        displayedRect.midY
                )
                .accessibilityHidden(
                    true
                )
            }

            let coachPath =
                analyzer
                    .coachSnapshot
                    .orderedPath

            if coachPath.count >= 2 {
                Path { path in
                    guard let first =
                            coachPath.first else {
                        return
                    }

                    path.move(
                        to:
                            CGPoint(
                                x:
                                    displayedRect.minX +
                                    first.x *
                                    displayedRect.width,
                                y:
                                    displayedRect.minY +
                                    first.y *
                                    displayedRect.height
                            )
                    )

                    for point in
                        coachPath.dropFirst() {

                        path.addLine(
                            to:
                                CGPoint(
                                    x:
                                        displayedRect.minX +
                                        point.x *
                                        displayedRect.width,
                                    y:
                                        displayedRect.minY +
                                        point.y *
                                        displayedRect.height
                                )
                        )
                    }
                }
                .stroke(
                    Color.green,
                    style:
                        StrokeStyle(
                            lineWidth:
                                max(
                                    2,
                                    displayedRect.width *
                                    0.012
                                ),
                            lineCap:
                                .round,
                            lineJoin:
                                .round
                        )
                )
                .shadow(
                    color:
                        Color.black
                            .opacity(0.75),
                    radius:
                        1
                )

                if let turnStart =
                    analyzer
                        .coachSnapshot
                        .turnStartPoint {

                    Circle()
                        .fill(Color.orange)
                        .overlay(
                            Circle()
                                .stroke(
                                    Color.black,
                                    lineWidth:
                                        1
                                )
                        )
                        .frame(
                            width:
                                9,
                            height:
                                9
                        )
                        .position(
                            x:
                                displayedRect.minX +
                                turnStart.x *
                                displayedRect.width,
                            y:
                                displayedRect.minY +
                                turnStart.y *
                                displayedRect.height
                        )
                }
            }
        }
    }

    private var sourceFrameSize:
        CGSize {

        guard analyzer.frameWidth > 0,
              analyzer.frameHeight > 0 else {

            return CGSize(
                width:
                    16,
                height:
                    9
            )
        }

        return CGSize(
            width:
                analyzer.frameWidth,
            height:
                analyzer.frameHeight
        )
    }

    private func aspectFitRect(
        sourceSize:
            CGSize,
        inside containerSize:
            CGSize
    ) -> CGRect {

        guard sourceSize.width > 0,
              sourceSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {

            return .zero
        }

        let scale =
            min(
                containerSize.width /
                sourceSize.width,
                containerSize.height /
                sourceSize.height
            )

        let fittedSize =
            CGSize(
                width:
                    sourceSize.width *
                    scale,
                height:
                    sourceSize.height *
                    scale
            )

        return CGRect(
            x:
                (
                    containerSize.width -
                    fittedSize.width
                ) /
                2,
            y:
                (
                    containerSize.height -
                    fittedSize.height
                ) /
                2,
            width:
                fittedSize.width,
            height:
                fittedSize.height
        )
    }

    private func displayRect(
        for normalizedRect:
            CGRect,
        inside frameRect:
            CGRect
    ) -> CGRect {

        CGRect(
            x:
                frameRect.minX +
                normalizedRect.minX *
                frameRect.width,
            y:
                frameRect.minY +
                normalizedRect.minY *
                frameRect.height,
            width:
                normalizedRect.width *
                frameRect.width,
            height:
                normalizedRect.height *
                frameRect.height
        )
    }
}

// MARK: - Route Detection Status

struct RouteDetectionStatusBadge:
    View {

    @ObservedObject var analyzer:
        FrameAnalyzer

    private var title:
        String {

        if analyzer
            .minimapAnalyzedFrameCount == 0 {

            return
                "ANALYZING MINIMAP"
        }

        if !analyzer
            .minimapVisible {

            return
                "MINIMAP NOT FOUND"
        }

        if analyzer
            .yellowRouteDetected {

            return String(
                format:
                    "GPS ROUTE DETECTED · %.0f%%",
                analyzer
                    .yellowRouteConfidence *
                100
            )
        }

        return
            "NO GPS ROUTE"
    }

    private var systemImage:
        String {

        if analyzer
            .minimapAnalyzedFrameCount == 0 {

            return
                "waveform.path.ecg"
        }

        if !analyzer
            .minimapVisible {

            return
                "map"
        }

        return analyzer
            .yellowRouteDetected
        ? "point.topleft.down.to.point.bottomright.curvepath.fill"
        : "location.slash.fill"
    }

    private var statusColor:
        Color {

        if analyzer
            .minimapAnalyzedFrameCount == 0 {

            return .blue
        }

        if !analyzer
            .minimapVisible {

            return .gray
        }

        return analyzer
            .yellowRouteDetected
        ? .pink
        : .orange
    }

    var body:
        some View {

        HStack(spacing: 8) {
            Image(
                systemName:
                    systemImage
            )

            Text(title)
                .font(
                    .system(
                        size: 12,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(
            .horizontal,
            12
        )
        .padding(
            .vertical,
            8
        )
        .background(
            statusColor
                .opacity(0.88),
            in:
                Capsule()
        )
        .overlay(
            Capsule()
                .stroke(
                    Color.white
                        .opacity(0.24),
                    lineWidth: 1
                )
        )
        .shadow(
            color:
                Color.black
                    .opacity(0.35),
            radius: 6,
            y: 2
        )
        .allowsHitTesting(false)
    }
}

struct VideoFormatWarningView:
    View {

    let message:
        String

    var body:
        some View {

        Label(
            message,
            systemImage:
                "exclamationmark.triangle.fill"
        )
        .font(
            .system(
                size: 11,
                weight: .semibold
            )
        )
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(
            .horizontal,
            12
        )
        .padding(
            .vertical,
            8
        )
        .background(
            Color.orange
                .opacity(0.88),
            in:
                RoundedRectangle(
                    cornerRadius: 9
                )
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Test Video Controls

struct VideoFilePlaybackControls:
    View {

    @ObservedObject var playback:
        VideoFilePlaybackController

    @State private var scrubberValue =
        0.0

    @State private var isScrubbing =
        false

    private var sliderMaximum:
        Double {

        max(
            playback.duration,
            0.1
        )
    }

    var body:
        some View {

        HStack(spacing: 10) {
            Button {
                playback.skip(
                    by:
                        -10
                )
            } label: {
                Image(
                    systemName:
                        "gobackward.10"
                )
            }
            .buttonStyle(.plain)
            .help("Back 10 Seconds")

            Button {
                playback.togglePlayback()
            } label: {
                Image(
                    systemName:
                        playback.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .frame(
                    width: 18,
                    height: 18
                )
            }
            .buttonStyle(.plain)
            .help(
                playback.isPlaying
                ? "Pause Test Video"
                : "Play Test Video"
            )

            Button {
                playback.skip(
                    by:
                        10
                )
            } label: {
                Image(
                    systemName:
                        "goforward.10"
                )
            }
            .buttonStyle(.plain)
            .help("Forward 10 Seconds")

            Slider(
                value:
                    $scrubberValue,
                in:
                    0...sliderMaximum,
                onEditingChanged: {
                    editing in

                    isScrubbing =
                        editing

                    if !editing {
                        playback.seek(
                            to:
                                scrubberValue
                        )
                    }
                }
            )

            Text(
                "\(formattedTime(playback.currentTime)) / \(formattedTime(playback.duration))"
            )
            .font(
                .system(
                    size: 11,
                    design: .monospaced
                )
            )
            .foregroundStyle(.white)
            .frame(
                width: 94,
                alignment: .trailing
            )

            Button {
                playback.toggleLooping()
            } label: {
                Image(
                    systemName:
                        "repeat"
                )
                .foregroundStyle(
                    playback.loopsPlayback
                    ? Color.accentColor
                    : Color.white.opacity(0.55)
                )
            }
            .buttonStyle(.plain)
            .help(
                playback.loopsPlayback
                ? "Looping On"
                : "Looping Off"
            )
        }
        .foregroundStyle(.white)
        .padding(
            .horizontal,
            14
        )
        .padding(
            .vertical,
            10
        )
        .frame(
            maxWidth: 560
        )
        .background(
            Color.black
                .opacity(0.74),
            in:
                RoundedRectangle(
                    cornerRadius: 12
                )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 12
            )
            .stroke(
                Color.white
                    .opacity(0.16),
                lineWidth: 1
            )
        )
        .onAppear {
            scrubberValue =
                playback.currentTime
        }
        .onChange(
            of:
                playback.currentTime
        ) { _, newTime in
            guard !isScrubbing else {
                return
            }

            scrubberValue =
                min(
                    max(
                        newTime,
                        0
                    ),
                    sliderMaximum
                )
        }
    }

    private func formattedTime(
        _ seconds:
            Double
    ) -> String {
        guard seconds.isFinite,
              seconds >= 0 else {
            return "0:00"
        }

        let totalSeconds =
            Int(seconds.rounded(.down))

        let minutes =
            totalSeconds /
            60

        let remainingSeconds =
            totalSeconds %
            60

        return String(
            format:
                "%d:%02d",
            minutes,
            remainingSeconds
        )
    }
}

// MARK: - Hover Volume

/// Mute button that reveals a vertical volume slider while hovered.
/// Clicking still mutes and unmutes; the slider sets the shared game volume.
struct HoverVolumeButton: View {
    @Binding var volume: Double
    let isMuted: Bool
    let onMuteToggle: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var isButtonHovered = false
    @State private var isSliderHovered = false
    @State private var isDragging = false
    @State private var showsSlider = false
    @State private var hideTask: Task<Void, Never>?

    private static let trackHeight: CGFloat = 110

    private var symbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Button {
            onMuteToggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .help(isMuted ? "Unmute Game Audio" : "Mute Game Audio")
        .accessibilityLabel(isMuted ? "Unmute Game Audio" : "Mute Game Audio")
        .onHover { hovering in
            isButtonHovered = hovering
            updateVisibility()
        }
        .overlay(alignment: .bottom) {
            if showsSlider {
                sliderPanel
                    // Sit above the button, overlapping slightly so the
                    // pointer can move up without leaving both views.
                    .offset(y: -40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var sliderPanel: some View {
        VStack(spacing: 8) {
            Text("\(Int(((isMuted ? 0 : volume) * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            GeometryReader { proxy in
                let height = proxy.size.height
                let level = CGFloat(isMuted ? 0 : volume)
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white)
                        .frame(height: max(height * level, 6))
                }
                .frame(width: 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            // Dragging while muted should be heard.
                            if isMuted { onMuteToggle() }
                            volume = min(max(1 - value.location.y / height, 0), 1)
                        }
                        .onEnded { _ in
                            isDragging = false
                            updateVisibility()
                        }
                )
            }
            .frame(width: 28, height: Self.trackHeight)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onHover { hovering in
            isSliderHovered = hovering
            updateVisibility()
        }
        .accessibilityElement()
        .accessibilityLabel("Game Volume")
        .accessibilityValue(isMuted ? "Muted" : "\(Int((volume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(volume + 0.1, 1)
            case .decrement: volume = max(volume - 0.1, 0)
            @unknown default: break
            }
        }
    }

    private func updateVisibility() {
        let wantsSlider = isButtonHovered || isSliderHovered || isDragging
        onHoverChange(wantsSlider)
        hideTask?.cancel()

        if wantsSlider {
            withAnimation(.easeOut(duration: 0.15)) { showsSlider = true }
        } else {
            // Short grace period for moving between the button and the slider.
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { showsSlider = false }
            }
        }
    }
}

// MARK: - Frame Debug

struct FrameDebugView: View {
    @ObservedObject var analyzer:
        FrameAnalyzer

    let maximumHeight:
        CGFloat

    let allowsDragging:
        Bool

    var isEmbedded:
        Bool = false

    @State private var showsPerformanceDetails =
        false

    @State private var showsMinimapDetails =
        false

    @State private var showsCoachDetails =
        false

    @State private var showsSpeedDetails =
        false

    private static let timeFormatter:
        DateFormatter = {

        let formatter =
            DateFormatter()

        formatter.dateFormat =
            "HH:mm:ss.SSS"

        return formatter
    }()

    private var resolutionText:
        String {

        guard analyzer.frameWidth > 0,
              analyzer.frameHeight > 0 else {
            return "Waiting for frame"
        }

        return
            "\(analyzer.frameWidth) × \(analyzer.frameHeight)"
    }

    private var lastFrameText:
        String {

        guard let lastFrameDate =
                analyzer.lastFrameDate else {
            return "Never"
        }

        return Self.timeFormatter.string(
            from:
                lastFrameDate
        )
    }

    private var detectedSpeedText:
        String {

        guard let detectedSpeed =
                analyzer.detectedSpeed else {
            return "—"
        }

        return String(
            detectedSpeed
        )
    }

    private var rawDetectedSpeedText:
        String {

        guard let rawDetectedSpeed =
                analyzer.rawDetectedSpeed else {
            return "—"
        }

        return String(
            rawDetectedSpeed
        )
    }

    private var coachAgeText:
        String {

        let snapshot =
            analyzer.coachSnapshot

        let frameAge =
            snapshot.sourceFrameUptime > 0
            ? String(
                format: "%.0f ms",
                snapshot.ageMilliseconds(
                    at:
                        ProcessInfo
                            .processInfo
                            .systemUptime
                )
            )
            : "—"

        let speedAge =
            snapshot.speedAgeMilliseconds
                .map {
                    String(
                        format: "%.0f ms",
                        $0
                    )
                } ?? "—"

        return "\(frameAge) / \(speedAge)"
    }

    private var preferredPanelHeight:
        CGFloat {

        var height:
            CGFloat = 214

        if showsPerformanceDetails {
            height += 176
        }

        if showsMinimapDetails {
            height += 300
        }

        if showsCoachDetails {
            height += 240
        }

        if showsSpeedDetails {
            height += 154
        }

        return min(
            max(
                maximumHeight,
                180
            ),
            height
        )
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            HStack(spacing: 8) {
                Text("FRAME ANALYZER")
                    .font(
                        .system(
                            size: 12,
                            weight: .bold,
                            design: .monospaced
                        )
                    )

                Spacer()

                if allowsDragging {
                    Image(
                        systemName:
                            "arrow.up.and.down.and.arrow.left.and.right"
                    )
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        Color.white.opacity(0.62)
                    )
                    .help(
                        "Drag this panel to move it"
                    )
                }
            }
            .foregroundStyle(.white)

            Divider()
                .overlay(
                    Color.white.opacity(0.25)
                )

            ScrollView(
                .vertical,
                showsIndicators:
                    true
            ) {
                VStack(spacing: 7) {
                    debugSection(
                        title:
                            "PERFORMANCE",
                        systemImage:
                            "gauge.with.dots.needle.67percent",
                        isExpanded:
                            $showsPerformanceDetails
                    ) {
                        debugRow(
                            title: "Resolution",
                            value: resolutionText
                        )

                        debugRow(
                            title: "Frame Count",
                            value:
                                "\(analyzer.capturedFrameCount)"
                        )

                        debugRow(
                            title: "Speed Frames",
                            value:
                                "\(analyzer.speedAnalyzedFrameCount)"
                        )

                        debugRow(
                            title: "Speed FPS",
                            value:
                                String(
                                    format:
                                        "%.2f / %.1f",
                                    analyzer.speedAnalysisFPS,
                                    analyzer.targetSpeedAnalysisFPS
                                )
                        )

                        debugRow(
                            title: "Map Frames",
                            value:
                                "\(analyzer.minimapAnalyzedFrameCount)"
                        )

                        debugRow(
                            title: "Map FPS",
                            value:
                                String(
                                    format:
                                        "%.2f / %.1f",
                                    analyzer.minimapAnalysisFPS,
                                    analyzer.targetMinimapAnalysisFPS
                                )
                        )

                        debugRow(
                            title: "Map Time",
                            value:
                                String(
                                    format:
                                        "%.2f ms",
                                    analyzer.minimapAnalysisMilliseconds
                                )
                        )

                        debugRow(
                            title: "Last Frame",
                            value:
                                lastFrameText
                        )
                    }

                    debugSection(
                        title:
                            "MINIMAP / ROUTE",
                        systemImage:
                            "map",
                        isExpanded:
                            $showsMinimapDetails
                    ) {
                        debugRow(
                            title:
                                "Minimap",
                            value:
                                analyzer.minimapVisible
                                ? "VISIBLE"
                                : "HIDDEN"
                        )

                        debugRow(
                            title:
                                "Map Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.minimapConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "Player Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.playerDetectionConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "Rim Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.rimStructureConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "GPS Route",
                            value:
                                analyzer.yellowRouteDetected
                                ? "YES"
                                : "NO"
                        )

                        debugRow(
                            title:
                                "Route Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.yellowRouteConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "Route Source",
                            value:
                                analyzer.minimapRouteSource.rawValue
                        )

                        debugRow(
                            title:
                                "Diagnostic",
                            value:
                                analyzer.minimapDiagnostic.rawValue
                        )

                        debugRow(
                            title:
                                "Player Cyan",
                            value:
                                "\(analyzer.cyanMarkerPixelCount)"
                        )

                        debugRow(
                            title:
                                "Yellow Candidates",
                            value:
                                "\(analyzer.yellowCandidatePixelCount)"
                        )

                        debugRow(
                            title:
                                "Learned Candidates",
                            value:
                                "\(analyzer.learnedCandidatePixelCount)"
                        )

                        debugRow(
                            title:
                                "Short Candidate",
                            value:
                                analyzer.shortRouteCandidateFound
                                ? "YES"
                                : "NO"
                        )

                        debugRow(
                            title:
                                "Short Verify",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.shortRouteVerifierConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "Route Mask",
                            value:
                                "\(analyzer.yellowRoutePixelCount)"
                        )

                        debugRow(
                            title:
                                "Route Parts",
                            value:
                                "\(analyzer.routeComponentCount)"
                        )

                        debugRow(
                            title:
                                "Rejected Parts",
                            value:
                                "\(analyzer.ignoredYellowComponentCount)"
                        )
                    }

                    debugSection(
                        title:
                            "DRIVING COACH",
                        systemImage:
                            "steeringwheel",
                        isExpanded:
                            $showsCoachDetails
                    ) {
                        debugRow(
                            title:
                                "Coach State",
                            value:
                                analyzer
                                    .coachSnapshot
                                    .state
                                    .rawValue
                                    .uppercased()
                        )

                        debugRow(
                            title:
                                "Coach Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer
                                        .coachSnapshot
                                        .overallConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title:
                                "Map / Anchor / Mask",
                            value:
                                confidenceTriplet(
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .minimap,
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .playerAnchor,
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .routeMask
                                )
                        )

                        debugRow(
                            title:
                                "Path / Geom / Stable",
                            value:
                                confidenceTriplet(
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .forwardPath,
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .geometry,
                                    analyzer
                                        .coachSnapshot
                                        .confidence
                                        .temporalStability
                                )
                        )

                        debugRow(
                            title:
                                "Turn",
                            value:
                                "\(analyzer.coachSnapshot.direction.title) / \(analyzer.coachSnapshot.severity.title) / \(analyzer.coachSnapshot.timing.title)"
                        )

                        debugRow(
                            title:
                                "Command",
                            value:
                                analyzer
                                    .coachSnapshot
                                    .action
                                    .title
                        )

                        debugRow(
                            title:
                                "Steering",
                            value:
                                analyzer
                                    .coachSnapshot
                                    .steering
                                    .title
                        )

                        debugRow(
                            title:
                                "Path / Branches",
                            value:
                                "\(analyzer.coachSnapshot.pathPointCount) / \(analyzer.coachSnapshot.branchPointCount)\(analyzer.coachSnapshot.trackingApplied ? " · TRACKED" : "")"
                        )

                        debugRow(
                            title:
                                "Latency",
                            value:
                                String(
                                    format:
                                        "%.0f ms",
                                    analyzer
                                        .coachSnapshot
                                        .processingLatencyMilliseconds
                                )
                        )

                        debugRow(
                            title:
                                "Frame / Speed Age",
                            value:
                                coachAgeText
                        )
                    }

                    debugSection(
                        title:
                            "SPEED OCR",
                        systemImage:
                            "speedometer",
                        isExpanded:
                            $showsSpeedDetails
                    ) {
                        debugRow(
                            title: "Speed",
                            value:
                                detectedSpeedText
                        )

                        debugRow(
                            title: "Raw Speed",
                            value:
                                rawDetectedSpeedText
                        )

                        debugRow(
                            title: "Unit",
                            value:
                                analyzer.detectedSpeedUnit ??
                                "Unknown"
                        )

                        debugRow(
                            title: "OCR Conf.",
                            value:
                                String(
                                    format:
                                        "%.0f%%",
                                    analyzer.speedConfidence *
                                    100
                                )
                        )

                        debugRow(
                            title: "OCR Time",
                            value:
                                String(
                                    format:
                                        "%.0f ms",
                                    analyzer.speedOCRMilliseconds
                                )
                        )

                        debugRow(
                            title: "OCR Text",
                            value:
                                analyzer.rawSpeedOCRText
                                    .isEmpty
                                ? "—"
                                : analyzer.rawSpeedOCRText
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(
            width: isEmbedded ? nil : 300,
            height:
                preferredPanelHeight,
            alignment: .leading
        )
        .frame(
            maxWidth: isEmbedded ? .infinity : nil
        )
        .background(
            Color.black.opacity(0.72),
            in:
                RoundedRectangle(
                    cornerRadius: 10
                )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 10
            )
            .stroke(
                Color.white.opacity(0.18),
                lineWidth: 1
            )
        )
        .shadow(radius: 3)
    }

    @ViewBuilder
    private func debugSection<Content: View>(
        title:
            String,
        systemImage:
            String,
        isExpanded:
            Binding<Bool>,
        @ViewBuilder content:
            @escaping () -> Content
    ) -> some View {

        DisclosureGroup(
            isExpanded:
                isExpanded
        ) {
            VStack(spacing: 7) {
                content()
            }
            .padding(
                .top,
                8
            )
        } label: {
            Label(
                title,
                systemImage:
                    systemImage
            )
            .font(
                .system(
                    size: 10,
                    weight: .bold,
                    design: .monospaced
                )
            )
            .foregroundStyle(.white)
        }
        .tint(.white)
        .padding(
            .horizontal,
            9
        )
        .padding(
            .vertical,
            8
        )
        .background(
            Color.white.opacity(
                isExpanded.wrappedValue
                ? 0.08
                : 0.045
            ),
            in:
                RoundedRectangle(
                    cornerRadius: 7
                )
        )
    }

    private func debugRow(
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(
                    Color.white.opacity(0.68)
                )

            Spacer()

            Text(value)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .font(
            .system(
                size: 11,
                design: .monospaced
            )
        )
        .monospacedDigit()
    }

    private func confidenceTriplet(
        _ first:
            Float,
        _ second:
            Float,
        _ third:
            Float
    ) -> String {

        String(
            format:
                "%.0f / %.0f / %.0f%%",
            first * 100,
            second * 100,
            third * 100
        )
    }
}

// MARK: - Connecting Indicator

struct ConnectingSourceView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text(
                "Connecting to source…"
            )
            .font(
                .system(
                    size: 14,
                    weight: .medium
                )
            )
            .foregroundStyle(
                .secondary
            )
        }
        .padding(
            .horizontal,
            26
        )
        .padding(
            .vertical,
            20
        )
        .background(
            .regularMaterial,
            in:
                RoundedRectangle(
                    cornerRadius: 14
                )
        )
    }
}

// MARK: - Local Video Preview

struct VideoFilePreview:
    NSViewRepresentable {

    let player:
        AVPlayer

    func makeNSView(
        context: Context
    ) -> VideoFilePreviewNSView {
        let view =
            VideoFilePreviewNSView()

        view.playerLayer.player =
            player

        return view
    }

    func updateNSView(
        _ nsView:
            VideoFilePreviewNSView,
        context: Context
    ) {
        if nsView.playerLayer.player !==
            player {

            nsView.playerLayer.player =
                player
        }
    }
}

final class VideoFilePreviewNSView:
    NSView {

    let playerLayer =
        AVPlayerLayer()

    override init(
        frame frameRect:
            NSRect
    ) {
        super.init(
            frame:
                frameRect
        )

        wantsLayer =
            true

        layer =
            playerLayer

        playerLayer.videoGravity =
            .resizeAspect

        playerLayer.backgroundColor =
            NSColor.black.cgColor
    }

    required init?(
        coder: NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    override func layout() {
        super.layout()

        playerLayer.frame =
            bounds
    }
}

// MARK: - Live AVFoundation Preview

struct CaptureVideoPreview:
    NSViewRepresentable {

    let session:
        AVCaptureSession

    func makeNSView(
        context: Context
    ) -> CapturePreviewNSView {
        let view =
            CapturePreviewNSView()

        view.previewLayer.session =
            session

        return view
    }

    func updateNSView(
        _ nsView:
            CapturePreviewNSView,
        context: Context
    ) {
        if nsView.previewLayer.session !==
            session {

            nsView.previewLayer.session =
                session
        }
    }
}

final class CapturePreviewNSView:
    NSView {

    let previewLayer =
        AVCaptureVideoPreviewLayer()

    override init(
        frame frameRect:
            NSRect
    ) {
        super.init(
            frame: frameRect
        )

        wantsLayer =
            true

        layer =
            previewLayer

        previewLayer.videoGravity =
            .resizeAspect

        previewLayer.backgroundColor =
            NSColor.black.cgColor
    }

    required init?(
        coder: NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    override func layout() {
        super.layout()

        previewLayer.frame =
            bounds
    }
}

// MARK: - Capture Error

struct CaptureErrorView: View {
    let message:
        String

    var body: some View {
        VStack(spacing: 12) {
            Image(
                systemName:
                    "exclamationmark.triangle.fill"
            )
            .font(
                .system(size: 34)
            )
            .foregroundStyle(.red)

            Text(
                "Video source unavailable"
            )
            .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
                .multilineTextAlignment(
                    .center
                )
                .frame(
                    maxWidth: 380
                )
        }
        .padding(24)
        .background(
            .regularMaterial,
            in:
                RoundedRectangle(
                    cornerRadius: 14
                )
        )
    }
}

// MARK: - Animation Data

struct NoConnectionAnimationFrame {
    let position:
        CGPoint

    let colorIndex:
        Int
}

// MARK: - Animation Controller

final class NoConnectionAnimator {
    private var position =
        CGPoint.zero

    private var velocity =
        CGVector(
            dx: 135,
            dy: 105
        )

    private var previousTravelSize:
        CGSize?

    private var lastUpdateDate:
        Date?

    private var currentColorIndex =
        0

    private var isPaused =
        false

    func pause() {
        isPaused = true
        lastUpdateDate = nil
    }

    func resume() {
        isPaused = false
        lastUpdateDate = nil
    }

    func frame(
        at date:
            Date,
        containerSize:
            CGSize,
        logoSize:
            CGSize
    ) -> NoConnectionAnimationFrame {
        let travelSize =
            CGSize(
                width:
                    max(
                        containerSize.width -
                        logoSize.width,
                        0
                    ),
                height:
                    max(
                        containerSize.height -
                        logoSize.height,
                        0
                    )
            )

        preserveRelativePosition(
            for: travelSize
        )

        guard !isPaused else {
            lastUpdateDate = date

            return makeFrame(
                logoSize:
                    logoSize
            )
        }

        guard let lastUpdateDate else {
            self.lastUpdateDate =
                date

            return makeFrame(
                logoSize:
                    logoSize
            )
        }

        let elapsedTime =
            date.timeIntervalSince(
                lastUpdateDate
            )

        self.lastUpdateDate =
            date

        let deltaTime =
            CGFloat(
                min(
                    max(
                        elapsedTime,
                        0
                    ),
                    1.0 / 30.0
                )
            )

        position.x +=
            velocity.dx *
            deltaTime

        position.y +=
            velocity.dy *
            deltaTime

        var hitWall =
            false

        if position.x < 0 {
            position.x =
                0

            velocity.dx =
                abs(
                    velocity.dx
                )

            hitWall =
                true

        } else if position.x >
                    travelSize.width {

            position.x =
                travelSize.width

            velocity.dx =
                -abs(
                    velocity.dx
                )

            hitWall =
                true
        }

        if position.y < 0 {
            position.y =
                0

            velocity.dy =
                abs(
                    velocity.dy
                )

            hitWall =
                true

        } else if position.y >
                    travelSize.height {

            position.y =
                travelSize.height

            velocity.dy =
                -abs(
                    velocity.dy
                )

            hitWall =
                true
        }

        if hitWall {
            currentColorIndex +=
                1
        }

        return makeFrame(
            logoSize:
                logoSize
        )
    }

    private func preserveRelativePosition(
        for newTravelSize:
            CGSize
    ) {
        guard let previousTravelSize else {
            self.previousTravelSize =
                newTravelSize

            return
        }

        let widthChanged =
            abs(
                previousTravelSize.width -
                newTravelSize.width
            ) > 0.5

        let heightChanged =
            abs(
                previousTravelSize.height -
                newTravelSize.height
            ) > 0.5

        if widthChanged {
            if previousTravelSize.width >
                0 {

                let progress =
                    position.x /
                    previousTravelSize.width

                position.x =
                    progress *
                    newTravelSize.width
            } else {
                position.x =
                    0
            }
        }

        if heightChanged {
            if previousTravelSize.height >
                0 {

                let progress =
                    position.y /
                    previousTravelSize.height

                position.y =
                    progress *
                    newTravelSize.height
            } else {
                position.y =
                    0
            }
        }

        position.x =
            min(
                max(
                    position.x,
                    0
                ),
                newTravelSize.width
            )

        position.y =
            min(
                max(
                    position.y,
                    0
                ),
                newTravelSize.height
            )

        self.previousTravelSize =
            newTravelSize
    }

    private func makeFrame(
        logoSize:
            CGSize
    ) -> NoConnectionAnimationFrame {
        NoConnectionAnimationFrame(
            position:
                CGPoint(
                    x:
                        position.x +
                        logoSize.width / 2,
                    y:
                        position.y +
                        logoSize.height / 2
                ),
            colorIndex:
                currentColorIndex
        )
    }
}

// MARK: - Bouncing Message

struct BouncingNoConnectionView:
    View {

    let animator:
        NoConnectionAnimator

    private let logoSize =
        CGSize(
            width: 310,
            height: 65
        )

    private let colors:
        [Color] = [
            .cyan,
            .pink,
            .yellow,
            .green,
            .purple,
            .orange,
            .red
        ]

    var body: some View {
        GeometryReader { geometry in
            TimelineView(
                .periodic(
                    from: .now,
                    by: 1.0 / 30.0
                )
            ) { timeline in
                let animationFrame =
                    animator.frame(
                        at:
                            timeline.date,
                        containerSize:
                            geometry.size,
                        logoSize:
                            logoSize
                    )

                Text(
                    "NO ACTIVE CONNECTION"
                )
                .font(
                    .system(
                        size: 20,
                        weight: .black,
                        design: .rounded
                    )
                )
                .tracking(2)
                .lineLimit(1)
                .minimumScaleFactor(
                    0.7
                )
                .foregroundStyle(
                    colors[
                        animationFrame
                            .colorIndex %
                        colors.count
                    ]
                )
                .frame(
                    width:
                        logoSize.width,
                    height:
                        logoSize.height
                )
                .position(
                    animationFrame
                        .position
                )
            }
        }
        .clipped()
    }
}

// MARK: - Minimap Dataset Controls

struct MinimapDatasetControls:
    View {

    @ObservedObject var recorder:
        MinimapDatasetRecorder

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(
                    recorder.isRecording
                    ? Color.red
                    : Color.secondary
                )
                .frame(
                    width: 8,
                    height: 8
                )

            VStack(
                alignment: .leading,
                spacing: 2
            ) {
                Text(
                    recorder.isRecording
                    ? "MINIMAP RECORDING"
                    : "MINIMAP DATASET"
                )
                .font(
                    .system(
                        size: 10,
                        weight: .bold,
                        design: .monospaced
                    )
                )

                Text(
                    "\(recorder.savedImageCount) saved · \(recorder.skippedDuplicateCount) skipped"
                )
                .font(
                    .system(
                        size: 9,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    .secondary
                )
            }

            Button {
                recorder.toggleRecording()
            } label: {
                Image(
                    systemName:
                        recorder.isRecording
                        ? "stop.fill"
                        : "record.circle"
                )
                .frame(
                    width: 20,
                    height: 20
                )
            }
            .buttonStyle(.bordered)
            .help(
                recorder.isRecording
                ? "Stop Minimap Dataset Recording"
                : "Start Minimap Dataset Recording"
            )

            Button {
                recorder.revealDatasetFolder()
            } label: {
                Image(
                    systemName:
                        "folder"
                )
                .frame(
                    width: 20,
                    height: 20
                )
            }
            .buttonStyle(.bordered)
            .help(
                "Open Minimap Dataset Folder"
            )
        }
    }
}

// MARK: - Dataset Metadata Counter

struct DatasetMetadataCounterView:
    View {

    @ObservedObject var store:
        RouteMaskDatasetStore

    let isOverlay:
        Bool

    private var primaryText:
        Color {

        isOverlay
        ? .white
        : .primary
    }

    private var secondaryText:
        Color {

        isOverlay
        ? Color.white.opacity(
            0.66
        )
        : .secondary
    }

    private var dividerColor:
        Color {

        isOverlay
        ? Color.white.opacity(
            0.22
        )
        : Color.secondary.opacity(
            0.25
        )
    }

    var body:
        some View {

        VStack(
            alignment:
                .leading,
            spacing:
                7
        ) {

            HStack(
                spacing:
                    8
            ) {

                Text(
                    "ROUTE MASK DATASET"
                )
                .font(
                    .system(
                        size:
                            12,
                        weight:
                            .bold,
                        design:
                            .monospaced
                    )
                )
                .foregroundStyle(
                    primaryText
                )

                Spacer()

                if !isOverlay {
                    RouteMaskEditorLaunchButton(
                        store:
                            store
                    )
                    .foregroundStyle(
                        primaryText
                    )
                }

                Button {
                    store.refresh()
                } label: {
                    Image(
                        systemName:
                            "arrow.clockwise"
                    )
                    .font(
                        .system(
                            size:
                                10,
                            weight:
                                .semibold
                        )
                    )
                }
                .buttonStyle(
                    .plain
                )
                .foregroundStyle(
                    primaryText
                )
                .help(
                    "Refresh route-mask dataset counts"
                )
            }

            Divider()
                .overlay(
                    dividerColor
                )

            datasetRow(
                title:
                    "Raw images",
                value:
                    store.rawImageCount,
                color:
                    primaryText
            )

            datasetRow(
                title:
                    "Pending review",
                value:
                    store.pendingCount,
                color:
                    .orange
            )

            datasetRow(
                title:
                    "Accepted",
                value:
                    store.acceptedCount,
                color:
                    .green
            )

            datasetRow(
                title:
                    "Corrected",
                value:
                    store.correctedCount,
                color:
                    .cyan
            )

            datasetRow(
                title:
                    "Rejected",
                value:
                    store.rejectedCount,
                color:
                    .red
            )

            Divider()
                .overlay(
                    dividerColor
                )

            HStack(
                spacing:
                    8
            ) {

                Text(
                    "Verified seed goal"
                )
                .foregroundStyle(
                    secondaryText
                )

                Spacer()

                Text(
                    "\(store.trainingReadyCount) / 100"
                )
                .foregroundStyle(
                    primaryText
                )
                .fontWeight(
                    .semibold
                )
            }
            .font(
                .system(
                    size:
                        10,
                    design:
                        .monospaced
                )
            )
            .monospacedDigit()

            ProgressView(
                value:
                    Double(
                        min(
                            store.trainingReadyCount,
                            100
                        )
                    ),
                total:
                    100
            )

            if store.missingPredictionCount > 0 {
                Label(
                    "\(store.missingPredictionCount) older image(s) need predictions",
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(
                    .system(
                        size:
                            9,
                        design:
                            .monospaced
                    )
                )
                .foregroundStyle(
                    .orange
                )
            }

            if let errorMessage =
                    store
                        .lastErrorMessage {

                Text(
                    errorMessage
                )
                .font(
                    .system(
                        size:
                            9,
                        design:
                            .monospaced
                    )
                )
                .foregroundStyle(
                    .red
                )
                .lineLimit(
                    3
                )
            }

            Text(
                isOverlay
                ? "Open the reviewer from the windowed sidebar."
                : "Use the paintbrush button to accept, reject, or correct automatic GPS-route masks."
            )
            .font(
                .system(
                    size:
                        9,
                    design:
                        .monospaced
                )
            )
            .foregroundStyle(
                secondaryText
            )
            .fixedSize(
                horizontal:
                    false,
                vertical:
                    true
            )
            .padding(
                .top,
                2
            )
        }
        .padding(
            isOverlay
            ? 12
            : 0
        )
        .frame(
            width:
                isOverlay
                ? 330
                : nil,
            alignment:
                .leading
        )
        .background(
            isOverlay
            ? Color.black.opacity(
                0.72
            )
            : Color.clear,
            in:
                RoundedRectangle(
                    cornerRadius:
                        10
                )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius:
                    10
            )
            .stroke(
                isOverlay
                ? Color.white.opacity(
                    0.18
                )
                : Color.clear,
                lineWidth:
                    1
            )
        )
    }

    private func datasetRow(
        title:
            String,
        value:
            Int,
        color:
            Color
    ) -> some View {

        HStack(
            spacing:
                8
        ) {

            Text(
                title
            )
            .foregroundStyle(
                secondaryText
            )

            Spacer()

            Text(
                "\(value)"
            )
            .foregroundStyle(
                color
            )
            .fontWeight(
                .semibold
            )
        }
        .font(
            .system(
                size:
                    10,
                design:
                    .monospaced
            )
        )
        .monospacedDigit()
    }
}

// Kept for compatibility with any older metadata already on disk. The new
// route-mask workflow above is the user-facing dataset tool.

struct LegacyDatasetMetadataCounterView:
    View {

    @ObservedObject var store:
        DatasetMetadataStore

    let isOverlay:
        Bool

    private var primaryText:
        Color {

        isOverlay
        ? .white
        : .primary
    }

    private var secondaryText:
        Color {

        isOverlay
        ? Color.white.opacity(
            0.66
        )
        : .secondary
    }

    var body:
        some View {

        VStack(
            alignment: .leading,
            spacing: 6
        ) {

            HStack(
                spacing: 8
            ) {

                Text(
                    "DATASET AUDIT"
                )
                .font(
                    .system(
                        size: 12,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    primaryText
                )

                Spacer()

                if !isOverlay {

                    DatasetLabelerLaunchButton(
                        store:
                            store
                    )
                    .foregroundStyle(
                        primaryText
                    )
                }

                Button {

                    store.refresh()

                } label: {

                    Image(
                        systemName:
                            "arrow.clockwise"
                    )
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )
                }
                .buttonStyle(
                    .plain
                )
                .foregroundStyle(
                    primaryText
                )
                .help(
                    "Refresh Dataset Metadata Counts"
                )
            }

            Divider()
                .overlay(
                    dividerColor
                )

            auditSummaryRow(
                title:
                    "Raw Images",
                value:
                    "\(store.rawImageCount)"
            )

            auditSummaryRow(
                title:
                    "Labeled",
                value:
                    "\(store.labeledImageCount)"
            )

            auditSummaryRow(
                title:
                    "Unlabeled",
                value:
                    "\(store.unlabeledImageCount)"
            )

            Divider()
                .overlay(
                    dividerColor
                )

            sectionLabel(
                "MINIMAP STATE"
            )

            ForEach(
                DatasetMinimapState
                    .allCases
            ) { state in

                targetRow(
                    title:
                        state
                            .displayName,
                    count:
                        store.count(
                            for:
                                state
                        ),
                    target:
                        state
                            .targetCount
                )
            }

            Divider()
                .overlay(
                    dividerColor
                )

            sectionLabel(
                "ROUTE STATE"
            )

            ForEach(
                DatasetRouteState
                    .allCases
            ) { state in

                if let target =
                        state
                            .targetCount {

                    targetRow(
                        title:
                            state
                                .displayName,
                        count:
                            store.count(
                                for:
                                    state
                            ),
                        target:
                            target
                    )

                } else {

                    countOnlyRow(
                        title:
                            state
                                .displayName,
                        count:
                            store.count(
                                for:
                                    state
                            )
                    )
                }
            }

            Divider()
                .overlay(
                    dividerColor
                )

            sectionLabel(
                "ROUTE SHAPE"
            )

            ForEach(
                DatasetRouteCategory
                    .allCases
            ) { category in

                targetRow(
                    title:
                        category
                            .displayName,
                    count:
                        store.count(
                            for:
                                category
                        ),
                    target:
                        category
                            .targetCount
                )
            }

            Divider()
                .overlay(
                    dividerColor
                )

            sectionLabel(
                "CONDITIONS"
            )

            ForEach(
                DatasetConditionCategory
                    .allCases
            ) { category in

                targetRow(
                    title:
                        category
                            .displayName,
                    count:
                        store.count(
                            for:
                                category
                        ),
                    target:
                        category
                            .targetCount
                )
            }

            if let errorMessage =
                    store
                        .lastErrorMessage {

                Divider()
                    .overlay(
                        dividerColor
                    )

                Text(
                    errorMessage
                )
                .font(
                    .system(
                        size: 9,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    .red
                )
                .lineLimit(
                    3
                )
            }

            Text(
                store.labeledImageCount == 0
                ? "Coverage counts begin when complete metadata labels are added."
                : "Targets are minimum coverage goals. Missing / invalid frames are useful negative examples."
            )
            .font(
                .system(
                    size: 9,
                    design: .monospaced
                )
            )
            .foregroundStyle(
                secondaryText
            )
            .fixedSize(
                horizontal: false,
                vertical: true
            )
            .padding(
                .top,
                2
            )
        }
        .padding(
            isOverlay
            ? 12
            : 0
        )
        .frame(
            width:
                isOverlay
                ? 330
                : nil,
            alignment:
                .leading
        )
        .background(
            isOverlay
            ? Color.black.opacity(
                0.72
            )
            : Color.clear,
            in:
                RoundedRectangle(
                    cornerRadius: 10
                )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 10
            )
            .stroke(
                isOverlay
                ? Color.white.opacity(
                    0.18
                )
                : Color.clear,
                lineWidth: 1
            )
        )
        .shadow(
            color:
                isOverlay
                ? Color.black.opacity(
                    0.35
                )
                : Color.clear,
            radius:
                isOverlay
                ? 3
                : 0
        )
    }

    // MARK: Divider

    private var dividerColor:
        Color {

        isOverlay
        ? Color.white.opacity(
            0.22
        )
        : Color.secondary.opacity(
            0.25
        )
    }

    // MARK: Section Label

    private func sectionLabel(
        _ title:
            String
    ) -> some View {

        Text(
            title
        )
        .font(
            .system(
                size: 9,
                weight: .bold,
                design: .monospaced
            )
        )
        .foregroundStyle(
            secondaryText
        )
    }

    // MARK: Summary Row

    private func auditSummaryRow(
        title:
            String,
        value:
            String
    ) -> some View {

        HStack(
            spacing: 8
        ) {

            Text(
                title
            )
            .foregroundStyle(
                secondaryText
            )

            Spacer()

            Text(
                value
            )
            .foregroundStyle(
                primaryText
            )
            .fontWeight(
                .semibold
            )
        }
        .font(
            .system(
                size: 10,
                design: .monospaced
            )
        )
        .monospacedDigit()
    }

    // MARK: Target Row

    private func targetRow(
        title:
            String,
        count:
            Int,
        target:
            Int
    ) -> some View {

        let complete =
            count >=
            target

        let missing =
            max(
                target -
                count,
                0
            )

        return HStack(
            spacing: 8
        ) {

            Text(
                title
            )
            .foregroundStyle(
                secondaryText
            )
            .lineLimit(
                1
            )

            Spacer()

            Text(
                "\(count) / \(target)"
            )
            .foregroundStyle(
                primaryText
            )

            Text(
                complete
                ? "✓"
                : "+\(missing)"
            )
            .foregroundStyle(
                complete
                ? Color.green
                : Color.orange
            )
            .frame(
                width: 28,
                alignment: .trailing
            )
        }
        .font(
            .system(
                size: 10,
                design: .monospaced
            )
        )
        .monospacedDigit()
    }

    // MARK: Count Only Row

    private func countOnlyRow(
        title:
            String,
        count:
            Int
    ) -> some View {

        HStack(
            spacing: 8
        ) {

            Text(
                title
            )
            .foregroundStyle(
                secondaryText
            )
            .lineLimit(
                1
            )

            Spacer()

            Text(
                "\(count)"
            )
            .foregroundStyle(
                primaryText
            )
            .fontWeight(
                .semibold
            )

            Text(
                "—"
            )
            .foregroundStyle(
                secondaryText
            )
            .frame(
                width: 28,
                alignment: .trailing
            )
        }
        .font(
            .system(
                size: 10,
                design: .monospaced
            )
        )
        .monospacedDigit()
    }
}

// MARK: - Audio Mixer

struct AudioMixerView: View {
    @Binding var gameVolume: Double
    @Binding var trainerVolume: Double
    @Binding var gameMuted: Bool
    @Binding var trainerMuted: Bool

    let gameAudioAvailable: Bool
    let gameAudioStatus: String

    @ObservedObject var analyzer: FrameAnalyzer
    @ObservedObject var datasetRecorder: MinimapDatasetRecorder

    @AppStorage("sidebar.showsTools")
    private var showsTools = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {
            Text("Audio")
                .font(.headline)

            AudioChannelRow(
                title: "Game Audio",
                statusText: gameAudioStatus,
                volume: $gameVolume,
                isMuted: $gameMuted,
                controlsEnabled: gameAudioAvailable
            )

            AudioChannelRow(
                title: "Trainer Voice",
                statusText: "Not connected yet",
                volume: $trainerVolume,
                isMuted: $trainerMuted,
                controlsEnabled: false
            )

            Divider()

            // Bench tools aren't needed while driving, so they start collapsed.
            DisclosureGroup(
                isExpanded:
                    $showsTools.animation(.easeOut(duration: 0.2))
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {
                    toolSection("Route Detection") {
                        RouteDetectionStatusBadge(
                            analyzer: analyzer
                        )
                    }

                    toolSection("Frame Analyzer") {
                        FrameDebugView(
                            analyzer: analyzer,
                            maximumHeight: 1_200,
                            allowsDragging: false,
                            isEmbedded: true
                        )
                    }

                    toolSection("Minimap Dataset") {
                        MinimapDatasetControls(
                            recorder: datasetRecorder
                        )
                    }

                    toolSection("Route Mask Dataset") {
                        DatasetMetadataCounterView(
                            store:
                                datasetRecorder
                                    .routeMaskDatasetStore,
                            isOverlay: false
                        )
                    }
                }
                .padding(.top, 12)
            } label: {
                Label(
                    "Tools & Diagnostics",
                    systemImage: "wrench.and.screwdriver"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showsTools.toggle()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
    }

    private func toolSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }
}

// MARK: - Audio Channel

struct AudioChannelRow: View {
    let title:
        String

    let statusText:
        String

    @Binding var volume:
        Double

    @Binding var isMuted:
        Bool

    let controlsEnabled:
        Bool

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Text(title)
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )

            Text(statusText)
                .font(.caption)
                .foregroundStyle(
                    controlsEnabled
                    ? .secondary
                    : .tertiary
                )
                .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    isMuted.toggle()
                } label: {
                    Image(
                        systemName:
                            isMuted
                            ? "speaker.slash.fill"
                            : "speaker.wave.2.fill"
                    )
                    .frame(width: 22)
                }
                .buttonStyle(.plain)
                .disabled(
                    !controlsEnabled
                )
                .help(
                    isMuted
                    ? "Unmute \(title)"
                    : "Mute \(title)"
                )

                Slider(
                    value:
                        $volume,
                    in:
                        0...1
                )
                .disabled(
                    isMuted ||
                    !controlsEnabled
                )

                Text(
                    "\(Int(volume * 100))%"
                )
                .font(
                    .system(
                        size: 12,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    .secondary
                )
                .frame(
                    width: 38,
                    alignment: .trailing
                )
            }
        }
    }
}
