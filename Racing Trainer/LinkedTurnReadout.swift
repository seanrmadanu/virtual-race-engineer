import SwiftUI

struct LinkedTurnReadout: View {
    let sample: LinkedTurnSample?
    let current: CornerTechniqueSample?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Linked Turns", systemImage: "arrow.triangle.branch").font(.headline)
                    Spacer()
                    Text("Route preview").font(.caption).foregroundStyle(.secondary)
                }
                Text(sample?.pattern.title ?? "Sequence unavailable").font(.title2.weight(.semibold))
                Text("Current phase: \(current?.title ?? "Phase unavailable")")
                    .font(.callout).foregroundStyle(.secondary)
                Text(sample?.reason ?? "No fresh sequence sample at this time")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Experimental · Bend order only; timing and braking unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
