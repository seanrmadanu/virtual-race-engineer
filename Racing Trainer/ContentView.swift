import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
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

    @State private var showsAnalyzerDebug =
        true

    @State private var showsHUDRegions =
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
                                .minimapDatasetRecorder
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
                    onAnalyzerDebugToggle:
                        toggleAnalyzerDebug,
                    onHUDRegionsToggle:
                        toggleHUDRegions,
                    onFullscreenToggle:
                        exitVideoFullscreen
                )
                .ignoresSafeArea()

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
        ) { newVolume in
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
        ) { newMutedValue in
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

        VStack(spacing: 0) {
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
                    onAnalyzerDebugToggle:
                        toggleAnalyzerDebug,
                    onHUDRegionsToggle:
                        toggleHUDRegions,
                    onFullscreenToggle:
                        enterVideoFullscreen
                )

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
                        datasetRecorder:
                            captureSession
                                .minimapDatasetRecorder
                    )
                }
                .frame(
                    width: 300
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
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

            Divider()

            bottomPanel
        }
        .background(
            Color(
                nsColor:
                    .windowBackgroundColor
            )
        )
    }

    // MARK: - Bottom Panel

    private var bottomPanel:
        some View {

        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        sourceStatusColor
                    )
                    .frame(
                        width: 9,
                        height: 9
                    )

                Text(sourceStatusText)
                    .font(
                        .system(
                            size: 13,
                            weight: .medium
                        )
                    )
                    .lineLimit(1)
            }

            Spacer(
                minLength:
                    20
            )

            HStack(spacing: 12) {
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
                .menuStyle(.borderlessButton)
                .fixedSize()

                Toggle(
                    "Analyzer",
                    isOn:
                        $showsAnalyzerDebug
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(
                    "HUD Boxes",
                    isOn:
                        $showsHUDRegions
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                SettingsLink {
                    Label(
                        "Settings",
                        systemImage:
                            "gearshape"
                    )
                }
                .buttonStyle(.bordered)
            }
            .fixedSize(
                horizontal: true,
                vertical: false
            )
        }
        .padding(
            .horizontal,
            18
        )
        .frame(
            maxWidth: .infinity
        )
        .frame(
            height: 88,
            alignment: .center
        )
        .background(
            Color(
                nsColor:
                    .controlBackgroundColor
            )
        )
    }

    // MARK: - Preview Controls

    private func toggleGameMute() {
        gameMuted.toggle()
    }

    private func toggleAnalyzerDebug() {
        showsAnalyzerDebug.toggle()
    }

    private func toggleHUDRegions() {
        showsHUDRegions.toggle()
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

    let onAnalyzerDebugToggle:
        () -> Void

    let onHUDRegionsToggle:
        () -> Void

    let onFullscreenToggle:
        () -> Void

    private var isUsingVideoFile:
        Bool {

        videoFilePlayback
            .hasLoadedVideo
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
                        maxHeight: .infinity
                    )
            }
        }
        .background(Color.black)
        .clipped()
    }

    private var previewContent:
        some View {

        ZStack(
            alignment:
                .bottomTrailing
        ) {
            Color.black

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
                FrameDebugView(
                    analyzer:
                        frameAnalyzer
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .padding(16)

                if isFullscreen {
                    DatasetMetadataCounterView(
                        store:
                            minimapDatasetRecorder
                                .metadataStore,
                        isOverlay:
                            true
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topTrailing
                    )
                    .padding(16)
                }
            }

            if showsAnalyzerDebug,
               isReceivingVideo {

                VStack(spacing: 8) {
                    RouteDetectionStatusBadge(
                        analyzer:
                            frameAnalyzer
                    )

                    if isUsingVideoFile,
                       let formatWarning =
                        videoFilePlayback
                            .formatWarning {

                        VideoFormatWarningView(
                            message:
                                formatWarning
                        )
                    }
                }
                .frame(
                    maxWidth: 440
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .padding(
                    .top,
                    16
                )
                .padding(
                    .horizontal,
                    16
                )
            }

            if isUsingVideoFile,
               videoFilePlayback
                .isReady {

                VideoFilePlaybackControls(
                    playback:
                        videoFilePlayback
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottom
                )
                .padding(
                    .horizontal,
                    110
                )
                .padding(
                    .bottom,
                    68
                )
            }

            if isFullscreen {
                sourceStatusOverlay
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomLeading
                    )
                    .padding(16)
            }

            previewControlButtons
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment:
                        isFullscreen
                        ? .bottomTrailing
                        : .bottomTrailing
                )
                .padding(
                    .trailing,
                    18
                )
                .padding(
                    .bottom,
                    18
                )
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

            Button {
                onMuteToggle()
            } label: {
                Image(
                    systemName:
                        isGameMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill"
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
                isGameMuted
                ? "Unmute Game Audio"
                : "Mute Game Audio"
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

            Button {
                onAnalyzerDebugToggle()
            } label: {
                Image(
                    systemName:
                        showsAnalyzerDebug
                        ? "info.circle.fill"
                        : "info.circle"
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
                showsAnalyzerDebug
                ? "Hide Analyzer Panel"
                : "Show Analyzer Panel"
            )

            Button {
                onHUDRegionsToggle()
            } label: {
                Image(
                    systemName:
                        "viewfinder"
                )
                .font(
                    .system(
                        size: 15,
                        weight: .semibold
                    )
                )
                .opacity(
                    showsHUDRegions
                    ? 1.0
                    : 0.45
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.bordered)
            .help(
                showsHUDRegions
                ? "Hide HUD Region Boxes"
                : "Show HUD Region Boxes"
            )

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
        }
        .fixedSize()
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
        ) { newTime in
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

// MARK: - Frame Debug

struct FrameDebugView: View {
    @ObservedObject var analyzer:
        FrameAnalyzer

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

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {
            Text("FRAME ANALYZER")
                .font(
                    .system(
                        size: 12,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.white)

            Divider()
                .overlay(
                    Color.white.opacity(0.25)
                )

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

            Divider()
                .overlay(
                    Color.white.opacity(0.25)
                )

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

            debugRow(
                title: "Last Frame",
                value:
                    lastFrameText
            )

            Divider()
                .overlay(
                    Color.white.opacity(0.25)
                )

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
        .padding(12)
        .frame(
            width: 300,
            alignment: .leading
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
        }
        .font(
            .system(
                size: 11,
                design: .monospaced
            )
        )
        .monospacedDigit()
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

// MARK: - Dataset Metadata Counter

struct DatasetMetadataCounterView:
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

    @Binding var gameVolume:
        Double

    @Binding var trainerVolume:
        Double

    @Binding var gameMuted:
        Bool

    @Binding var trainerMuted:
        Bool

    let gameAudioAvailable:
        Bool

    let gameAudioStatus:
        String

    @ObservedObject var datasetRecorder:
        MinimapDatasetRecorder

    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            Text("AUDIO MIXER")
                .font(.headline)

            AudioChannelRow(
                title:
                    "Game Audio",
                statusText:
                    gameAudioStatus,
                volume:
                    $gameVolume,
                isMuted:
                    $gameMuted,
                controlsEnabled:
                    gameAudioAvailable
            )

            Divider()

            AudioChannelRow(
                title:
                    "Trainer Voice",
                statusText:
                    "Not connected yet",
                volume:
                    $trainerVolume,
                isMuted:
                    $trainerMuted,
                controlsEnabled:
                    false
            )

            Divider()

            MinimapDatasetControls(
                recorder:
                    datasetRecorder
            )

            DatasetMetadataCounterView(
                store:
                    datasetRecorder
                        .metadataStore,
                isOverlay:
                    false
            )

            Spacer(
                minLength:
                    0
            )
        }
        .padding(20)
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .background(
            Color(
                nsColor:
                    .controlBackgroundColor
            )
        )
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
