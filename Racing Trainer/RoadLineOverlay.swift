import SwiftUI

/// Draws the road paint found in the latest frame: the lane the car is in as a
/// soft corridor between its two boundaries, each boundary in its paint colour,
/// and any other markings faintly. Lines fade toward the horizon and fade out
/// as the observation ages, instead of vanishing in one frame.
struct RoadLineOverlay: View {
    let observation: RoadLineObservation
    let time: Double
    let videoRect: CGRect
    var camera: RoadCameraMode = .chase

    /// Full strength until this age, then fading to nothing at the freshness limit.
    private static let fadeStart = 0.25

    var body: some View {
        Canvas { context, _ in
            guard observation.isFresh(at: time) else { return }
            let age = max(0, time - observation.capturedAt)
            let fade = age <= Self.fadeStart ? 1 : max(0, 1 - (age - Self.fadeStart) / (0.65 - Self.fadeStart))
            guard fade > 0 else { return }

            func convert(_ point: RoadPoint) -> CGPoint {
                CGPoint(x: videoRect.minX + point.x * videoRect.width,
                        y: videoRect.minY + point.y * videoRect.height)
            }
            func path(_ points: [RoadPoint]) -> Path {
                var path = Path()
                path.addLines(points.map(convert))
                return path
            }
            // Brighter near the car, where the evidence is largest on screen.
            func depthShading(_ color: Color, _ points: [RoadPoint], near: Double, far: Double) -> GraphicsContext.Shading {
                let top = points.map(\.y).min() ?? 0, bottom = points.map(\.y).max() ?? 1
                return .linearGradient(
                    Gradient(colors: [color.opacity(far * fade), color.opacity(near * fade)]),
                    startPoint: convert(RoadPoint(x: points.first?.x ?? 0.5, y: top)),
                    endPoint: convert(RoadPoint(x: points.last?.x ?? 0.5, y: bottom)))
            }
            let lineWidth = max(1.5, videoRect.height * 0.003)
            let markings = observation.markings ?? []

            // Markings beyond the lane: context only.
            for marking in markings where !isBoundary(marking) {
                let color = paint(marking.color)
                context.stroke(path(marking.points), with: depthShading(color, marking.points, near: 0.45, far: 0.1),
                               style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round, lineJoin: .round))
            }

            guard observation.hasBoundary else { return }
            let left = observation.left, right = observation.right
            if observation.hasCorridor {
                var corridor = Path()
                corridor.addLines(left.map(convert) + right.reversed().map(convert))
                corridor.closeSubpath()
                let top = left.first?.y ?? 0, bottom = left.last?.y ?? 1
                var fillContext = context
                if camera == .chase {
                    // Keep the tint on the road, never across the player's car.
                    let car = RoadLineDetector.chaseCarRegion
                    var outsideCar = Path(videoRect)
                    outsideCar.addRect(CGRect(x: videoRect.minX + car.minX * videoRect.width,
                                              y: videoRect.minY + car.minY * videoRect.height,
                                              width: car.width * videoRect.width,
                                              height: car.height * videoRect.height))
                    fillContext.clip(to: outsideCar, style: FillStyle(eoFill: true))
                }
                fillContext.fill(corridor, with: .linearGradient(
                    Gradient(colors: [Color.cyan.opacity(0.02 * fade), Color.cyan.opacity(0.16 * fade)]),
                    startPoint: convert(RoadPoint(x: 0.5, y: top)),
                    endPoint: convert(RoadPoint(x: 0.5, y: bottom))))
            }
            for edge in [left, right] where edge.count >= 2 {
                let color = paint(paintColor(of: edge))
                let shape = path(edge)
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                context.stroke(shape, with: .color(.black.opacity(0.5 * fade)),
                               style: StrokeStyle(lineWidth: lineWidth * 2.2, lineCap: .round, lineJoin: .round))
                context.stroke(shape, with: depthShading(color, edge, near: 0.95, far: 0.35), style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if observation.hasCorridor { return "Detected lane boundaries from road paint" }
        if observation.hasBoundary { return "Detected one lane boundary from road paint" }
        return "Detected road markings"
    }

    private func paint(_ color: RoadMarkingColor) -> Color {
        color == .yellow ? Color(red: 1, green: 0.84, blue: 0.25) : .white
    }

    /// Lane edges are resampled from a marking; recover that marking's paint colour.
    private func paintColor(of edge: [RoadPoint]) -> RoadMarkingColor {
        guard let middle = edge.dropFirst(edge.count / 2).first else { return .white }
        let nearest = (observation.markings ?? []).min { distance($0, to: middle) < distance($1, to: middle) }
        return nearest.flatMap { distance($0, to: middle) < 0.02 ? $0.color : nil } ?? .white
    }

    private func isBoundary(_ marking: RoadMarking) -> Bool {
        [observation.left, observation.right].contains { edge in
            guard let middle = edge.dropFirst(edge.count / 2).first else { return false }
            return distance(marking, to: middle) < 0.02
        }
    }

    /// Horizontal distance from a marking to a point, at the point's row.
    private func distance(_ marking: RoadMarking, to point: RoadPoint) -> Double {
        let points = marking.points
        for (a, b) in zip(points, points.dropFirst()) where a.y <= point.y && b.y >= point.y && b.y > a.y {
            let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
            return abs(x - point.x)
        }
        return .infinity
    }
}
