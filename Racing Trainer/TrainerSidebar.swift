import SwiftUI

/// Practice controls do not subscribe to the analyzer's high-frequency updates.
/// Expensive diagnostics are constructed only when their separate sheet opens.
struct TrainerSidebar: View {
    @Binding var gameVolume: Double
    @Binding var gameMuted: Bool
    let gameAudioAvailable: Bool
    let gameAudioStatus: String
    var onReviewTurns: () -> Void
    var onReviewTechnique: () -> Void
    var onDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Practice", systemImage: "steeringwheel").font(.title2.weight(.semibold))
                Text("Follow the turn guidance over your gameplay.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The wheel illustrates direction. It is not a calibrated steering angle.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Review Your Driving").font(.headline)
                Button(action: onReviewTurns) {
                    Label("Turns & Timing", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                Button(action: onReviewTechnique) {
                    Label("Corner Technique", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Text("Review approach, entry, in-bend and exit estimates in recorded video.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Divider()
            AudioChannelRow(title: "Game Audio", statusText: gameAudioStatus,
                            volume: $gameVolume, isMuted: $gameMuted, controlsEnabled: gameAudioAvailable)
            Divider()
            Button("Input Diagnostics…", systemImage: "wrench.and.screwdriver", action: onDiagnostics)
                .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Audio Channel

struct AudioChannelRow: View {
    let title:
        String

    let statusText:
        String

    @Binding var volume:
        Double

    @Binding var isMuted:
        Bool

    let controlsEnabled:
        Bool

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Text(title)
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )

            Text(statusText)
                .font(.caption)
                .foregroundStyle(
                    controlsEnabled
                    ? .secondary
                    : .tertiary
                )
                .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    isMuted.toggle()
                } label: {
                    Image(
                        systemName:
                            isMuted
                            ? "speaker.slash.fill"
                            : "speaker.wave.2.fill"
                    )
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute \(title)" : "Mute \(title)")
                .disabled(
                    !controlsEnabled
                )
                .help(
                    isMuted
                    ? "Unmute \(title)"
                    : "Mute \(title)"
                )

                Slider(
                    value:
                        $volume,
                    in:
                        0...1
                )
                .accessibilityLabel("\(title) volume")
                .disabled(
                    isMuted ||
                    !controlsEnabled
                )

                Text(
                    "\(Int(volume * 100))%"
                )
                .font(
                    .system(
                        size: 12,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    .secondary
                )
                .frame(
                    width: 38,
                    alignment: .trailing
                )
            }
        }
    }
}
