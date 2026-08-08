import AVFoundation
import Combine
import CoreVideo
import Foundation

/// Plays a user-selected gameplay recording and forwards its decoded video
/// frames through the same analyzers used by the live capture-card source.
final class VideoFilePlaybackController:
    NSObject,
    ObservableObject {

    let player =
        AVPlayer()

    @Published private(set)
    var loadedFileName:
        String?

    @Published private(set)
    var isReady =
        false

    @Published private(set)
    var isPlaying =
        false

    @Published private(set)
    var currentTime =
        0.0

    @Published private(set)
    var duration =
        0.0

    @Published private(set)
    var errorMessage:
        String?

    @Published private(set)
    var formatWarning:
        String?

    @Published private(set)
    var loopsPlayback =
        true

    var hasLoadedVideo:
        Bool {

        loadedFileName != nil
    }

    private let frameAnalyzer:
        FrameAnalyzer

    private let minimapDatasetRecorder:
        MinimapDatasetRecorder

    private var videoOutput:
        AVPlayerItemVideoOutput?

    private var timeObserverToken:
        Any?

    private var itemStatusObservation:
        NSKeyValueObservation?

    private var endObserverToken:
        NSObjectProtocol?

    private var failureObserverToken:
        NSObjectProtocol?

    private var securityScopedURL:
        URL?

    private var desiredVolume:
        Float = 0.80

    private var desiredMuted =
        false

    private var hasCheckedFrameFormat =
        false

    init(
        frameAnalyzer:
            FrameAnalyzer,
        minimapDatasetRecorder:
            MinimapDatasetRecorder
    ) {
        self.frameAnalyzer =
            frameAnalyzer

        self.minimapDatasetRecorder =
            minimapDatasetRecorder

        super.init()

        player.actionAtItemEnd =
            .pause

        installTimeObserver()
        applyAudioSettings()
    }

    deinit {
        player.pause()

        if let timeObserverToken {
            player.removeTimeObserver(
                timeObserverToken
            )
        }

        removeItemObservers()
        stopSecurityScopedAccess()
    }

    // MARK: - Load and Unload

    func load(
        url:
            URL
    ) {
        unload(
            resetAnalyzer:
                false
        )

        errorMessage =
            nil

        formatWarning =
            nil

        hasCheckedFrameFormat =
            false

        loadedFileName =
            url.lastPathComponent

        isReady =
            false

        isPlaying =
            false

        currentTime =
            0

        duration =
            0

        if url.startAccessingSecurityScopedResource() {
            securityScopedURL =
                url
        }

        frameAnalyzer.reset()

        let output =
            AVPlayerItemVideoOutput(
                pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(
                            kCVPixelFormatType_32BGRA
                        )
                ]
            )

        let item =
            AVPlayerItem(
                url:
                    url
            )

        item.add(
            output
        )

        videoOutput =
            output

        installItemObservers(
            for:
                item
        )

        player.replaceCurrentItem(
            with:
                item
        )

        applyAudioSettings()
    }

    func unload() {
        unload(
            resetAnalyzer:
                true
        )
    }

    private func unload(
        resetAnalyzer:
            Bool
    ) {
        player.pause()

        removeItemObservers()

        if let currentItem =
            player.currentItem,
           let videoOutput {

            currentItem.remove(
                videoOutput
            )
        }

        player.replaceCurrentItem(
            with:
                nil
        )

        videoOutput =
            nil

        stopSecurityScopedAccess()

        loadedFileName =
            nil

        isReady =
            false

        isPlaying =
            false

        currentTime =
            0

        duration =
            0

        errorMessage =
            nil

        formatWarning =
            nil

        hasCheckedFrameFormat =
            false

        if resetAnalyzer {
            frameAnalyzer.reset()
        }
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        guard isReady else {
            return
        }

        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard isReady else {
            return
        }

        if duration > 0,
           currentTime >=
            duration - 0.05 {

            seek(
                to:
                    0,
                resumeAfterSeek:
                    true
            )

            return
        }

        player.play()

        isPlaying =
            true
    }

    func pause() {
        player.pause()

        isPlaying =
            false
    }

    func restart() {
        seek(
            to:
                0,
            resumeAfterSeek:
                true
        )
    }

    func skip(
        by seconds:
            Double
    ) {
        seek(
            to:
                currentTime +
                seconds,
            resumeAfterSeek:
                isPlaying
        )
    }

    func seek(
        to seconds:
            Double
    ) {
        seek(
            to:
                seconds,
            resumeAfterSeek:
                isPlaying
        )
    }

    func toggleLooping() {
        loopsPlayback.toggle()
    }

    func setAudio(
        volume:
            Double,
        muted:
            Bool
    ) {
        desiredVolume =
            Float(
                min(
                    max(
                        volume,
                        0
                    ),
                    1
                )
            )

        desiredMuted =
            muted

        applyAudioSettings()
    }

    private func seek(
        to seconds:
            Double,
        resumeAfterSeek:
            Bool
    ) {
        guard player.currentItem != nil else {
            return
        }

        let maximumTime =
            duration > 0
            ? duration
            : max(
                seconds,
                0
            )

        let safeTime =
            min(
                max(
                    seconds,
                    0
                ),
                maximumTime
            )

        let targetTime =
            CMTime(
                seconds:
                    safeTime,
                preferredTimescale:
                    600
            )

        player.seek(
            to:
                targetTime,
            toleranceBefore:
                .zero,
            toleranceAfter:
                .zero
        ) {
            [weak self] finished in

            guard let self,
                  finished else {
                return
            }

            DispatchQueue.main.async {
                self.currentTime =
                    safeTime

                self.processFrame(
                    at:
                        targetTime
                )

                if resumeAfterSeek {
                    self.player.play()

                    self.isPlaying =
                        true
                } else {
                    self.player.pause()

                    self.isPlaying =
                        false
                }
            }
        }
    }

    private func applyAudioSettings() {
        player.volume =
            desiredVolume

        player.isMuted =
            desiredMuted
    }

    // MARK: - Frame Delivery

    private func installTimeObserver() {
        let interval =
            CMTime(
                value:
                    1,
                timescale:
                    30
            )

        timeObserverToken =
            player.addPeriodicTimeObserver(
                forInterval:
                    interval,
                queue:
                    .main
            ) {
                [weak self] itemTime in

                guard let self,
                      self.hasLoadedVideo else {
                    return
                }

                self.updatePlaybackTime(
                    itemTime
                )

                self.processFrame(
                    at:
                        itemTime
                )
            }
    }

    private func processFrame(
        at itemTime:
            CMTime
    ) {
        guard let videoOutput,
              videoOutput
                .hasNewPixelBuffer(
                    forItemTime:
                        itemTime
                ),
              let pixelBuffer =
                videoOutput
                    .copyPixelBuffer(
                        forItemTime:
                            itemTime,
                        itemTimeForDisplay:
                            nil
                    ) else {

            return
        }

        checkFrameFormatIfNeeded(
            pixelBuffer
        )

        frameAnalyzer.receive(
            pixelBuffer
        )

        minimapDatasetRecorder.receive(
            pixelBuffer
        )
    }

    private func updatePlaybackTime(
        _ itemTime:
            CMTime
    ) {
        let seconds =
            itemTime.seconds

        if seconds.isFinite {
            currentTime =
                max(
                    seconds,
                    0
                )
        }

        updateDuration()
    }

    private func updateDuration() {
        guard let item =
                player.currentItem else {
            return
        }

        let itemDuration =
            item.duration.seconds

        guard itemDuration.isFinite,
              itemDuration > 0 else {
            return
        }

        duration =
            itemDuration
    }

    private func checkFrameFormatIfNeeded(
        _ pixelBuffer:
            CVPixelBuffer
    ) {
        guard !hasCheckedFrameFormat else {
            return
        }

        hasCheckedFrameFormat =
            true

        let width =
            CVPixelBufferGetWidth(
                pixelBuffer
            )

        let height =
            CVPixelBufferGetHeight(
                pixelBuffer
            )

        guard width > 0,
              height > 0 else {
            return
        }

        let aspectRatio =
            Double(width) /
            Double(height)

        let expectedAspectRatio =
            16.0 /
            9.0

        if abs(
            aspectRatio -
            expectedAspectRatio
        ) > 0.04 {

            formatWarning =
                "This video is not 16:9. The fixed Motorfest HUD boxes may miss the minimap. Use an uncropped 16:9 recording."
        } else {
            formatWarning =
                nil
        }
    }

    // MARK: - Item State

    private func installItemObservers(
        for item:
            AVPlayerItem
    ) {
        itemStatusObservation =
            item.observe(
                \.status,
                options: [
                    .initial,
                    .new
                ]
            ) {
                [weak self] observedItem,
                _ in

                DispatchQueue.main.async {
                    self?.handleItemStatus(
                        observedItem
                    )
                }
            }

        endObserverToken =
            NotificationCenter.default
                .addObserver(
                    forName:
                        .AVPlayerItemDidPlayToEndTime,
                    object:
                        item,
                    queue:
                        .main
                ) {
                    [weak self] _ in

                    self?.handlePlaybackEnded()
                }

        failureObserverToken =
            NotificationCenter.default
                .addObserver(
                    forName:
                        .AVPlayerItemFailedToPlayToEndTime,
                    object:
                        item,
                    queue:
                        .main
                ) {
                    [weak self] notification in

                    let error =
                        notification.userInfo?[
                            AVPlayerItemFailedToPlayToEndTimeErrorKey
                        ] as? Error

                    self?.publishFailure(
                        error?.localizedDescription ??
                        "The selected video could not finish playing."
                    )
                }
    }

    private func removeItemObservers() {
        itemStatusObservation?
            .invalidate()

        itemStatusObservation =
            nil

        if let endObserverToken {
            NotificationCenter.default
                .removeObserver(
                    endObserverToken
                )

            self.endObserverToken =
                nil
        }

        if let failureObserverToken {
            NotificationCenter.default
                .removeObserver(
                    failureObserverToken
                )

            self.failureObserverToken =
                nil
        }
    }

    private func handleItemStatus(
        _ item:
            AVPlayerItem
    ) {
        guard item ===
                player.currentItem else {
            return
        }

        switch item.status {
        case .readyToPlay:
            isReady =
                true

            errorMessage =
                nil

            updateDuration()

            player.play()

            isPlaying =
                true

        case .failed:
            publishFailure(
                item.error?
                    .localizedDescription ??
                "The selected file is not a playable video."
            )

        case .unknown:
            isReady =
                false

        @unknown default:
            isReady =
                false
        }
    }

    private func handlePlaybackEnded() {
        isPlaying =
            false

        currentTime =
            duration

        guard loopsPlayback else {
            return
        }

        seek(
            to:
                0,
            resumeAfterSeek:
                true
        )
    }

    private func publishFailure(
        _ message:
            String
    ) {
        player.pause()

        isReady =
            false

        isPlaying =
            false

        errorMessage =
            message
    }

    private func stopSecurityScopedAccess() {
        securityScopedURL?
            .stopAccessingSecurityScopedResource()

        securityScopedURL =
            nil
    }
}
