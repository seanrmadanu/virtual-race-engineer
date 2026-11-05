import SwiftUI

struct CornerTechniqueReadout: View {
    let sample: CornerTechniqueSample?
    let hasAnalysis: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Corner Technique", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.headline)
                    Spacer()
                    Text("Route phase estimate").font(.caption).foregroundStyle(.secondary)
                }
                Text(sample?.title ?? (hasAnalysis ? "Phase unavailable" : "Analyze video for corner phases"))
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.updatesFrequently)
                if let sample, ["left", "right"].contains(sample.upcomingDirection) {
                    Text("Next bend: \(sample.upcomingDirection.capitalized)").font(.callout)
                }
                Text(sample?.reason ?? (hasAnalysis ? "No fresh phase sample at this time."
                    : "This saved run has no continuous Category 2 analysis."))
                    .font(.callout).foregroundStyle(.secondary)
                Text("Experimental · Apex and racing line unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
