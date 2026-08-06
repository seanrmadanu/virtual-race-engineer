import SwiftUI

@main
struct Racing_TrainerApp: App {
    @StateObject private var captureDevices =
        CaptureDeviceManager()

    var body: some Scene {
        WindowGroup {
            ContentView(
                captureDevices: captureDevices
            )
            .frame(
                minWidth: 1000,
                minHeight: 650
            )
        }
        .defaultSize(
            width: 1280,
            height: 760
        )

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
