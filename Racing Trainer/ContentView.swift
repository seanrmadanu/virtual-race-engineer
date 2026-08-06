import SwiftUI
import AppKit
import AVFoundation
import Combine

struct ContentView: View {
    @ObservedObject var captureDevices:
        CaptureDeviceManager

    @StateObject private var captureSession =
        CaptureSessionManager()

    @State private var noConnectionAnimator =
        NoConnectionAnimator()

    @State private var isVideoFullscreen =
        false

    @State private var videoFullscreenOwnsNativeFullscreen =
        false

    @State private var gameVolume =
        0.80

    @State private var trainerVolume =
        0.65

    @State private var microphoneVolume =
        0.50

    @State private var gameMuted =
        false

    @State private var trainerMuted =
        false

    @State private var microphoneMuted =
        true

    // MARK: - Source Information

    private var hasAvailableInputSource:
        Bool {

        !captureDevices
            .videoDevices
            .isEmpty
    }

    private var hasActiveInputSource:
        Bool {

        captureDevices
            .activeDeviceID != nil
    }

    private var sourceStatusText:
        String {

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

        if captureDevices
            .cameraPermissionDenied ||
            captureSession
            .errorMessage != nil {

            return .red
        }

        if captureSession
            .isReceivingVideo {

            return .green
        }

        if hasActiveInputSource {
            return .yellow
        }

        return .secondary
    }

    private var gameAudioStatusText:
        String {

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
                    session:
                        captureSession.session,
                    hasAvailableInputSource:
                        hasAvailableInputSource,
                    isReceivingVideo:
                        captureSession
                            .isReceivingVideo,
                    errorMessage:
                        captureSession
                            .errorMessage,
                    isFullscreen:
                        true,
                    isGameMuted:
                        gameMuted,
                    animator:
                        noConnectionAnimator,
                    onMuteToggle:
                        toggleGameMute,
                    onRefresh:
                        refreshAllSources,
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

            captureDevices
                .refreshDevicesWithRetry()

            captureSession.setGameAudio(
                volume:
                    gameVolume,
                muted:
                    gameMuted
            )

            applySelectedAudioOutput()

            /*
             Device discovery may still be finishing when
             ContentView first appears.

             Starting the current sources directly prevents
             audio from being skipped when activeAudioDeviceID
             was already set before onReceive subscribed.
             */
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.5
            ) {
                startCurrentSources()
            }
        }

        /*
         Stop the capture sessions only when the app
         terminates. Do not stop them during fullscreen
         transitions.
         */
        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        NSApplication
                        .willTerminateNotification
                )
        ) { _ in
            captureSession.stop()
        }

        .onReceive(
            captureDevices
                .$activeDeviceID
                .removeDuplicates()
        ) { deviceID in
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
                    session:
                        captureSession.session,
                    hasAvailableInputSource:
                        hasAvailableInputSource,
                    isReceivingVideo:
                        captureSession
                            .isReceivingVideo,
                    errorMessage:
                        captureSession
                            .errorMessage,
                    isFullscreen:
                        false,
                    isGameMuted:
                        gameMuted,
                    animator:
                        noConnectionAnimator,
                    onMuteToggle:
                        toggleGameMute,
                    onRefresh:
                        refreshAllSources,
                    onFullscreenToggle:
                        enterVideoFullscreen
                )

                Divider()

                AudioMixerView(
                    gameVolume:
                        $gameVolume,
                    trainerVolume:
                        $trainerVolume,
                    microphoneVolume:
                        $microphoneVolume,
                    gameMuted:
                        $gameMuted,
                    trainerMuted:
                        $trainerMuted,
                    microphoneMuted:
                        $microphoneMuted,
                    gameAudioAvailable:
                        captureSession
                            .isGameAudioAvailable,
                    gameAudioStatus:
                        gameAudioStatusText
                )
                .frame(width: 300)
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

        ZStack(
            alignment:
                .bottomTrailing
        ) {
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

                Spacer()
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(18)

            SettingsLink {
                Label(
                    "Settings",
                    systemImage:
                        "gearshape"
                )
            }
            .buttonStyle(.bordered)
            .padding(18)
        }
        .frame(height: 110)
        .background(
            Color(
                nsColor:
                    .controlBackgroundColor
            )
        )
    }

    // MARK: - Source Startup

    private func startCurrentSources() {
        captureSession.configureVideo(
            device:
                captureDevices
                    .activeDevice
        )

        captureSession.configureAudio(
            device:
                captureDevices
                    .activeAudioDevice
        )

        captureSession.setGameAudio(
            volume:
                gameVolume,
            muted:
                gameMuted
        )

        applySelectedAudioOutput()
    }

    // MARK: - Preview Controls

    private func toggleGameMute() {
        gameMuted.toggle()
    }

    private func refreshAllSources() {
        captureDevices
            .refreshDevicesWithRetry()

        /*
         Wait briefly for the refreshed device lists
         before force-restarting the current sources.
         */
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.4
        ) {
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

            captureSession.setGameAudio(
                volume:
                    gameVolume,
                muted:
                    gameMuted
            )
        }
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
    let session:
        AVCaptureSession

    let hasAvailableInputSource:
        Bool

    let isReceivingVideo:
        Bool

    let errorMessage:
        String?

    let isFullscreen:
        Bool

    let isGameMuted:
        Bool

    let animator:
        NoConnectionAnimator

    let onMuteToggle:
        () -> Void

    let onRefresh:
        () -> Void

    let onFullscreenToggle:
        () -> Void

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

            CaptureVideoPreview(
                session:
                    session
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

            previewControlButtons
                .padding(16)
        }
    }

    private var previewControlButtons:
        some View {

        HStack(spacing: 8) {
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
                "Refresh Video and Audio Sources"
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

// MARK: - AVFoundation Preview

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

// MARK: - Audio Mixer

struct AudioMixerView: View {
    @Binding var gameVolume:
        Double

    @Binding var trainerVolume:
        Double

    @Binding var microphoneVolume:
        Double

    @Binding var gameMuted:
        Bool

    @Binding var trainerMuted:
        Bool

    @Binding var microphoneMuted:
        Bool

    let gameAudioAvailable:
        Bool

    let gameAudioStatus:
        String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 22
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

            AudioChannelRow(
                title:
                    "Microphone",
                statusText:
                    "Not connected yet",
                volume:
                    $microphoneVolume,
                isMuted:
                    $microphoneMuted,
                controlsEnabled:
                    false
            )

            Spacer()
        }
        .padding(20)
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
