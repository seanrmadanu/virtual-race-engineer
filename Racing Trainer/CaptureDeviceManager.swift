import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation

struct AudioOutputDevice:
    Identifiable,
    Equatable {

    let audioObjectID:
        AudioObjectID

    let uniqueID:
        String

    let name:
        String

    var id: String {
        uniqueID
    }
}

final class CaptureDeviceManager:
    ObservableObject {

    // Empty means Automatic — Hardware Preferred.
    @Published private(set)
    var selectedDeviceID = ""

    // Empty means Automatic — Capture Card Audio.
    @Published private(set)
    var selectedAudioDeviceID = ""

    // Empty means System Default Output.
    @Published private(set)
    var selectedAudioOutputDeviceUID = ""

    @Published private(set)
    var activeDeviceID: String?

    @Published private(set)
    var activeAudioDeviceID: String?

    @Published private(set)
    var videoDevices:
        [AVCaptureDevice] = []

    @Published private(set)
    var audioDevices:
        [AVCaptureDevice] = []

    @Published private(set)
    var audioOutputDevices:
        [AudioOutputDevice] = []

    @Published private(set)
    var defaultAudioOutputDeviceUID:
        String?

    @Published private(set)
    var cameraPermissionDenied = false

    @Published private(set)
    var audioPermissionDenied = false

    private let videoDiscoverySession:
        AVCaptureDevice.DiscoverySession

    private let audioDiscoverySession:
        AVCaptureDevice.DiscoverySession

    private var videoDeviceObservation:
        NSKeyValueObservation?

    private var audioDeviceObservation:
        NSKeyValueObservation?

    private var cancellables =
        Set<AnyCancellable>()

    /*
     Each new refresh request invalidates the delayed
     refresh attempts created by the previous request.
     */
    private var refreshGeneration = 0

    init() {
        let videoDeviceTypes:
            [AVCaptureDevice.DeviceType]

        let audioDeviceTypes:
            [AVCaptureDevice.DeviceType]

        if #available(macOS 14.0, *) {
            videoDeviceTypes = [
                .external
            ]

            audioDeviceTypes = [
                .microphone,
                .external
            ]
        } else {
            videoDeviceTypes = [
                .externalUnknown
            ]

            audioDeviceTypes = [
                .builtInMicrophone,
                .externalUnknown
            ]
        }

        videoDiscoverySession =
            AVCaptureDevice.DiscoverySession(
                deviceTypes:
                    videoDeviceTypes,
                mediaType:
                    .video,
                position:
                    .unspecified
            )

        audioDiscoverySession =
            AVCaptureDevice.DiscoverySession(
                deviceTypes:
                    audioDeviceTypes,
                mediaType:
                    .audio,
                position:
                    .unspecified
            )

        observeDiscoverySessions()
        observeDeviceConnections()
        observeApplicationActivation()
    }

    // MARK: - Start

    func start() {
        refreshAudioOutputDevices()

        requestVideoPermission()
        requestAudioPermission()
    }

    // MARK: - Permissions

    private func requestVideoPermission() {
        switch AVCaptureDevice
            .authorizationStatus(
                for: .video
            ) {

        case .authorized:
            cameraPermissionDenied = false
            refreshDevicesWithRetry()

        case .notDetermined:
            AVCaptureDevice.requestAccess(
                for: .video
            ) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }

                    self.cameraPermissionDenied =
                        !granted

                    if granted {
                        self.refreshDevicesWithRetry()
                    } else {
                        self.videoDevices = []
                        self.updateActiveDevices()
                    }
                }
            }

        case .denied, .restricted:
            cameraPermissionDenied = true
            videoDevices = []
            updateActiveDevices()

        @unknown default:
            cameraPermissionDenied = true
            videoDevices = []
            updateActiveDevices()
        }
    }

    private func requestAudioPermission() {
        switch AVCaptureDevice
            .authorizationStatus(
                for: .audio
            ) {

        case .authorized:
            audioPermissionDenied = false
            refreshDevicesWithRetry()

        case .notDetermined:
            AVCaptureDevice.requestAccess(
                for: .audio
            ) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }

                    self.audioPermissionDenied =
                        !granted

                    if granted {
                        self.refreshDevicesWithRetry()
                    } else {
                        self.audioDevices = []
                        self.updateActiveDevices()
                    }
                }
            }

        case .denied, .restricted:
            audioPermissionDenied = true
            audioDevices = []
            updateActiveDevices()

        @unknown default:
            audioPermissionDenied = true
            audioDevices = []
            updateActiveDevices()
        }
    }

    // MARK: - User Selection

    func selectDevice(
        id: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?.selectDevice(
                    id: id
                )
            }

            return
        }

        guard selectedDeviceID != id else {
            return
        }

        selectedDeviceID = id

        updateActiveDevices()
    }

    func selectAudioDevice(
        id: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?.selectAudioDevice(
                    id: id
                )
            }

            return
        }

        guard selectedAudioDeviceID != id else {
            return
        }

        selectedAudioDeviceID = id

        updateActiveDevices()
    }

    func selectAudioOutputDevice(
        uniqueID: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?
                    .selectAudioOutputDevice(
                        uniqueID:
                            uniqueID
                    )
            }

            return
        }

        guard selectedAudioOutputDeviceUID !=
                uniqueID else {
            return
        }

        if uniqueID.isEmpty {
            selectedAudioOutputDeviceUID = ""
            return
        }

        let deviceExists =
            audioOutputDevices.contains {
                $0.uniqueID == uniqueID
            }

        guard deviceExists else {
            selectedAudioOutputDeviceUID = ""
            return
        }

        selectedAudioOutputDeviceUID =
            uniqueID
    }

    // MARK: - Device Observation

    private func observeDiscoverySessions() {
        videoDeviceObservation =
            videoDiscoverySession.observe(
                \.devices,
                options: [
                    .initial,
                    .new
                ]
            ) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?
                        .refreshDevicesWithRetry()
                }
            }

        audioDeviceObservation =
            audioDiscoverySession.observe(
                \.devices,
                options: [
                    .initial,
                    .new
                ]
            ) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?
                        .refreshDevicesWithRetry()
                }
            }
    }

    private func observeDeviceConnections() {
        NotificationCenter.default.publisher(
            for:
                AVCaptureDevice
                .wasConnectedNotification
        )
        .receive(
            on: DispatchQueue.main
        )
        .sink { [weak self] _ in
            self?.refreshDevicesWithRetry()
        }
        .store(
            in: &cancellables
        )

        NotificationCenter.default.publisher(
            for:
                AVCaptureDevice
                .wasDisconnectedNotification
        )
        .receive(
            on: DispatchQueue.main
        )
        .sink {
            [weak self] notification in

            guard let self else {
                return
            }

            if let disconnectedDevice =
                notification.object
                as? AVCaptureDevice {

                if disconnectedDevice.uniqueID ==
                    self.selectedDeviceID {

                    self.selectedDeviceID = ""
                }

                if disconnectedDevice.uniqueID ==
                    self.selectedAudioDeviceID {

                    self.selectedAudioDeviceID = ""
                }
            }

            self.refreshDevicesWithRetry()
        }
        .store(
            in: &cancellables
        )
    }

    private func observeApplicationActivation() {
        NotificationCenter.default.publisher(
            for:
                NSApplication
                .didBecomeActiveNotification
        )
        .receive(
            on: DispatchQueue.main
        )
        .sink { [weak self] _ in
            self?.refreshDevicesWithRetry()
        }
        .store(
            in: &cancellables
        )
    }

    // MARK: - Refresh

    func refreshDevicesWithRetry() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?.refreshDevicesWithRetry()
            }

            return
        }

        refreshGeneration += 1

        let generation =
            refreshGeneration

        /*
         Some USB capture cards expose their video
         endpoint first and their audio endpoint later.
         Continue checking for several seconds.
         */
        let retryDelays:
            [TimeInterval] = [
                0,
                0.25,
                0.75,
                1.50,
                3.00,
                5.00
            ]

        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(
                deadline:
                    .now() + delay
            ) { [weak self] in
                guard let self,
                      self.refreshGeneration ==
                        generation else {
                    return
                }

                self.refreshDevices()
            }
        }
    }

    func refreshDevices() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?.refreshDevices()
            }

            return
        }

        refreshVideoDevices()
        refreshAudioInputDevices()
        refreshAudioOutputDevices()

        updateActiveDevices()
    }

    private func refreshVideoDevices() {
        let refreshedDevices =
            videoDiscoverySession.devices
                .filter { device in
                    guard device.isConnected else {
                        return false
                    }

                    if #available(
                        macOS 13.0,
                        *
                    ),
                    device.isContinuityCamera {

                        return false
                    }

                    return device.hasMediaType(
                        .video
                    )
                }
                .sorted(
                    by:
                        videoDeviceShouldComeFirst
                )

        let oldIDs =
            videoDevices.map(
                \.uniqueID
            )

        let newIDs =
            refreshedDevices.map(
                \.uniqueID
            )

        if oldIDs != newIDs {
            videoDevices =
                refreshedDevices
        }
    }

    private func refreshAudioInputDevices() {
        let refreshedDevices =
            audioDiscoverySession.devices
                .filter { device in
                    device.isConnected &&
                    device.hasMediaType(
                        .audio
                    )
                }
                .sorted(
                    by:
                        audioDeviceShouldComeFirst
                )

        let oldIDs =
            audioDevices.map(
                \.uniqueID
            )

        let newIDs =
            refreshedDevices.map(
                \.uniqueID
            )

        if oldIDs != newIDs {
            audioDevices =
                refreshedDevices
        }
    }

    // MARK: - Audio Outputs

    func refreshAudioOutputDevices() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                [weak self] in

                self?
                    .refreshAudioOutputDevices()
            }

            return
        }

        let deviceIDs =
            systemAudioDeviceIDs()

        let refreshedDevices =
            deviceIDs.compactMap {
                deviceID
                    -> AudioOutputDevice? in

                guard audioDeviceHasOutput(
                    deviceID
                ) else {
                    return nil
                }

                guard let uniqueID =
                        audioStringProperty(
                            objectID:
                                deviceID,
                            selector:
                                kAudioDevicePropertyDeviceUID
                        ),
                      !uniqueID.isEmpty else {
                    return nil
                }

                let name =
                    audioStringProperty(
                        objectID:
                            deviceID,
                        selector:
                            kAudioObjectPropertyName
                    ) ??
                    "Unnamed Audio Output"

                return AudioOutputDevice(
                    audioObjectID:
                        deviceID,
                    uniqueID:
                        uniqueID,
                    name:
                        name
                )
            }
            .sorted { first, second in
                first.name
                    .localizedCaseInsensitiveCompare(
                        second.name
                    ) ==
                    .orderedAscending
            }

        if audioOutputDevices !=
            refreshedDevices {

            audioOutputDevices =
                refreshedDevices
        }

        let newDefaultUID =
            currentDefaultOutputDeviceUID()

        if defaultAudioOutputDeviceUID !=
            newDefaultUID {

            defaultAudioOutputDeviceUID =
                newDefaultUID
        }

        if !selectedAudioOutputDeviceUID
            .isEmpty {

            let selectedOutputStillExists =
                refreshedDevices.contains {
                    $0.uniqueID ==
                        selectedAudioOutputDeviceUID
                }

            if !selectedOutputStillExists {
                selectedAudioOutputDeviceUID = ""
            }
        }
    }

    private func systemAudioDeviceIDs()
        -> [AudioObjectID] {

        var address =
            AudioObjectPropertyAddress(
                mSelector:
                    kAudioHardwarePropertyDevices,
                mScope:
                    kAudioObjectPropertyScopeGlobal,
                mElement:
                    kAudioObjectPropertyElementMain
            )

        var dataSize:
            UInt32 = 0

        let sizeStatus =
            AudioObjectGetPropertyDataSize(
                AudioObjectID(
                    kAudioObjectSystemObject
                ),
                &address,
                0,
                nil,
                &dataSize
            )

        guard sizeStatus == noErr else {
            return []
        }

        let deviceCount =
            Int(dataSize) /
            MemoryLayout<
                AudioObjectID
            >.size

        guard deviceCount > 0 else {
            return []
        }

        var deviceIDs =
            [AudioObjectID](
                repeating: 0,
                count: deviceCount
            )

        let dataStatus =
            deviceIDs.withUnsafeMutableBytes {
                rawBuffer -> OSStatus in

                guard let baseAddress =
                        rawBuffer.baseAddress else {
                    return -1
                }

                return AudioObjectGetPropertyData(
                    AudioObjectID(
                        kAudioObjectSystemObject
                    ),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    baseAddress
                )
            }

        guard dataStatus == noErr else {
            return []
        }

        return deviceIDs
    }

    private func audioDeviceHasOutput(
        _ deviceID: AudioObjectID
    ) -> Bool {
        var address =
            AudioObjectPropertyAddress(
                mSelector:
                    kAudioDevicePropertyStreams,
                mScope:
                    kAudioDevicePropertyScopeOutput,
                mElement:
                    kAudioObjectPropertyElementMain
            )

        var dataSize:
            UInt32 = 0

        let status =
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            )

        guard status == noErr else {
            return false
        }

        return dataSize >=
            UInt32(
                MemoryLayout<
                    AudioStreamID
                >.size
            )
    }

    private func audioStringProperty(
        objectID: AudioObjectID,
        selector:
            AudioObjectPropertySelector
    ) -> String? {
        var address =
            AudioObjectPropertyAddress(
                mSelector:
                    selector,
                mScope:
                    kAudioObjectPropertyScopeGlobal,
                mElement:
                    kAudioObjectPropertyElementMain
            )

        var value:
            CFString?

        var dataSize =
            UInt32(
                MemoryLayout<
                    CFString?
                >.size
            )

        let status =
            withUnsafeMutablePointer(
                to: &value
            ) { pointer in
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &dataSize,
                    UnsafeMutableRawPointer(
                        pointer
                    )
                )
            }

        guard status == noErr,
              let value else {
            return nil
        }

        return value as String
    }

    private func currentDefaultOutputDeviceUID()
        -> String? {

        var address =
            AudioObjectPropertyAddress(
                mSelector:
                    kAudioHardwarePropertyDefaultOutputDevice,
                mScope:
                    kAudioObjectPropertyScopeGlobal,
                mElement:
                    kAudioObjectPropertyElementMain
            )

        var deviceID:
            AudioObjectID = 0

        var dataSize =
            UInt32(
                MemoryLayout<
                    AudioObjectID
                >.size
            )

        let status =
            AudioObjectGetPropertyData(
                AudioObjectID(
                    kAudioObjectSystemObject
                ),
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            )

        guard status == noErr,
              deviceID != 0 else {
            return nil
        }

        return audioStringProperty(
            objectID:
                deviceID,
            selector:
                kAudioDevicePropertyDeviceUID
        )
    }

    // MARK: - Output Information

    var selectedAudioOutputDevice:
        AudioOutputDevice? {

        guard !selectedAudioOutputDeviceUID
            .isEmpty else {
            return nil
        }

        return audioOutputDevices.first {
            $0.uniqueID ==
                selectedAudioOutputDeviceUID
        }
    }

    var defaultAudioOutputDevice:
        AudioOutputDevice? {

        guard let defaultUID =
                defaultAudioOutputDeviceUID else {
            return nil
        }

        return audioOutputDevices.first {
            $0.uniqueID == defaultUID
        }
    }

    var activeAudioOutputName:
        String {

        if let selectedAudioOutputDevice {
            return selectedAudioOutputDevice.name
        }

        if let defaultAudioOutputDevice {
            return defaultAudioOutputDevice.name
        }

        return "System Default"
    }

    // MARK: - Active Devices

    private func updateActiveDevices() {
        let newActiveVideoDeviceID:
            String?

        if selectedDeviceID.isEmpty {
            newActiveVideoDeviceID =
                videoDevices.first?
                    .uniqueID
        } else if device(
            withID: selectedDeviceID
        ) != nil {
            newActiveVideoDeviceID =
                selectedDeviceID
        } else {
            newActiveVideoDeviceID = nil
        }

        if activeDeviceID !=
            newActiveVideoDeviceID {

            activeDeviceID =
                newActiveVideoDeviceID
        }

        let newActiveAudioDeviceID:
            String?

        if selectedAudioDeviceID.isEmpty {
            newActiveAudioDeviceID =
                automaticAudioDevice()?
                    .uniqueID
        } else if audioDevice(
            withID:
                selectedAudioDeviceID
        ) != nil {
            newActiveAudioDeviceID =
                selectedAudioDeviceID
        } else {
            newActiveAudioDeviceID = nil
        }

        if activeAudioDeviceID !=
            newActiveAudioDeviceID {

            activeAudioDeviceID =
                newActiveAudioDeviceID
        }
    }

    func device(
        withID deviceID: String?
    ) -> AVCaptureDevice? {
        guard let deviceID else {
            return nil
        }

        /*
         Ask AVFoundation for a fresh device object first.
         This helps after USB device initialization or
         reconnection.
         */
        if let freshDevice =
            AVCaptureDevice(
                uniqueID: deviceID
            ),
           freshDevice.isConnected,
           freshDevice.hasMediaType(
                .video
           ) {

            return freshDevice
        }

        return videoDevices.first {
            $0.uniqueID == deviceID &&
            $0.isConnected
        }
    }

    func audioDevice(
        withID deviceID: String?
    ) -> AVCaptureDevice? {
        guard let deviceID else {
            return nil
        }

        /*
         Do not keep relying on an old capture-device
         object after the USB endpoint becomes ready.
         */
        if let freshDevice =
            AVCaptureDevice(
                uniqueID: deviceID
            ),
           freshDevice.isConnected,
           freshDevice.hasMediaType(
                .audio
           ) {

            return freshDevice
        }

        return audioDevices.first {
            $0.uniqueID == deviceID &&
            $0.isConnected
        }
    }

    var activeDevice:
        AVCaptureDevice? {

        device(
            withID:
                activeDeviceID
        )
    }

    var activeAudioDevice:
        AVCaptureDevice? {

        audioDevice(
            withID:
                activeAudioDeviceID
        )
    }

    var activeSourceName:
        String? {

        guard let activeDevice else {
            return nil
        }

        return displayName(
            for: activeDevice
        )
    }

    var activeAudioSourceName:
        String? {

        guard let activeAudioDevice else {
            return nil
        }

        return displayName(
            for: activeAudioDevice
        )
    }

    // MARK: - Automatic Audio Selection

    private func automaticAudioDevice()
        -> AVCaptureDevice? {

        let likelyGameAudioDevices =
            audioDevices.filter(
                isLikelyGameAudioDevice
            )

        guard !likelyGameAudioDevices
            .isEmpty else {
            return nil
        }

        guard let activeDevice else {
            return likelyGameAudioDevices
                .sorted(
                    by:
                        audioDeviceShouldComeFirst
                )
                .first
        }

        return likelyGameAudioDevices
            .sorted { first, second in
                let firstScore =
                    automaticAudioScore(
                        for: first,
                        matching:
                            activeDevice
                    )

                let secondScore =
                    automaticAudioScore(
                        for: second,
                        matching:
                            activeDevice
                    )

                if firstScore != secondScore {
                    return firstScore <
                        secondScore
                }

                return displayName(
                    for: first
                )
                .localizedCaseInsensitiveCompare(
                    displayName(
                        for: second
                    )
                ) ==
                    .orderedAscending
            }
            .first
    }

    private func automaticAudioScore(
        for audioDevice:
            AVCaptureDevice,
        matching videoDevice:
            AVCaptureDevice
    ) -> Int {
        var score =
            audioPriority(
                for: audioDevice
            )

        let audioTokens =
            matchingTokens(
                for: audioDevice
            )

        let videoTokens =
            matchingTokens(
                for: videoDevice
            )

        let sharedTokenCount =
            audioTokens
                .intersection(
                    videoTokens
                )
                .count

        score -=
            sharedTokenCount * 35

        let audioManufacturer =
            audioDevice.manufacturer
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()

        let videoManufacturer =
            videoDevice.manufacturer
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()

        if !audioManufacturer.isEmpty,
           audioManufacturer ==
            videoManufacturer {

            score -= 60
        }

        return score
    }

    private func matchingTokens(
        for device:
            AVCaptureDevice
    ) -> Set<String> {
        let text = [
            device.manufacturer,
            device.localizedName,
            device.modelID
        ]
        .joined(
            separator: " "
        )
        .lowercased()

        let ignoredWords:
            Set<String> = [
                "audio",
                "video",
                "device",
                "capture",
                "camera",
                "microphone",
                "external",
                "input",
                "output"
            ]

        let words =
            text.components(
                separatedBy:
                    CharacterSet
                    .alphanumerics
                    .inverted
            )
            .filter {
                $0.count >= 3 &&
                !ignoredWords.contains(
                    $0
                )
            }

        return Set(words)
    }

    private func isLikelyGameAudioDevice(
        _ device:
            AVCaptureDevice
    ) -> Bool {
        let text =
            searchableText(
                for: device
            )

        let virtualKeywords = [
            "blackhole",
            "loopback",
            "soundflower",
            "obs",
            "virtual",
            "aggregate"
        ]

        if virtualKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return false
        }

        let gameAudioKeywords = [
            "capture",
            "hdmi",
            "usb audio",
            "usb2 audio",
            "usb3 audio",
            "usb pnp",
            "digital audio",
            "ultrasemi",
            "elgato",
            "avermedia",
            "magewell",
            "cam link",
            "line in",
            "line-in"
        ]

        if gameAudioKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return true
        }

        return isExternalDevice(
            device
        )
    }

    // MARK: - Priority

    private func videoDeviceShouldComeFirst(
        _ firstDevice:
            AVCaptureDevice,
        _ secondDevice:
            AVCaptureDevice
    ) -> Bool {
        let firstPriority =
            videoPriority(
                for: firstDevice
            )

        let secondPriority =
            videoPriority(
                for: secondDevice
            )

        if firstPriority != secondPriority {
            return firstPriority <
                secondPriority
        }

        return displayName(
            for: firstDevice
        )
        .localizedCaseInsensitiveCompare(
            displayName(
                for: secondDevice
            )
        ) ==
            .orderedAscending
    }

    private func audioDeviceShouldComeFirst(
        _ firstDevice:
            AVCaptureDevice,
        _ secondDevice:
            AVCaptureDevice
    ) -> Bool {
        let firstPriority =
            audioPriority(
                for: firstDevice
            )

        let secondPriority =
            audioPriority(
                for: secondDevice
            )

        if firstPriority != secondPriority {
            return firstPriority <
                secondPriority
        }

        return displayName(
            for: firstDevice
        )
        .localizedCaseInsensitiveCompare(
            displayName(
                for: secondDevice
            )
        ) ==
            .orderedAscending
    }

    private func videoPriority(
        for device:
            AVCaptureDevice
    ) -> Int {
        let text =
            searchableText(
                for: device
            )

        let virtualKeywords = [
            "obs",
            "virtual camera",
            "virtualcam",
            "manycam",
            "camo",
            "snap camera",
            "mmhmm",
            "ndi video",
            "screen capture"
        ]

        if virtualKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return 2
        }

        let hardwareKeywords = [
            "capture",
            "hdmi",
            "usb video",
            "usb2 video",
            "usb3 video",
            "ultrasemi",
            "elgato",
            "avermedia",
            "magewell",
            "cam link"
        ]

        if hardwareKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return 0
        }

        return 1
    }

    private func audioPriority(
        for device:
            AVCaptureDevice
    ) -> Int {
        let text =
            searchableText(
                for: device
            )

        let captureKeywords = [
            "capture",
            "hdmi",
            "ultrasemi",
            "elgato",
            "avermedia",
            "magewell",
            "cam link"
        ]

        if captureKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return 0
        }

        let usbAudioKeywords = [
            "usb audio",
            "usb2 audio",
            "usb3 audio",
            "usb pnp",
            "digital audio",
            "line in",
            "line-in"
        ]

        if usbAudioKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return 1
        }

        if isExternalDevice(
            device
        ) {
            return 2
        }

        let virtualKeywords = [
            "blackhole",
            "loopback",
            "soundflower",
            "obs",
            "virtual",
            "aggregate"
        ]

        if virtualKeywords.contains(
            where: {
                text.contains($0)
            }
        ) {
            return 3
        }

        return 4
    }

    private func isExternalDevice(
        _ device:
            AVCaptureDevice
    ) -> Bool {
        if #available(
            macOS 14.0,
            *
        ) {
            return device.deviceType ==
                .external
        }

        return device.deviceType ==
            .externalUnknown
    }

    private func searchableText(
        for device:
            AVCaptureDevice
    ) -> String {
        [
            device.manufacturer,
            device.localizedName,
            device.modelID
        ]
        .joined(
            separator: " "
        )
        .lowercased()
    }

    // MARK: - Display Name

    func displayName(
        for device:
            AVCaptureDevice
    ) -> String {
        let deviceName =
            device.localizedName
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let manufacturer =
            device.manufacturer
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !manufacturer.isEmpty else {
            return deviceName
        }

        if deviceName
            .localizedCaseInsensitiveContains(
                manufacturer
            ) {

            return deviceName
        }

        return
            "\(manufacturer) \(deviceName)"
    }
}
