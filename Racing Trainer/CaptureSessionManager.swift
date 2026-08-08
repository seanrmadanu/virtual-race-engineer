import CoreVideo
import AVFoundation
import Combine
import Foundation

final class CaptureSessionManager:
    NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate {

    let session =
        AVCaptureSession()

    let frameAnalyzer =
        FrameAnalyzer(
            targetSpeedAnalysisFPS:
                15.0,
            targetMinimapAnalysisFPS:
                30.0
        )

    let minimapDatasetRecorder =
        MinimapDatasetRecorder(
            sampleInterval:
                1.0,
            minimumFrameDifference:
                0.015
        )


    private let audioSession =
        AVCaptureSession()

    @Published private(set)
    var isReceivingVideo = false

    @Published private(set)
    var isGameAudioAvailable = false

    @Published private(set)
    var errorMessage: String?

    @Published private(set)
    var audioErrorMessage: String?

    @Published private(set)
    var configuredDeviceID: String?

    @Published private(set)
    var configuredAudioDeviceID: String?

    @Published private(set)
    var configuredAudioOutputDeviceUID:
        String?

    private let videoSessionQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.video-session",
            qos:
                .userInteractive
        )

    private let audioSessionQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.audio-session",
            qos:
                .userInitiated
        )

    private let videoOutputQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.video-output",
            qos:
                .userInteractive
        )

    private let videoOutput =
        AVCaptureVideoDataOutput()

    private let audioPreviewOutput =
        AVCaptureAudioPreviewOutput()

    private var currentVideoInput:
        AVCaptureDeviceInput?

    private var currentAudioInput:
        AVCaptureDeviceInput?

    private var requestedVideoDeviceID:
        String?

    private var requestedAudioDeviceID:
        String?

    private let videoRequestLock =
        NSLock()

    private let audioRequestLock =
        NSLock()

    private var latestVideoRequestNumber = 0
    private var latestAudioRequestNumber = 0

    private let frameStateLock =
        NSLock()

    private var hasReceivedCurrentVideoFrame =
        false

    private var acceptFramesAfterUptime =
        0.0

    private var desiredGameVolume:
        Float = 0.80

    private var desiredGameMuted =
        false

    override init() {
        super.init()

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA)
        ]

        videoOutput
            .alwaysDiscardsLateVideoFrames =
            true

        videoOutput.setSampleBufferDelegate(
            self,
            queue:
                videoOutputQueue
        )

        audioPreviewOutput
            .outputDeviceUniqueID =
            nil

        audioPreviewOutput.volume =
            desiredGameVolume
    }

    // MARK: - Refresh All Sources

    func refreshSources(
        videoDevice: AVCaptureDevice?,
        audioDevice: AVCaptureDevice?,
        audioOutputUniqueID: String?
    ) {
        configureVideo(
            device: videoDevice,
            forceRestart: true
        )

        // Apply the output route before restarting audio.
        setAudioOutputDevice(
            uniqueID:
                audioOutputUniqueID
        )

        configureAudio(
            device: audioDevice,
            forceRestart: true
        )
    }

    /// Temporarily stops hardware input while a local gameplay recording is
    /// being used. Inputs remain configured so returning to live capture is
    /// quick and still uses the device selected in Settings.
    func pauseLiveSourcesForTestPlayback() {
        _ = createVideoRequestNumber()
        _ = createAudioRequestNumber()

        frameStateLock.lock()

        hasReceivedCurrentVideoFrame =
            false

        acceptFramesAfterUptime =
            .greatestFiniteMagnitude

        frameStateLock.unlock()

        videoSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            DispatchQueue.main.async {
                self.isReceivingVideo =
                    false

                self.errorMessage =
                    nil
            }
        }

        audioSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            if self.audioSession.isRunning {
                self.audioSession.stopRunning()
            }

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    false

                self.audioErrorMessage =
                    nil
            }
        }
    }

    // MARK: - Configure Video

    func configureVideo(
        device: AVCaptureDevice?,
        forceRestart: Bool = false
    ) {
        let requestNumber =
            createVideoRequestNumber()

        let newDeviceID =
            device?.uniqueID

        videoSessionQueue.async {
            [weak self] in

            guard let self,
                  self.isLatestVideoRequest(
                    requestNumber
                  ) else {
                return
            }

            if !forceRestart,
               self.requestedVideoDeviceID ==
                newDeviceID,
               self.currentVideoInput?
                .device.uniqueID ==
                newDeviceID,
               self.session.isRunning {

                return
            }

            self.requestedVideoDeviceID =
                newDeviceID

            self.resetFrameState()

            DispatchQueue.main.async {
                self.isReceivingVideo =
                    false

                self.errorMessage =
                    nil
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            guard self.isLatestVideoRequest(
                requestNumber
            ) else {
                return
            }

            self.session
                .beginConfiguration()

            if let currentVideoInput =
                self.currentVideoInput {

                self.session.removeInput(
                    currentVideoInput
                )

                self.currentVideoInput =
                    nil
            }

            if self.session
                .canSetSessionPreset(
                    .high
                ) {

                self.session.sessionPreset =
                    .high
            }

            var configurationError:
                Error?

            self.addVideoOutputIfNeeded(
                error:
                    &configurationError
            )

            if let device,
               configurationError == nil {

                do {
                    let input =
                        try AVCaptureDeviceInput(
                            device: device
                        )

                    if self.session.canAddInput(
                        input
                    ) {
                        self.session.addInput(
                            input
                        )

                        self.currentVideoInput =
                            input
                    } else {
                        configurationError =
                            CaptureSessionError(
                                message:
                                    "The selected video source cannot be added to the capture session."
                            )
                    }
                } catch {
                    configurationError =
                        error
                }
            }

            self.session
                .commitConfiguration()

            guard self.isLatestVideoRequest(
                requestNumber
            ) else {
                return
            }

            guard let device else {
                DispatchQueue.main.async {
                    self.configuredDeviceID =
                        nil

                    self.isReceivingVideo =
                        false
                }

                return
            }

            if let configurationError {
                DispatchQueue.main.async {
                    self.configuredDeviceID =
                        nil

                    self.isReceivingVideo =
                        false

                    self.errorMessage =
                        configurationError
                            .localizedDescription
                }

                return
            }

            self.prepareForNewFrames(
                ignoreDuration:
                    0.10
            )

            self.session.startRunning()

            guard self.isLatestVideoRequest(
                requestNumber
            ) else {
                return
            }

            DispatchQueue.main.async {
                self.configuredDeviceID =
                    device.uniqueID
            }
        }
    }

    private func addVideoOutputIfNeeded(
        error: inout Error?
    ) {
        let hasVideoOutput =
            session.outputs.contains {
                $0 === videoOutput
            }

        guard !hasVideoOutput else {
            return
        }

        if session.canAddOutput(
            videoOutput
        ) {
            session.addOutput(
                videoOutput
            )
        } else {
            error =
                CaptureSessionError(
                    message:
                        "Racing Trainer could not create its video output."
                )
        }
    }

    // MARK: - Configure Audio Input

    func configureAudio(
        device: AVCaptureDevice?,
        forceRestart: Bool = false
    ) {
        let requestNumber =
            createAudioRequestNumber()

        let newDeviceID =
            device?.uniqueID

        audioSessionQueue.async {
            [weak self] in

            guard let self,
                  self.isLatestAudioRequest(
                    requestNumber
                  ) else {
                return
            }

            if !forceRestart,
               self.requestedAudioDeviceID ==
                newDeviceID,
               self.currentAudioInput?
                .device.uniqueID ==
                newDeviceID,
               self.audioSession.isRunning {

                self.applyGameAudioVolume()
                return
            }

            self.requestedAudioDeviceID =
                newDeviceID

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    false

                self.audioErrorMessage =
                    nil
            }

            if self.audioSession.isRunning {
                self.audioSession
                    .stopRunning()
            }

            guard self.isLatestAudioRequest(
                requestNumber
            ) else {
                return
            }

            self.audioSession
                .beginConfiguration()

            if let currentAudioInput =
                self.currentAudioInput {

                self.audioSession.removeInput(
                    currentAudioInput
                )

                self.currentAudioInput =
                    nil
            }

            var configurationError:
                Error?

            self.addAudioPreviewOutputIfNeeded(
                error:
                    &configurationError
            )

            if let device,
               configurationError == nil {

                do {
                    let input =
                        try AVCaptureDeviceInput(
                            device: device
                        )

                    if self.audioSession
                        .canAddInput(
                            input
                        ) {

                        self.audioSession.addInput(
                            input
                        )

                        self.currentAudioInput =
                            input
                    } else {
                        configurationError =
                            CaptureSessionError(
                                message:
                                    "The selected audio input cannot be added to the audio session."
                            )
                    }
                } catch {
                    configurationError =
                        error
                }
            }

            self.audioSession
                .commitConfiguration()

            guard self.isLatestAudioRequest(
                requestNumber
            ) else {
                return
            }

            guard let device else {
                DispatchQueue.main.async {
                    self.configuredAudioDeviceID =
                        nil

                    self.isGameAudioAvailable =
                        false
                }

                return
            }

            if let configurationError {
                DispatchQueue.main.async {
                    self.configuredAudioDeviceID =
                        nil

                    self.isGameAudioAvailable =
                        false

                    self.audioErrorMessage =
                        configurationError
                            .localizedDescription
                }

                return
            }

            self.applyGameAudioVolume()

            self.audioSession.startRunning()

            guard self.isLatestAudioRequest(
                requestNumber
            ) else {
                return
            }

            let audioStarted =
                self.audioSession.isRunning

            DispatchQueue.main.async {
                self.configuredAudioDeviceID =
                    audioStarted
                    ? device.uniqueID
                    : nil

                self.isGameAudioAvailable =
                    audioStarted

                self.audioErrorMessage =
                    audioStarted
                    ? nil
                    : "The selected audio input could not start its preview session."
            }
        }
    }

    private func addAudioPreviewOutputIfNeeded(
        error: inout Error?
    ) {
        let hasOutput =
            audioSession.outputs.contains {
                $0 === audioPreviewOutput
            }

        guard !hasOutput else {
            return
        }

        if audioSession.canAddOutput(
            audioPreviewOutput
        ) {
            audioSession.addOutput(
                audioPreviewOutput
            )
        } else {
            error =
                CaptureSessionError(
                    message:
                        "Racing Trainer could not create its game-audio preview output."
                )
        }
    }

    // MARK: - Audio Output

    func setAudioOutputDevice(
        uniqueID: String?
    ) {
        let normalizedUniqueID:
            String?

        if let uniqueID,
           !uniqueID.isEmpty {

            normalizedUniqueID =
                uniqueID
        } else {
            normalizedUniqueID =
                nil
        }

        audioSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            let routeAlreadySelected =
                self.audioPreviewOutput
                    .outputDeviceUniqueID ==
                normalizedUniqueID

            if routeAlreadySelected,
               self.audioSession.isRunning {

                DispatchQueue.main.async {
                    self
                        .configuredAudioOutputDeviceUID =
                        normalizedUniqueID
                }

                return
            }

            let hadAudioInput =
                self.currentAudioInput != nil

            if self.audioSession.isRunning {
                self.audioSession
                    .stopRunning()
            }

            self.audioPreviewOutput
                .outputDeviceUniqueID =
                normalizedUniqueID

            self.applyGameAudioVolume()

            if hadAudioInput {
                self.audioSession
                    .startRunning()
            }

            let audioStarted =
                hadAudioInput &&
                self.audioSession.isRunning

            DispatchQueue.main.async {
                self
                    .configuredAudioOutputDeviceUID =
                    normalizedUniqueID

                if hadAudioInput {
                    self.isGameAudioAvailable =
                        audioStarted

                    self.audioErrorMessage =
                        audioStarted
                        ? nil
                        : "The selected audio output could not start the game-audio preview."
                }
            }
        }
    }

    // MARK: - Volume and Mute

    func setGameAudio(
        volume: Double,
        muted: Bool
    ) {
        let safeVolume =
            Float(
                min(
                    max(
                        volume,
                        0
                    ),
                    1
                )
            )

        audioSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            self.desiredGameVolume =
                safeVolume

            self.desiredGameMuted =
                muted

            self.applyGameAudioVolume()
        }
    }

    private func applyGameAudioVolume() {
        audioPreviewOutput.volume =
            desiredGameMuted
            ? 0
            : desiredGameVolume
    }

    // MARK: - Stop

    func stop() {
        minimapDatasetRecorder
            .stopRecording()

        _ = createVideoRequestNumber()
        _ = createAudioRequestNumber()

        videoSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            self.resetFrameState()

            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.session
                .beginConfiguration()

            if let currentVideoInput =
                self.currentVideoInput {

                self.session.removeInput(
                    currentVideoInput
                )

                self.currentVideoInput =
                    nil
            }

            self.session
                .commitConfiguration()

            self.requestedVideoDeviceID =
                nil

            DispatchQueue.main.async {
                self.configuredDeviceID =
                    nil

                self.isReceivingVideo =
                    false
            }
        }

        audioSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            if self.audioSession.isRunning {
                self.audioSession
                    .stopRunning()
            }

            self.audioSession
                .beginConfiguration()

            if let currentAudioInput =
                self.currentAudioInput {

                self.audioSession.removeInput(
                    currentAudioInput
                )

                self.currentAudioInput =
                    nil
            }

            self.audioSession
                .commitConfiguration()

            self.requestedAudioDeviceID =
                nil

            DispatchQueue.main.async {
                self.configuredAudioDeviceID =
                    nil

                self.isGameAudioAvailable =
                    false
            }
        }
    }

    // MARK: - Request Ordering

    private func createVideoRequestNumber()
        -> Int {

        videoRequestLock.lock()

        latestVideoRequestNumber += 1

        let requestNumber =
            latestVideoRequestNumber

        videoRequestLock.unlock()

        return requestNumber
    }

    private func isLatestVideoRequest(
        _ requestNumber: Int
    ) -> Bool {
        videoRequestLock.lock()

        let isLatest =
            requestNumber ==
            latestVideoRequestNumber

        videoRequestLock.unlock()

        return isLatest
    }

    private func createAudioRequestNumber()
        -> Int {

        audioRequestLock.lock()

        latestAudioRequestNumber += 1

        let requestNumber =
            latestAudioRequestNumber

        audioRequestLock.unlock()

        return requestNumber
    }

    private func isLatestAudioRequest(
        _ requestNumber: Int
    ) -> Bool {
        audioRequestLock.lock()

        let isLatest =
            requestNumber ==
            latestAudioRequestNumber

        audioRequestLock.unlock()

        return isLatest
    }

    // MARK: - Video Frames

    func captureOutput(
        _ output:
            AVCaptureOutput,
        didOutput sampleBuffer:
            CMSampleBuffer,
        from connection:
            AVCaptureConnection
    ) {
        guard output === videoOutput,
              CMSampleBufferDataIsReady(
                sampleBuffer
              ) else {
            return
        }

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        frameStateLock.lock()

        guard currentUptime >=
                acceptFramesAfterUptime else {

            frameStateLock.unlock()
            return
        }

        let shouldPublishVideoState =
            !hasReceivedCurrentVideoFrame

        if shouldPublishVideoState {
            hasReceivedCurrentVideoFrame =
                true
        }

        frameStateLock.unlock()

        if shouldPublishVideoState {
            DispatchQueue.main.async {
                [weak self] in

                self?.isReceivingVideo =
                    true

                self?.errorMessage =
                    nil
            }
        }

        // Hand every valid frame to the analyzer.
        // The analyzer performs its own throttling and
        // moves actual work to a separate utility queue.
        frameAnalyzer.receive(
            sampleBuffer
        )

        minimapDatasetRecorder.receive(
            sampleBuffer
        )
    }

    private func resetFrameState() {
        frameStateLock.lock()

        hasReceivedCurrentVideoFrame =
            false

        acceptFramesAfterUptime =
            0

        frameStateLock.unlock()

        frameAnalyzer.reset()
    }

    private func prepareForNewFrames(
        ignoreDuration:
            TimeInterval
    ) {
        frameStateLock.lock()

        hasReceivedCurrentVideoFrame =
            false

        acceptFramesAfterUptime =
            ProcessInfo
                .processInfo
                .systemUptime +
            ignoreDuration

        frameStateLock.unlock()
    }
}

// MARK: - Capture Error

private struct CaptureSessionError:
    LocalizedError {

    let message:
        String

    var errorDescription:
        String? {

        message
    }
}
