import Foundation

nonisolated enum ModularShadowFactory {
    static func makeFromArguments() -> ShadowCapturePipeline? {
        let args = CommandLine.arguments
        func option(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        // No work, files or extra capture permissions in an ordinary app/review launch.
        guard let root = option("--shadow-log-root"), root.hasPrefix("/") else { return nil }
        var config = ShadowRunConfiguration()
        config.hudProfile = option("--shadow-hud-profile") ?? "unconfirmed"
        config.speedUnit = option("--shadow-speed-unit")
        config.carSetupID = option("--shadow-car-setup") ?? "unconfirmed"
        config.recordHUDImages = args.contains("--shadow-record-hud")
        guard ["unconfirmed", "reference-video2-v1"].contains(config.hudProfile),
              config.speedUnit == nil || ["km/h", "mph"].contains(config.speedUnit!) else {
            NSLog("Shadow recording disabled: unknown HUD profile or speed unit."); return nil
        }
        do {
            let recorder = try ShadowSessionRecorder(root: URL(fileURLWithPath: root), configuration: config)
            let modules = ModularVideoModules(profileID: config.hudProfile)
            let unit = config.speedUnit
            let pipeline = ShadowCapturePipeline(configuration: config, sink: recorder,
                resetModules: { modules.reset() }, analyze: { pixels, ticket, startedAt in
                    modules.analyze(pixelBuffer: pixels, capturedAt: ticket.receivedAt, startedAt: startedAt,
                        session: ticket.generation, confirmedSpeedUnit: unit)
                })
            NSLog("Shadow evidence only; no cues. Recording: %@", recorder.directory.path)
            return pipeline
        } catch {
            NSLog("Shadow recording unavailable: %@. Existing coach is unchanged.", error.localizedDescription)
            return nil
        }
    }
}
