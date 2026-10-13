import SwiftUI

struct RoadLineOverlay: View {
    let observation: RoadLineObservation
    let time: Double
    let videoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard observation.hasBoundary, observation.isFresh(at: time) else { return }
            func convert(_ point: RoadPoint) -> CGPoint {
                CGPoint(x: videoRect.minX + point.x * videoRect.width,
                        y: videoRect.minY + point.y * videoRect.height)
            }
            let left = observation.left.map(convert), right = observation.right.map(convert)
            if observation.hasCorridor {
                var corridor = Path()
                corridor.addLines(left + right.reversed())
                corridor.closeSubpath()
                context.fill(corridor, with: .color(.cyan.opacity(0.08)))
            }
            var edges = Path()
            edges.addLines(left); edges.addLines(right)
            context.stroke(edges, with: .color(.black.opacity(0.55)), lineWidth: max(3, videoRect.height * 0.005))
            context.stroke(edges, with: .color(.white.opacity(0.9)), lineWidth: max(1.5, videoRect.height * 0.0025))
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Detected white road boundaries")
    }
}
