import SwiftUI

@main
struct Racing_TrainerApp: App {
    @StateObject private var modelReview = ModelReviewStore()

    @StateObject private var captureDevices =
        CaptureDeviceManager()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--model-review") {
                ModelReviewView(store: modelReview)
            } else if CommandLine.arguments.contains("--corner-replay-lab") {
                CornerReplayWorkspace()
            } else {
                ContentView(
                    captureDevices: captureDevices, modelReview: modelReview
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
        .commands { ModelReviewCommands(store: modelReview) }

        Window("Model Review", id: "model-review") {
            ModelReviewView(store: modelReview)
        }
        .defaultSize(width: 1360, height: 900)

        Window("Corner Replay Lab", id: "corner-replay-lab") {
            CornerReplayWorkspace()
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

/// The comparison lab owns its players only while its workspace exists.
private struct CornerReplayWorkspace: View {
    @StateObject private var store = CornerReplayLabStore()
    var body: some View { CornerReplayLab(store: store) }
}
