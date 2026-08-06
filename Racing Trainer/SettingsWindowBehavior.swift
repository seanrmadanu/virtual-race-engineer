import SwiftUI
import AppKit

struct SettingsWindowBehavior:
    NSViewRepresentable {

    func makeNSView(
        context: Context
    ) -> SettingsWindowObserverView {

        SettingsWindowObserverView(
            frame: .zero
        )
    }

    func updateNSView(
        _ nsView:
            SettingsWindowObserverView,
        context: Context
    ) {
        DispatchQueue.main.async {
            [weak nsView] in

            nsView?
                .configureWindowIfAvailable()
        }
    }

    static func dismantleNSView(
        _ nsView:
            SettingsWindowObserverView,
        coordinator: ()
    ) {
        nsView.detachFromParentWindow()
    }
}

final class SettingsWindowObserverView:
    NSView {

    private var notificationObservers:
        [NSObjectProtocol] = []

    override init(
        frame frameRect: NSRect
    ) {
        super.init(
            frame: frameRect
        )

        installObservers()
    }

    required init?(
        coder: NSCoder
    ) {
        super.init(
            coder: coder
        )

        installObservers()
    }

    deinit {
        for observer in
            notificationObservers {

            NotificationCenter
                .default
                .removeObserver(
                    observer
                )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            detachFromParentWindow()
            return
        }

        DispatchQueue.main.async {
            [weak self] in

            self?
                .configureWindowIfAvailable()
        }
    }

    func configureWindowIfAvailable() {
        guard let settingsWindow =
                window else {
            return
        }

        /*
         Allows the Settings window to appear
         inside Racing Trainer's fullscreen Space.
         */
        settingsWindow
            .collectionBehavior
            .remove(
                .canJoinAllSpaces
            )

        settingsWindow
            .collectionBehavior
            .insert(
                .moveToActiveSpace
            )

        settingsWindow
            .collectionBehavior
            .insert(
                .fullScreenAuxiliary
            )

        settingsWindow.isMovable = true

        guard let fullScreenWindow =
                NSApp.windows.first(
                    where: { candidate in

                        candidate !==
                            settingsWindow &&
                        candidate.isVisible &&
                        candidate.styleMask
                            .contains(
                                .fullScreen
                            )
                    }
                ) else {

            detachFromParentWindow()
            return
        }

        if settingsWindow.parent !==
            fullScreenWindow {

            settingsWindow.parent?
                .removeChildWindow(
                    settingsWindow
                )

            fullScreenWindow
                .addChildWindow(
                    settingsWindow,
                    ordered: .above
                )
        }

        settingsWindow
            .makeKeyAndOrderFront(nil)
    }

    func detachFromParentWindow() {
        guard let settingsWindow =
                window else {
            return
        }

        settingsWindow.parent?
            .removeChildWindow(
                settingsWindow
            )
    }

    private func installObservers() {
        let notificationCenter =
            NotificationCenter.default

        let enteredFullScreen =
            notificationCenter.addObserver(
                forName:
                    NSWindow
                    .didEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) {
                [weak self] _ in

                self?
                    .configureWindowIfAvailable()
            }

        let exitedFullScreen =
            notificationCenter.addObserver(
                forName:
                    NSWindow
                    .didExitFullScreenNotification,
                object: nil,
                queue: .main
            ) {
                [weak self] _ in

                self?
                    .configureWindowIfAvailable()
            }

        notificationObservers = [
            enteredFullScreen,
            exitedFullScreen
        ]
    }
}
