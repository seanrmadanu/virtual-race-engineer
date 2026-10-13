import Foundation

/// Selects a meaningful change along the forward route, relative to its local
/// tangent. A slightly angled straight is not automatically a turn. Distances
/// stay in normalized map coordinates; no timing in seconds is inferred.
nonisolated enum RouteTurnSelector {
    struct Selection: Equatable, Sendable {
        let direction: String
        let severity: String
        let distance: Double?
        let target: String
        let reason: String
    }

    static func select(_ path: [MinimapPoint], preferUpcoming: Bool = true) -> Selection {
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
            guard abs(change) >= 24, abs(headings[i+1] - baseline) >= 24 else { i += 1; continue }
            let sign = change > 0 ? 1.0 : -1.0
            var peak = i, end = i + 1
            while end < headings.count {
                if (headings[end] - headings[peak]) * sign > 0 { peak = end }
                if (headings[peak] - headings[end]) * sign >= 14 { break }
                end += 1
            }
            var onset = anchor
            for j in anchor...i where abs(headings[j] - baseline) < 8 { onset = j }
            if distances[peak] - distances[onset] >= 0.055 {
                candidates.append((distances[onset], headings[peak] - baseline))
            }
            baseline = headings[peak]; anchor = peak; i = max(i+1, peak+1)
        }
        guard !candidates.isEmpty else {
            return Selection(direction: "straight", severity: "straight", distance: nil,
                             target: "straight_segment", reason: "No sustained route heading change of 24 degrees")
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
