import CoreVideo
import Foundation

/// Follows painted lines from frame to frame so the overlay is steady.
///
/// Each frame's fitted lines are matched to the lines already being followed.
/// A matched line glides toward its new position instead of jumping, a line
/// must be seen on a few frames before it is shown, and a line that misses a
/// frame or two is held briefly instead of blinking off. Last frame's lines are
/// also offered to the detector as starting guesses.
///
/// Two observations come out of every update:
/// - `observation` uses only lines with paint support in this frame (smoothed),
///   so evidence never outlives its pixels. This is the one for guidance.
/// - `display` also includes lines held through a short dropout, for drawing.
nonisolated struct RoadLineTracker {
    struct Track: Equatable {
        let id: Int
        var curve: RoadLineDetector.Curve
        var hits: Int
        var lastSeen: Double
        /// Recent fraction of frames with paint support (time-weighted).
        var presence: Double

        var isConfirmed: Bool {
            hits >= RoadLineTracker.confirmationHits && presence >= RoadLineTracker.confirmationPresence
        }
    }

    /// A line is shown once it has been seen on this many frames, and on most
    /// recent frames: sun patches line up briefly, real paint keeps showing up.
    static let confirmationHits = 4
    static let confirmationPresence = 0.3
    /// Time constant of the presence average.
    static let presenceTime = 0.25
    /// How long a line that loses paint support is still drawn.
    static let holdDuration = 0.50
    /// Smoothing time constant: a moved line covers ~63% of the gap in this time.
    static let smoothingTime = 0.045
    /// Line ends follow more slowly: how far paint is visible changes noisily.
    static let rangeSmoothingTime = 0.18
    /// Longer gaps, or time going backwards (seek, new source), start over.
    static let resetGap = 0.5

    private(set) var tracks: [Track] = []
    private var nextID = 0
    private var lastTime: Double?
    private var lastUpdate: Double?
    private var leftID: Int?
    private var rightID: Int?
    /// The lane last shown as a filled corridor, per output.
    private var pairedIDs: [Bool: (Int, Int)] = [:]
    private let detector = RoadLineDetector()

    mutating func reset() {
        tracks = []; lastTime = nil; lastUpdate = nil; leftID = nil; rightID = nil; pairedIDs = [:]
    }

    mutating func update(_ buffer: CVPixelBuffer, at time: Double,
                         camera: RoadCameraMode) -> (observation: RoadLineObservation, display: RoadLineObservation) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            let missing = RoadLineObservation.unavailable(at: time, reason: "Unsupported road image format")
            return (missing, missing)
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 160, height >= 90, abs(Double(width) / Double(height) - 16 / 9.0) < 0.03 else {
            reset()
            let missing = RoadLineObservation.unavailable(at: time, reason: "Road detection needs uncropped 16:9 footage")
            return (missing, missing)
        }
        let candidates = detector.candidates(in: buffer, camera: camera) ?? []
        return update(candidates: candidates, at: time)
    }

    /// Pure stage, also used by tests.
    mutating func update(candidates: [RoadPaintCandidate],
                         at time: Double) -> (observation: RoadLineObservation, display: RoadLineObservation) {
        if let lastTime, !(time > lastTime) || time - lastTime > Self.resetGap { reset() }
        lastTime = time

        let curves = detector.markingCurves(candidates, priors: tracks.map(\.curve))
        match(curves, at: time)
        tracks.removeAll { time - $0.lastSeen > Self.holdDuration }
        mergeDuplicates()

        let confirmed = tracks.filter(\.isConfirmed)
        let current = confirmed.filter { $0.lastSeen == time }
        let observation = assemble(current, at: time, remember: true)
        let display = assemble(confirmed, at: time, remember: false)
        return (observation, display)
    }

    // MARK: Matching

    /// Median horizontal gap between two lines over the rows both cover. The
    /// median ignores the wobble quadratic fits have at their ends.
    static func distance(_ a: RoadLineDetector.Curve, _ b: RoadLineDetector.Curve) -> Double {
        let low = max(a.minY, b.minY), high = min(a.maxY, b.maxY)
        guard high - low >= 0.02 else { return .infinity }
        let gaps = stride(from: low, through: high, by: (high - low) / 4).map { abs(a.x($0) - b.x($0)) }.sorted()
        return gaps[gaps.count / 2]
    }

    /// Allowed per-update movement, larger nearer the car where lines sweep faster.
    /// Neighbouring lane lines are at least about twice this far apart.
    static func matchLimit(_ curve: RoadLineDetector.Curve) -> Double {
        0.022 + max(0, (curve.minY + curve.maxY) / 2 - 0.40) * 0.08
    }

    private mutating func match(_ curves: [RoadLineDetector.Curve], at time: Double) {
        var unmatched = Array(curves.indices)
        let frameGap = lastUpdate.map { min(max(time - $0, 1.0 / 240), Self.holdDuration) } ?? 1.0 / 60
        lastUpdate = time
        let decay = exp(-frameGap / Self.presenceTime)
        for index in tracks.indices { tracks[index].presence *= decay }
        // Established lines claim their detections first.
        for index in tracks.indices.sorted(by: { tracks[$0].hits > tracks[$1].hits }) {
            let track = tracks[index]
            guard let best = unmatched.min(by: { Self.distance(track.curve, curves[$0]) < Self.distance(track.curve, curves[$1]) }),
                  Self.distance(track.curve, curves[best]) <= Self.matchLimit(track.curve) else { continue }
            unmatched.removeAll { $0 == best }
            let dt = min(max(time - track.lastSeen, 1.0 / 240), Self.holdDuration)
            tracks[index].curve = Self.blend(track.curve, toward: curves[best], by: 1 - exp(-dt / Self.smoothingTime),
                rangeBy: 1 - exp(-dt / Self.rangeSmoothingTime), settledColor: track.hits >= Self.confirmationHits)
            tracks[index].hits += 1
            tracks[index].lastSeen = time
            tracks[index].presence += 1 - decay
        }
        for index in unmatched {
            tracks.append(Track(id: nextID, curve: curves[index], hits: 1, lastSeen: time, presence: 1 - decay))
            nextID += 1
        }
    }

    /// Two tracks on the same paint keep the better-established one.
    private mutating func mergeDuplicates() {
        tracks.sort { ($0.hits, -$0.id) > ($1.hits, -$1.id) }
        var kept: [Track] = []
        for track in tracks where !kept.contains(where: { Self.distance($0.curve, track.curve) <= Self.matchLimit($0.curve) / 2 }) {
            kept.append(track)
        }
        tracks = kept
    }

    static func blend(_ old: RoadLineDetector.Curve, toward new: RoadLineDetector.Curve, by f: Double,
                      rangeBy g: Double, settledColor: Bool) -> RoadLineDetector.Curve {
        func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
        return RoadLineDetector.Curve(a: mix(old.a, new.a, f), b: mix(old.b, new.b, f), c: mix(old.c, new.c, f),
            minY: mix(old.minY, new.minY, g), maxY: mix(old.maxY, new.maxY, g), rows: new.rows,
            color: settledColor ? old.color : new.color)
    }

    // MARK: Lane

    /// Keeps the same lines as lane boundaries while they remain visible on the
    /// same side of the car, so the lane does not flick to a nearer streak.
    private mutating func assemble(_ shown: [Track], at time: Double, remember: Bool) -> RoadLineObservation {
        let curves = shown.map(\.curve)
        guard !curves.isEmpty else {
            if remember { leftID = nil; rightID = nil }
            return .unavailable(at: time, reason: "Road markings are not established")
        }
        let sides = detector.laneSides(curves)
        func pick(_ ordered: [RoadLineDetector.Curve], previous: Int?) -> RoadLineDetector.Curve? {
            guard let nearest = ordered.first else { return nil }
            if let previous, let kept = shown.first(where: { $0.id == previous })?.curve, ordered.contains(kept) {
                return kept
            }
            return nearest
        }
        let left = pick(sides.left, previous: leftID)
        let right = pick(sides.right, previous: rightID)
        let ids = (left.flatMap { curve in shown.first { $0.curve == curve }?.id },
                   right.flatMap { curve in shown.first { $0.curve == curve }?.id })
        if remember { leftID = ids.0; rightID = ids.1 }
        // A lane already shown stays paired on looser overlap, so the fill does not blink.
        let wasPaired = pairedIDs[remember].map { $0 == ids.0 && $1 == ids.1 } ?? false
        let observation = detector.lane(markings: curves, left: left, right: right, at: time, keepPaired: wasPaired)
        if observation.hasCorridor, let l = ids.0, let r = ids.1 { pairedIDs[remember] = (l, r) }
        else { pairedIDs[remember] = nil }
        return observation
    }
}

