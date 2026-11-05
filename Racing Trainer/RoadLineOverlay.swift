import SwiftUI

/// Draws the tracked road paint: the lane the car is in as a soft corridor
/// between its two boundaries, each boundary in its paint colour, and other
/// markings faintly. Redrawn every display frame by `RoadOverlayAnimator`, so
/// lines fade in and out and crossfade when a boundary changes, never pop.
struct RoadLineOverlay: View {
    let observation: RoadLineObservation
    /// Kept for callers; drawing uses the display clock directly.
    let time: Double
    let videoRect: CGRect
    var camera: RoadCameraMode = .chase

    @State private var animator = RoadOverlayAnimator()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let frame = animator.frame(for: observation, at: ProcessInfo.processInfo.systemUptime)
            Canvas { context, _ in draw(frame, in: context) }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(accessibilityText)
    }

    private func draw(_ frame: RoadOverlayFrame, in context: GraphicsContext) {
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
                Gradient(colors: [color.opacity(far), color.opacity(near)]),
                startPoint: convert(RoadPoint(x: points.first?.x ?? 0.5, y: top)),
                endPoint: convert(RoadPoint(x: points.last?.x ?? 0.5, y: bottom)))
        }
        let lineWidth = max(1.5, videoRect.height * 0.003)

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
        for corridor in frame.corridors where corridor.left.count >= 2 && corridor.right.count >= 2 {
            var shape = Path()
            shape.addLines(corridor.left.map(convert) + corridor.right.reversed().map(convert))
            shape.closeSubpath()
            let top = corridor.left.first?.y ?? 0, bottom = corridor.left.last?.y ?? 1
            fillContext.fill(shape, with: .linearGradient(
                Gradient(colors: [Color.cyan.opacity(0.02 * corridor.opacity), Color.cyan.opacity(0.16 * corridor.opacity)]),
                startPoint: convert(RoadPoint(x: 0.5, y: top)),
                endPoint: convert(RoadPoint(x: 0.5, y: bottom))))
        }
        for stroke in frame.strokes where stroke.points.count >= 2 {
            let color = paint(stroke.color)
            let shape = path(stroke.points)
            if stroke.isBoundary {
                context.stroke(shape, with: .color(.black.opacity(0.5 * stroke.opacity)),
                               style: StrokeStyle(lineWidth: lineWidth * 2.2, lineCap: .round, lineJoin: .round))
                context.stroke(shape, with: depthShading(color, stroke.points, near: 0.95 * stroke.opacity, far: 0.35 * stroke.opacity),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            } else {
                // Markings beyond the lane: context only.
                context.stroke(shape, with: depthShading(color, stroke.points, near: 0.45 * stroke.opacity, far: 0.1 * stroke.opacity),
                               style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var accessibilityText: String {
        if observation.hasCorridor { return "Detected lane boundaries from road paint" }
        if observation.hasBoundary { return "Detected one lane boundary from road paint" }
        return "Detected road markings"
    }

    private func paint(_ color: RoadMarkingColor) -> Color {
        color == .yellow ? Color(red: 1, green: 0.84, blue: 0.25) : .white
    }
}
