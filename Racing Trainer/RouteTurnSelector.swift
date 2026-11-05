import Foundation

/// Selects a meaningful change along the forward route, relative to its local
/// tangent. A slightly angled straight is not automatically a turn. Distances
/// stay in normalized map coordinates; no timing in seconds is inferred.
nonisolated enum RouteTurnSelector {
    struct NearRoute: Sendable {
        let bearing: Double
        let startGap: Double
        let tangent: Double
    }

    /// Near-route bearing is measured from the detected player, including the
    /// hidden gap under the marker. Curvature farther along the path is not the
    /// current driving direction. This is image geometry, not a steering angle.
    static func nearRoute(_ path: [MinimapPoint], anchor: MinimapPoint?) -> NearRoute? {
        guard let anchor, anchor.x.isFinite, anchor.y.isFinite,
              (0...1).contains(anchor.x), (0...1).contains(anchor.y), path.count >= 6,
              path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let first = path.first else { return nil }
        let gap = hypot(first.x - anchor.x, first.y - anchor.y)
        guard gap <= 0.095, first.y <= anchor.y + 0.012 else { return nil }
        // A fixed local window, rather than the bend's farthest heading change.
        let horizon = 0.09
        var remaining = horizon - gap
        var target: MinimapPoint?
        if remaining <= 0 { target = first }
        for (a, b) in zip(path, path.dropFirst()) where target == nil {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            if remaining <= length {
                let fraction = remaining / length
                target = MinimapPoint(x: a.x + fraction * (b.x - a.x), y: a.y + fraction * (b.y - a.y))
            } else { remaining -= length }
        }
        guard let target, anchor.y - target.y > 0.025 else { return nil }
        // The player-to-path gap is largely the marker's occluded footprint.
        // Its bearing alone stays upright while the visible road already bends.
        // Measure the first short visible segment independently of that gap.
        var localEnd = first, localLength = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            let fraction = min(1, (0.06 - localLength) / length)
            localEnd = MinimapPoint(x: a.x + fraction * (b.x - a.x), y: a.y + fraction * (b.y - a.y))
            localLength += length * fraction
            if localLength >= 0.06 - 1e-9 { break }
        }
        guard localLength >= 0.05 else { return nil }
        return NearRoute(bearing: atan2(target.x - anchor.x, anchor.y - target.y) * 180 / .pi,
                         startGap: gap, tangent: atan2(localEnd.x - first.x, first.y - localEnd.y) * 180 / .pi)
    }
    struct Selection: Equatable, Sendable {
        let direction: String
        let severity: String
        let distance: Double?
        let target: String
        let reason: String
    }

    static func select(_ path: [MinimapPoint], preferUpcoming: Bool = true, minimumChange: Double = 24) -> Selection {
        func unknown(_ reason: String) -> Selection {
            Selection(direction: "unknown", severity: "unknown", distance: nil, target: "unknown", reason: reason)
        }
        guard path.count >= 8, path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return unknown("Insufficient forward route samples")
        }
        var distances = [0.0]
        for i in 1..<path.count {
            distances.append(distances.last! + hypot(path[i].x - path[i-1].x, path[i].y - path[i-1].y))
        }
        guard distances.last! >= 0.16, path[0].y - path[min(4, path.count-1)].y > 0.015 else {
            return unknown("Selected route does not establish forward continuity")
        }
        var headings: [Double] = []
        for i in path.indices {
            let a = path[max(0, i-2)], b = path[min(path.count-1, i+2)]
            var angle = atan2(b.x-a.x, -(b.y-a.y)) * 180 / .pi
            if let previous = headings.last {
                while angle - previous > 180 { angle -= 360 }
                while angle - previous < -180 { angle += 360 }
            }
            headings.append(angle)
        }
        var candidates: [(distance: Double, change: Double)] = []
        var baseline = headings[0], anchor = 0, i = 2
        while i < headings.count - 1 {
            let change = headings[i] - baseline
            guard abs(change) >= minimumChange, abs(headings[i+1] - baseline) >= minimumChange else { i += 1; continue }
            let sign = change > 0 ? 1.0 : -1.0
            var peak = i, end = i + 1
            while end < headings.count {
                if (headings[end] - headings[peak]) * sign > 0 { peak = end }
                if (headings[peak] - headings[end]) * sign >= 14 { break }
                end += 1
            }
            var onset = anchor
            for j in anchor...i where abs(headings[j] - baseline) < 8 { onset = j }
            // A gentle bend can reach its shallow peak quickly and then hold
            // it. Count that sustained arc for Next, not only the rise to peak.
            let support = minimumChange < 24 ? min(end, headings.count - 1) : peak
            if distances[support] - distances[onset] >= 0.055 {
                candidates.append((distances[onset], headings[peak] - baseline))
            }
            baseline = headings[peak]; anchor = peak; i = max(i+1, peak+1)
        }
        guard !candidates.isEmpty else {
            return Selection(direction: "straight", severity: "straight", distance: nil,
                             target: "straight_segment", reason: "No sustained route heading change of \(Int(minimumChange)) degrees")
        }
        // A near segment and a subsequent turn have separate identities.
        // Near alone is not an assertion that the vehicle is already steering.
        let selected = preferUpcoming ? (candidates.first(where: { $0.distance >= 0.08 }) ?? candidates[0]) : candidates[0]
        let magnitude = abs(selected.change)
        return Selection(direction: selected.change < 0 ? "left" : "right",
                         severity: magnitude >= 135 ? "uTurn" : magnitude >= 80 ? "sharp" : magnitude >= 42 ? "medium" : "gentle",
                         distance: selected.distance,
                         target: selected.distance < 0.08 ? "near_route" : "upcoming_route",
                         reason: "Sustained route change \(Int(magnitude))°; \(candidates.count) visible bend segment(s)")
    }
}
