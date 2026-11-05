import SwiftUI

@main
struct Racing_TrainerApp: App {
    @StateObject private var replayLab = CornerReplayLabStore()

    @StateObject private var captureDevices =
        CaptureDeviceManager()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--corner-replay-lab") {
                CornerReplayLab(store: replayLab)
            } else {
                ContentView(
                    captureDevices: captureDevices
                )
                .frame(
                    minWidth: 1000,
                    minHeight: 650
                )
            }
        }
        .defaultSize(
            width: 1280,
            height: 760
        )

        Window("Reference Video Lab", id: "corner-replay-lab") {
            CornerReplayLab(store: replayLab)
        }
        .defaultSize(width: 1240, height: 920)

        Settings {
            SettingsView(
                captureDevices: captureDevices
            )
            .frame(
                width: 560,
                height: 580
            )
        }
    }
}
