import AVFoundation
import Combine
import Foundation

final class CaptureSessionManager:
    NSObject,
    ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    let session =
        AVCaptureSession()

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

    private let audioOutputQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.audio-output",
            qos:
                .userInitiated
        )

    private let videoOutput =
        AVCaptureVideoDataOutput()

    /*
     This output provides the sound that the user hears.
     */
    private let audioPreviewOutput =
        AVCaptureAudioPreviewOutput()

    /*
     This output lets the app verify that real audio
     sample buffers are arriving from the capture card.
     */
    private let audioDataOutput =
        AVCaptureAudioDataOutput()

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

    // MARK: Video Frame State

    private let videoFrameStateLock =
        NSLock()

    private var hasReceivedCurrentVideoFrame =
        false

    private var acceptVideoFramesAfterUptime =
        0.0

    // MARK: Audio Stream State

    private let audioStateLock =
        NSLock()

    private var hasReceivedCurrentAudioSample =
        false

    private var audioStreamReady =
        false

    private var audioReadinessCheckPending =
        false

    private var acceptAudioSamplesAfterUptime =
        0.0

    private var lastAudioSampleUptime =
        0.0

    /*
     Maximum gap between sample buffers before the
     audio stream is considered stalled.
     */
    private let maximumHealthyAudioSampleGap:
        TimeInterval = 2.5

    private let audioStartupCheckDelay:
        TimeInterval = 1.25

    private let audioWatchdogInterval:
        TimeInterval = 2.0

    /*
     These are bounded retries. The app will not
     endlessly restart the capture card.
     */
    private let automaticAudioRecoveryDelays:
        [TimeInterval] = [
            0.25,
            0.75,
            1.50,
            3.00
        ]

    // MARK: Audio Volume State

    private var desiredGameVolume:
        Float = 0.80

    private var desiredGameMuted =
        false

    private var audioVolumeRampToken =
        0

    override init() {
        super.init()

        videoOutput
            .alwaysDiscardsLateVideoFrames =
            true

        videoOutput.setSampleBufferDelegate(
            self,
            queue:
                videoOutputQueue
        )

        audioDataOutput.setSampleBufferDelegate(
            self,
            queue:
                audioOutputQueue
        )

        /*
         nil means the current macOS system-default
         audio output.
         */
        audioPreviewOutput
            .outputDeviceUniqueID =
            nil

        /*
         Keep preview muted until real audio sample
         buffers are confirmed.
         */
        audioPreviewOutput.volume = 0
    }

    // MARK: - Refresh All Sources

    func refreshSources(
        videoDevice: AVCaptureDevice?,
        audioDevice: AVCaptureDevice?,
        audioOutputUniqueID: String?
    ) {
        /*
         Queue the selected output before restarting
         the audio input.
         */
        setAudioOutputDevice(
            uniqueID:
                audioOutputUniqueID
        )

        configureVideo(
            device:
                videoDevice,
            forceRestart:
                true
        )

        configureAudio(
            device:
                audioDevice,
            forceRestart:
                true
        )
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

            self.resetVideoFrameState()

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
                    let freshDevice =
                        AVCaptureDevice(
                            uniqueID:
                                device.uniqueID
                        ) ??
                        device

                    let input =
                        try AVCaptureDeviceInput(
                            device:
                                freshDevice
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

            self.prepareForNewVideoFrames(
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
        let alreadyAdded =
            session.outputs.contains {
                $0 === videoOutput
            }

        guard !alreadyAdded else {
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

    // MARK: - Configure Audio

    func configureAudio(
        device: AVCaptureDevice?,
        forceRestart: Bool = false
    ) {
        configureAudio(
            device:
                device,
            forceRestart:
                forceRestart,
            recoveryAttempt:
                0
        )
    }

    private func configureAudio(
        device: AVCaptureDevice?,
        forceRestart: Bool,
        recoveryAttempt: Int
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

            self.cancelAudioVolumeRamp()
            self.audioPreviewOutput.volume = 0
            self.resetAudioStreamState()

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    false

                self.audioErrorMessage =
                    nil
            }

            if self.audioSession.isRunning {
                self.audioSession.stopRunning()
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

            self.addAudioOutputsIfNeeded(
                error:
                    &configurationError
            )

            if let device,
               configurationError == nil {

                do {
                    /*
                     Reacquire the device object for every
                     retry instead of reusing a stale USB
                     device object.
                     */
                    let freshDevice =
                        AVCaptureDevice(
                            uniqueID:
                                device.uniqueID
                        ) ??
                        device

                    let input =
                        try AVCaptureDeviceInput(
                            device:
                                freshDevice
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

                self.scheduleAudioRecovery(
                    expectedDeviceID:
                        device.uniqueID,
                    requestNumber:
                        requestNumber,
                    recoveryAttempt:
                        recoveryAttempt
                )

                return
            }

            self.prepareForNewAudioSamples(
                ignoreDuration:
                    0.05
            )

            self.audioSession.startRunning()

            guard self.isLatestAudioRequest(
                requestNumber
            ) else {
                return
            }

            guard self.audioSession.isRunning else {
                DispatchQueue.main.async {
                    self.configuredAudioDeviceID =
                        nil

                    self.isGameAudioAvailable =
                        false

                    self.audioErrorMessage =
                        "The audio session did not start."
                }

                self.scheduleAudioRecovery(
                    expectedDeviceID:
                        device.uniqueID,
                    requestNumber:
                        requestNumber,
                    recoveryAttempt:
                        recoveryAttempt
                )

                return
            }

            DispatchQueue.main.async {
                self.configuredAudioDeviceID =
                    device.uniqueID
            }

            self.scheduleAudioWatchdog(
                expectedDeviceID:
                    device.uniqueID,
                requestNumber:
                    requestNumber,
                recoveryAttempt:
                    recoveryAttempt,
                delay:
                    self.audioStartupCheckDelay
            )
        }
    }

    private func addAudioOutputsIfNeeded(
        error: inout Error?
    ) {
        let hasAudioDataOutput =
            audioSession.outputs.contains {
                $0 === audioDataOutput
            }

        if !hasAudioDataOutput {
            if audioSession.canAddOutput(
                audioDataOutput
            ) {
                audioSession.addOutput(
                    audioDataOutput
                )
            } else {
                error =
                    CaptureSessionError(
                        message:
                            "Racing Trainer could not create its audio monitoring output."
                    )

                return
            }
        }

        let hasAudioPreviewOutput =
            audioSession.outputs.contains {
                $0 === audioPreviewOutput
            }

        if !hasAudioPreviewOutput {
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
    }

    // MARK: - Audio Output Device

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

            if self.audioPreviewOutput
                .outputDeviceUniqueID ==
                normalizedUniqueID {

                DispatchQueue.main.async {
                    self
                        .configuredAudioOutputDeviceUID =
                        normalizedUniqueID
                }

                return
            }

            self.cancelAudioVolumeRamp()
            self.audioPreviewOutput.volume = 0

            self.audioPreviewOutput
                .outputDeviceUniqueID =
                normalizedUniqueID

            DispatchQueue.main.async {
                self
                    .configuredAudioOutputDeviceUID =
                    normalizedUniqueID
            }

            if self.isAudioStreamHealthy() {
                self.audioSessionQueue.asyncAfter(
                    deadline:
                        .now() + 0.10
                ) { [weak self] in
                    self?
                        .beginAudioVolumeRamp()
                }
            }
        }
    }

    // MARK: - Audio Sample Handling

    private func handleAudioSampleBuffer(
        _ sampleBuffer:
            CMSampleBuffer
    ) {
        guard CMSampleBufferDataIsReady(
            sampleBuffer
        ) else {
            return
        }

        let shouldCheckPreview =
            noteAudioSampleAndRequestReadinessCheck()

        guard shouldCheckPreview else {
            return
        }

        audioSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            let previewConnectionReady =
                self.audioSession.isRunning &&
                self.currentAudioInput != nil &&
                self.audioPreviewOutput
                    .connection(
                        with: .audio
                    )?
                    .isEnabled ==
                true

            let becameReady =
                self.finishAudioReadinessCheck(
                    previewConnectionReady:
                        previewConnectionReady
                )

            guard becameReady else {
                return
            }

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    true

                self.audioErrorMessage =
                    nil
            }

            self.beginAudioVolumeRamp()
        }
    }

    private func noteAudioSampleAndRequestReadinessCheck()
        -> Bool {

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        audioStateLock.lock()

        guard currentUptime >=
                acceptAudioSamplesAfterUptime else {

            audioStateLock.unlock()
            return false
        }

        hasReceivedCurrentAudioSample =
            true

        lastAudioSampleUptime =
            currentUptime

        guard !audioStreamReady,
              !audioReadinessCheckPending else {

            audioStateLock.unlock()
            return false
        }

        audioReadinessCheckPending =
            true

        audioStateLock.unlock()

        return true
    }

    private func finishAudioReadinessCheck(
        previewConnectionReady:
            Bool
    ) -> Bool {
        audioStateLock.lock()

        audioReadinessCheckPending =
            false

        let shouldBecomeReady =
            previewConnectionReady &&
            hasReceivedCurrentAudioSample &&
            !audioStreamReady

        if shouldBecomeReady {
            audioStreamReady =
                true
        }

        audioStateLock.unlock()

        return shouldBecomeReady
    }

    // MARK: - Audio Watchdog

    private func scheduleAudioWatchdog(
        expectedDeviceID: String,
        requestNumber: Int,
        recoveryAttempt: Int,
        delay: TimeInterval
    ) {
        audioSessionQueue.asyncAfter(
            deadline:
                .now() + delay
        ) { [weak self] in
            guard let self,
                  self.isLatestAudioRequest(
                    requestNumber
                  ),
                  self.currentAudioInput?
                    .device.uniqueID ==
                    expectedDeviceID else {
                return
            }

            if self.isAudioStreamHealthy() {
                self.scheduleAudioWatchdog(
                    expectedDeviceID:
                        expectedDeviceID,
                    requestNumber:
                        requestNumber,
                    recoveryAttempt:
                        0,
                    delay:
                        self.audioWatchdogInterval
                )

                return
            }

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    false

                self.audioErrorMessage =
                    nil
            }

            self.cancelAudioVolumeRamp()
            self.audioPreviewOutput.volume = 0

            self.scheduleAudioRecovery(
                expectedDeviceID:
                    expectedDeviceID,
                requestNumber:
                    requestNumber,
                recoveryAttempt:
                    recoveryAttempt
            )
        }
    }

    private func scheduleAudioRecovery(
        expectedDeviceID: String,
        requestNumber: Int,
        recoveryAttempt: Int
    ) {
        guard isLatestAudioRequest(
            requestNumber
        ) else {
            return
        }

        guard recoveryAttempt <
                automaticAudioRecoveryDelays
                    .count else {

            let receivedSamples =
                hasReceivedAnyAudioSamples()

            DispatchQueue.main.async {
                self.isGameAudioAvailable =
                    false

                if receivedSamples {
                    self.audioErrorMessage =
                        "Audio data arrived, but macOS could not create a playable preview connection. Press Refresh or reconnect the capture card."
                } else {
                    self.audioErrorMessage =
                        "The capture card did not send audio data. Press Refresh or reconnect the capture card."
                }
            }

            return
        }

        let retryDelay =
            automaticAudioRecoveryDelays[
                recoveryAttempt
            ]

        audioSessionQueue.asyncAfter(
            deadline:
                .now() + retryDelay
        ) { [weak self] in
            guard let self,
                  self.isLatestAudioRequest(
                    requestNumber
                  ) else {
                return
            }

            let refreshedDevice =
                AVCaptureDevice(
                    uniqueID:
                        expectedDeviceID
                ) ??
                self.currentAudioInput?
                    .device

            guard let refreshedDevice,
                  refreshedDevice.isConnected else {

                DispatchQueue.main.async {
                    self.isGameAudioAvailable =
                        false

                    self.audioErrorMessage =
                        "The selected audio input is no longer connected."
                }

                return
            }

            self.configureAudio(
                device:
                    refreshedDevice,
                forceRestart:
                    true,
                recoveryAttempt:
                    recoveryAttempt + 1
            )
        }
    }

    private func isAudioStreamHealthy()
        -> Bool {

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        audioStateLock.lock()

        let healthy =
            audioStreamReady &&
            hasReceivedCurrentAudioSample &&
            currentUptime -
                lastAudioSampleUptime <=
                maximumHealthyAudioSampleGap

        audioStateLock.unlock()

        return healthy
    }

    private func hasReceivedAnyAudioSamples()
        -> Bool {

        audioStateLock.lock()

        let received =
            hasReceivedCurrentAudioSample

        audioStateLock.unlock()

        return received
    }

    private func resetAudioStreamState() {
        audioStateLock.lock()

        hasReceivedCurrentAudioSample =
            false

        audioStreamReady =
            false

        audioReadinessCheckPending =
            false

        acceptAudioSamplesAfterUptime =
            0

        lastAudioSampleUptime =
            0

        audioStateLock.unlock()
    }

    private func prepareForNewAudioSamples(
        ignoreDuration:
            TimeInterval
    ) {
        audioStateLock.lock()

        hasReceivedCurrentAudioSample =
            false

        audioStreamReady =
            false

        audioReadinessCheckPending =
            false

        lastAudioSampleUptime =
            0

        acceptAudioSamplesAfterUptime =
            ProcessInfo
                .processInfo
                .systemUptime +
            ignoreDuration

        audioStateLock.unlock()
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

            self.cancelAudioVolumeRamp()
            self.applyGameAudioVolume()
        }
    }

    private func applyGameAudioVolume() {
        guard isAudioStreamHealthy() else {
            audioPreviewOutput.volume = 0
            return
        }

        audioPreviewOutput.volume =
            desiredGameMuted
            ? 0
            : desiredGameVolume
    }

    private func beginAudioVolumeRamp() {
        cancelAudioVolumeRamp()

        guard isAudioStreamHealthy(),
              !desiredGameMuted,
              desiredGameVolume > 0 else {

            audioPreviewOutput.volume = 0
            return
        }

        let rampToken =
            audioVolumeRampToken

        let targetVolume =
            desiredGameVolume

        audioPreviewOutput.volume = 0

        let rampSteps:
            [(delay: TimeInterval, amount: Float)] = [
                (0.03, 0.20),
                (0.07, 0.50),
                (0.12, 1.00)
            ]

        for step in rampSteps {
            audioSessionQueue.asyncAfter(
                deadline:
                    .now() + step.delay
            ) { [weak self] in
                guard let self,
                      self.audioVolumeRampToken ==
                        rampToken,
                      self.isAudioStreamHealthy(),
                      !self.desiredGameMuted else {
                    return
                }

                self.audioPreviewOutput.volume =
                    targetVolume *
                    step.amount
            }
        }
    }

    private func cancelAudioVolumeRamp() {
        audioVolumeRampToken += 1
    }

    // MARK: - Stop

    func stop() {
        _ = createVideoRequestNumber()
        _ = createAudioRequestNumber()

        videoSessionQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            self.resetVideoFrameState()

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

            self.cancelAudioVolumeRamp()
            self.audioPreviewOutput.volume = 0
            self.resetAudioStreamState()

            if self.audioSession.isRunning {
                self.audioSession.stopRunning()
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

        let latest =
            requestNumber ==
            latestVideoRequestNumber

        videoRequestLock.unlock()

        return latest
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

        let latest =
            requestNumber ==
            latestAudioRequestNumber

        audioRequestLock.unlock()

        return latest
    }

    // MARK: - Output Delegates

    func captureOutput(
        _ output:
            AVCaptureOutput,
        didOutput sampleBuffer:
            CMSampleBuffer,
        from connection:
            AVCaptureConnection
    ) {
        if output === videoOutput {
            handleVideoSampleBuffer(
                sampleBuffer
            )

            return
        }

        if output === audioDataOutput {
            handleAudioSampleBuffer(
                sampleBuffer
            )
        }
    }

    private func handleVideoSampleBuffer(
        _ sampleBuffer:
            CMSampleBuffer
    ) {
        guard CMSampleBufferDataIsReady(
            sampleBuffer
        ) else {
            return
        }

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        videoFrameStateLock.lock()

        guard currentUptime >=
                acceptVideoFramesAfterUptime else {

            videoFrameStateLock.unlock()
            return
        }

        let shouldPublish =
            !hasReceivedCurrentVideoFrame

        if shouldPublish {
            hasReceivedCurrentVideoFrame =
                true
        }

        videoFrameStateLock.unlock()

        guard shouldPublish else {
            return
        }

        DispatchQueue.main.async {
            [weak self] in

            self?.isReceivingVideo =
                true

            self?.errorMessage =
                nil
        }
    }

    private func resetVideoFrameState() {
        videoFrameStateLock.lock()

        hasReceivedCurrentVideoFrame =
            false

        acceptVideoFramesAfterUptime =
            0

        videoFrameStateLock.unlock()
    }

    private func prepareForNewVideoFrames(
        ignoreDuration:
            TimeInterval
    ) {
        videoFrameStateLock.lock()

        hasReceivedCurrentVideoFrame =
            false

        acceptVideoFramesAfterUptime =
            ProcessInfo
                .processInfo
                .systemUptime +
            ignoreDuration

        videoFrameStateLock.unlock()
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