// MARK: - Drawing animation

/// What the overlay draws on one display frame.
nonisolated struct RoadOverlayFrame: Equatable {
    struct Stroke: Equatable {
        let points: [RoadPoint]
        let color: RoadMarkingColor
        let opacity: Double
        let isBoundary: Bool
    }
    struct Corridor: Equatable {
        let left: [RoadPoint]
        let right: [RoadPoint]
        let opacity: Double
    }
    var strokes: [Stroke] = []
    var corridors: [Corridor] = []
}

/// Turns a stream of lane observations into smooth drawing: every element fades
/// in and out instead of popping, and a lane boundary that moves to a different
/// painted line crossfades instead of jumping across the road. Display only.
nonisolated final class RoadOverlayAnimator {
    static let fadeIn = 0.12
    static let fadeOut = 0.25
    /// Movement larger than this (median, frame fraction) is a switch to another line.
    static let switchDistance = 0.03

    private struct Element {
        var points: [RoadPoint]
        var partner: [RoadPoint] = []
        var color: RoadMarkingColor = .white
        var opacity = 0.0
        var target = 1.0
    }
    private var left: Element?, right: Element?, corridor: Element?
    private var others: [Element] = []
    private var ghosts: [(element: Element, kind: Int)] = []   // 0 boundary, 1 corridor, 2 other
    private var lastTime: Double?

    func reset() { left = nil; right = nil; corridor = nil; others = []; ghosts = []; lastTime = nil }

    func frame(for observation: RoadLineObservation, at time: Double) -> RoadOverlayFrame {
        if let lastTime, time < lastTime { reset() }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time
        let usable = observation.isFresh(at: time)
        let markings = usable ? (observation.markings ?? []) : []
        func color(of edge: [RoadPoint]) -> RoadMarkingColor {
            guard let middle = edge.dropFirst(edge.count / 2).first else { return .white }
            return markings.min { Self.gap($0.points, middle) < Self.gap($1.points, middle) }
                .flatMap { Self.gap($0.points, middle) < 0.02 ? $0.color : nil } ?? .white
        }
        let leftEdge = usable && observation.left.count >= 2 ? observation.left : nil
        let rightEdge = usable && observation.right.count >= 2 ? observation.right : nil
        update(&left, to: leftEdge, partner: [], color: leftEdge.map(color) ?? .white, kind: 0)
        update(&right, to: rightEdge, partner: [], color: rightEdge.map(color) ?? .white, kind: 0)
        let lane = usable && observation.hasCorridor ? observation : nil
        update(&corridor, to: lane?.left, partner: lane?.right ?? [], color: .white, kind: 1)

        // Other markings: match by position to keep their fades continuous.
        let boundaries = [leftEdge, rightEdge].compactMap { $0 }
        let extra = markings.filter { marking in
            !boundaries.contains { edge in
                guard let middle = edge.dropFirst(edge.count / 2).first else { return false }
                return Self.gap(marking.points, middle) < 0.02
            }
        }
        var matched = Set<Int>()
        for index in others.indices {
            if let best = extra.indices.filter({ !matched.contains($0) })
                .min(by: { Self.distance(extra[$0].points, others[index].points) < Self.distance(extra[$1].points, others[index].points) }),
               Self.distance(extra[best].points, others[index].points) < Self.switchDistance {
                matched.insert(best)
                others[index].points = extra[best].points; others[index].color = extra[best].color; others[index].target = 1
            } else {
                others[index].target = 0
            }
        }
        for index in extra.indices where !matched.contains(index) {
            others.append(Element(points: extra[index].points, color: extra[index].color, opacity: 0, target: 1))
        }

        // Advance fades.
        func step(_ element: inout Element) {
            if element.target > element.opacity {
                element.opacity = min(element.target, element.opacity + dt / Self.fadeIn)
            } else {
                element.opacity = max(element.target, element.opacity - dt / Self.fadeOut)
            }
        }
        for slot in [\RoadOverlayAnimator.left, \.right, \.corridor] {
            if var element = self[keyPath: slot] {
                step(&element)
                self[keyPath: slot] = element.opacity <= 0 && element.target == 0 ? nil : element
            }
        }
        for index in others.indices { step(&others[index]) }
        others.removeAll { $0.opacity <= 0 && $0.target == 0 }
        for index in ghosts.indices { step(&ghosts[index].element) }
        ghosts.removeAll { $0.element.opacity <= 0 }

        var frame = RoadOverlayFrame()
        for element in others where element.opacity > 0 {
            frame.strokes.append(.init(points: element.points, color: element.color, opacity: element.opacity, isBoundary: false))
        }
        for ghost in ghosts where ghost.kind == 1 {
            frame.corridors.append(.init(left: ghost.element.points, right: ghost.element.partner, opacity: ghost.element.opacity))
        }
        if let corridor, corridor.opacity > 0 {
            frame.corridors.append(.init(left: corridor.points, right: corridor.partner, opacity: corridor.opacity))
        }
        for ghost in ghosts where ghost.kind == 0 {
            frame.strokes.append(.init(points: ghost.element.points, color: ghost.element.color, opacity: ghost.element.opacity, isBoundary: true))
        }
        for element in [left, right].compactMap({ $0 }) where element.opacity > 0 {
            frame.strokes.append(.init(points: element.points, color: element.color, opacity: element.opacity, isBoundary: true))
        }
        return frame
    }

    private func update(_ slot: inout Element?, to points: [RoadPoint]?, partner: [RoadPoint],
                        color: RoadMarkingColor, kind: Int) {
        guard let points else { slot?.target = 0; return }
        if var current = slot, current.opacity > 0 || current.target > 0 {
            let moved = Self.distance(current.points, points)
                + (kind == 1 ? Self.distance(current.partner, partner) : 0)
            if moved < Self.switchDistance {
                current.points = points; current.partner = partner; current.color = color; current.target = 1
                slot = current
                return
            }
            // A different line: let the old one fade out where it was.
            current.target = 0
            ghosts.append((current, kind))
        }
        slot = Element(points: points, partner: partner, color: color, opacity: 0, target: 1)
    }

    /// Median horizontal gap between two polylines over shared rows (∞ if none).
    static func distance(_ a: [RoadPoint], _ b: [RoadPoint]) -> Double {
        guard let a0 = a.first?.y, let a1 = a.last?.y, let b0 = b.first?.y, let b1 = b.last?.y else { return .infinity }
        let low = max(a0, b0), high = min(a1, b1)
        guard high > low else { return .infinity }
        let gaps = (0...4).compactMap { i -> Double? in
            let y = low + (high - low) * Double(i) / 4
            guard let xa = x(of: a, at: y), let xb = x(of: b, at: y) else { return nil }
            return abs(xa - xb)
        }.sorted()
        return gaps.isEmpty ? .infinity : gaps[gaps.count / 2]
    }

    static func gap(_ line: [RoadPoint], _ point: RoadPoint) -> Double {
        x(of: line, at: point.y).map { abs($0 - point.x) } ?? .infinity
    }

    static func x(of line: [RoadPoint], at y: Double) -> Double? {
        for (a, b) in zip(line, line.dropFirst()) where a.y <= y && b.y >= y {
            return b.y > a.y ? a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x) : a.x
        }
        return nil
    }
}
