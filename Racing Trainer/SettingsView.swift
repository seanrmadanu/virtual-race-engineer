import SwiftUI
import AppKit
import AVFoundation
import Combine

struct SettingsView: View {
    @ObservedObject var captureDevices:
        CaptureDeviceManager

    @State private var selectedVideoSourceID:
        String

    @State private var selectedAudioSourceID:
        String

    @State private var selectedAudioOutputUID:
        String

    init(
        captureDevices:
            CaptureDeviceManager
    ) {
        self.captureDevices =
            captureDevices

        _selectedVideoSourceID =
            State(
                initialValue:
                    captureDevices
                        .selectedDeviceID
            )

        _selectedAudioSourceID =
            State(
                initialValue:
                    captureDevices
                        .selectedAudioDeviceID
            )

        _selectedAudioOutputUID =
            State(
                initialValue:
                    captureDevices
                        .selectedAudioOutputDeviceUID
            )
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 20
        ) {
            Text("Capture Settings")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Video") {
                VStack(
                    alignment: .leading,
                    spacing: 14
                ) {
                    Picker(
                        "Video Source",
                        selection:
                            $selectedVideoSourceID
                    ) {
                        Text(
                            "Automatic — Hardware Preferred"
                        )
                        .tag("")

                        ForEach(
                            captureDevices
                                .videoDevices,
                            id: \.uniqueID
                        ) { device in
                            Text(
                                captureDevices
                                    .displayName(
                                        for: device
                                    )
                            )
                            .tag(
                                device.uniqueID
                            )
                        }
                    }

                    if captureDevices
                        .cameraPermissionDenied {

                        Text(
                            "Camera access is denied. Enable Racing Trainer in System Settings → Privacy & Security → Camera."
                        )
                        .font(.caption)
                        .foregroundStyle(.red)

                    } else if captureDevices
                        .videoDevices.isEmpty {

                        Text(
                            "No external video sources detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )

                    } else {
                        Text(
                            "\(captureDevices.videoDevices.count) video source(s) detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }
                }
                .padding(8)
            }

            GroupBox("Game Audio") {
                VStack(
                    alignment: .leading,
                    spacing: 14
                ) {
                    Picker(
                        "Audio Input",
                        selection:
                            $selectedAudioSourceID
                    ) {
                        Text(
                            "Automatic — Capture Card Audio"
                        )
                        .tag("")

                        ForEach(
                            captureDevices
                                .audioDevices,
                            id: \.uniqueID
                        ) { device in
                            Text(
                                captureDevices
                                    .displayName(
                                        for: device
                                    )
                            )
                            .tag(
                                device.uniqueID
                            )
                        }
                    }

                    if captureDevices
                        .audioPermissionDenied {

                        Text(
                            "Audio access is denied. Enable Racing Trainer in System Settings → Privacy & Security → Microphone."
                        )
                        .font(.caption)
                        .foregroundStyle(.red)

                    } else if captureDevices
                        .audioDevices.isEmpty {

                        Text(
                            "No audio input devices detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )

                    } else {
                        Text(
                            "\(captureDevices.audioDevices.count) audio input source(s) detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    if selectedAudioSourceID.isEmpty,
                       let automaticAudioName =
                        captureDevices
                            .activeAudioSourceName {

                        Text(
                            "Automatic input currently uses: \(automaticAudioName)"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    Divider()

                    Picker(
                        "Audio Output",
                        selection:
                            $selectedAudioOutputUID
                    ) {
                        if let defaultOutputName =
                            captureDevices
                                .defaultAudioOutputDevice?
                                .name {

                            Text(
                                "System Default — \(defaultOutputName)"
                            )
                            .tag("")
                        } else {
                            Text(
                                "System Default"
                            )
                            .tag("")
                        }

                        Divider()

                        ForEach(
                            captureDevices
                                .audioOutputDevices
                        ) { outputDevice in
                            Text(
                                outputDevice.name
                            )
                            .tag(
                                outputDevice.uniqueID
                            )
                        }
                    }

                    if captureDevices
                        .audioOutputDevices
                        .isEmpty {

                        Text(
                            "No audio output devices detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    } else {
                        Text(
                            "\(captureDevices.audioOutputDevices.count) audio output device(s) detected."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    Text(
                        "Current output: \(captureDevices.activeAudioOutputName)"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        .secondary
                    )
                }
                .padding(8)
            }

            Text(
                "Video, audio input, and audio output are controlled separately. Changing the speakers or headphones will not restart the video feed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Refresh Devices") {
                    captureDevices
                        .refreshDevicesWithRetry()
                }

                Spacer()

                Button("Done") {
                    NSApp.keyWindow?
                        .performClose(nil)
                }
                .keyboardShortcut(
                    .defaultAction
                )
            }
        }
        .padding(24)
        .background(
            SettingsWindowBehavior()
        )

        .onAppear {
            captureDevices
                .refreshAudioOutputDevices()
        }

        .onChange(
            of: selectedVideoSourceID
        ) { _, newDeviceID in
            captureDevices.selectDevice(
                id: newDeviceID
            )
        }

        .onChange(
            of: selectedAudioSourceID
        ) { _, newDeviceID in
            captureDevices.selectAudioDevice(
                id: newDeviceID
            )
        }

        .onChange(
            of: selectedAudioOutputUID
        ) { _, newOutputUID in
            captureDevices
                .selectAudioOutputDevice(
                    uniqueID: newOutputUID
                )
        }

        .onReceive(
            captureDevices
                .$selectedDeviceID
                .removeDuplicates()
        ) { managerDeviceID in
            guard selectedVideoSourceID !=
                    managerDeviceID else {
                return
            }

            selectedVideoSourceID =
                managerDeviceID
        }

        .onReceive(
            captureDevices
                .$selectedAudioDeviceID
                .removeDuplicates()
        ) { managerDeviceID in
            guard selectedAudioSourceID !=
                    managerDeviceID else {
                return
            }

            selectedAudioSourceID =
                managerDeviceID
        }

        .onReceive(
            captureDevices
                .$selectedAudioOutputDeviceUID
                .removeDuplicates()
        ) { managerOutputUID in
            guard selectedAudioOutputUID !=
                    managerOutputUID else {
                return
            }

            selectedAudioOutputUID =
                managerOutputUID
        }
    }
}
