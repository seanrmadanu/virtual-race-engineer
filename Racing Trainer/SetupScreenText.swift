import Foundation

/// One line of text found on the game picture. Position is normalized to the
/// frame, with the origin at the top left.
nonisolated struct ScreenTextLine: Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
}

/// A setup value read off the screen. `value` is what gets stored; `summary`
/// is what the checklist shows.
nonisolated struct SetupReading: Equatable, Sendable {
    let value: String
    let summary: String
}

/// Turns the text on a Motorfest menu or HUD into setup values. Rules only: it
/// never sees pixels. Labels come from the game's English menus:
/// Options › Game Settings › Unit, Options › Controls › Wheel Controls ›
/// Dynamic Range, Options › Difficulty › Auto Steering / Auto Braking.
nonisolated enum SetupScreenMatcher {
    static func read(_ lines: [ScreenTextLine]) -> [SetupItemID: SetupReading] {
        var found: [SetupItemID: SetupReading] = [:]
        if let unit = speedUnit(lines) { found[.speedUnit] = unit }
        if let range = steeringRange(lines) { found[.steeringAngle] = range }
        if let assists = assists(lines) { found[.assists] = assists }
        if let car = car(lines) { found[.car] = car }
        return found
    }

    /// The picture looks like a menu, not the road: one of the known settings
    /// rows is on screen.
    static func looksLikeSettingsMenu(_ lines: [ScreenTextLine]) -> Bool {
        let rows: [[String]] = [["unit"], ["dynamic", "range"], ["auto", "steering"], ["auto", "braking"],
                                ["force", "feedback"], ["steering", "preset"], ["traction", "control"]]
        return lines.contains { line in rows.contains { leadingWords(of: line.text, match: $0) != nil } }
    }

    // MARK: - Items

    private static func speedUnit(_ lines: [ScreenTextLine]) -> SetupReading? {
        // The settings row wins over the HUD: it states the unit in words.
        for line in lines {
            guard let rest = leadingWords(of: line.text, match: ["unit"]) ?? leadingWords(of: line.text, match: ["units"]),
                  let unit = unit(in: rest + " " + (valueBeside(line, in: lines) ?? "")) else { continue }
            return SetupReading(value: unit, summary: unit)
        }
        // The speedometer prints its unit as a short label of its own.
        for line in lines where line.y > 0.5 {
            let compact = line.text.lowercased().filter { !$0.isWhitespace }
            if ["km/h", "kmh", "kph"].contains(compact) { return SetupReading(value: "km/h", summary: "km/h") }
            if compact == "mph" { return SetupReading(value: "mph", summary: "mph") }
        }
        return nil
    }

    private static func unit(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("metric") || lower.contains("km/h") || lower.contains("kph") { return "km/h" }
        if lower.contains("imperial") || lower.contains("mph") { return "mph" }
        return nil
    }

    private static func steeringRange(_ lines: [ScreenTextLine]) -> SetupReading? {
        for line in lines {
            guard let rest = leadingWords(of: line.text, match: ["dynamic", "range"]),
                  onOff(in: rest + " " + (valueBeside(line, in: lines) ?? "")) == true else { continue }
            return SetupReading(value: "auto", summary: "Set per car by the game")
        }
        // With Dynamic Range off the game uses one angle for every car.
        let labels: [[String]] = [["steering", "range"], ["wheel", "range"], ["steering", "angle"], ["wheel", "angle"],
                                  ["steering", "rotation"], ["wheel", "rotation"], ["rotation"], ["range"]]
        for line in lines {
            guard let rest = labels.lazy.compactMap({ leadingWords(of: line.text, match: $0) }).first else { continue }
            let numbers = (rest + " " + (valueBeside(line, in: lines) ?? ""))
                .split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if let degrees = numbers.first(where: SetupChecklist.isValidSteeringAngle) {
                return SetupReading(value: String(degrees), summary: "\(degrees)°")
            }
        }
        return nil
    }

    private static func assists(_ lines: [ScreenTextLine]) -> SetupReading? {
        func state(_ label: [String]) -> Bool? {
            for line in lines {
                guard let rest = leadingWords(of: line.text, match: label),
                      let on = onOff(in: rest + " " + (valueBeside(line, in: lines) ?? "")) else { continue }
                return on
            }
            return nil
        }
        // Both rows sit together on the Difficulty page; one alone is a partial read.
        guard let steering = state(["auto", "steering"]), let braking = state(["auto", "braking"]) else { return nil }
        return SetupReading(value: "steering=\(steering ? "on" : "off");braking=\(braking ? "on" : "off")",
                            summary: "Auto steering \(steering ? "on" : "off") · Auto braking \(braking ? "on" : "off")")
    }

    /// A car screen is recognized by its spec rows. The name is taken as the
    /// largest other text on screen, which is a guess until checked on real
    /// Motorfest car screens.
    private static func car(_ lines: [ScreenTextLine]) -> SetupReading? {
        let specLabels: [(title: String, words: [[String]])] = [
            ("Top speed", [["top", "speed"], ["max", "speed"], ["maximum", "speed"]]),
            ("Acceleration", [["acceleration"], ["0", "60"], ["0", "100"], ["0", "62"]]),
            ("Power", [["power"], ["horsepower"]]),
            ("Weight", [["weight"]]),
            ("Braking", [["braking"]]),
            ("Handling", [["handling"]]),
        ]
        var specs: [String] = []
        var specLines: [ScreenTextLine] = []
        for label in specLabels {
            for line in lines {
                guard let rest = label.words.lazy.compactMap({ leadingWords(of: line.text, match: $0) }).first else { continue }
                let value = [rest, valueBeside(line, in: lines) ?? ""].joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard value.contains(where: \.isNumber) else { continue }
                specs.append("\(label.title) \(value)")
                specLines.append(line)
                break
            }
        }
        guard specs.count >= 2 else { return nil }
        let name = lines.filter { line in
            !specLines.contains(line) && line.text.filter(\.isLetter).count >= 3
                && line.text.filter(\.isLetter).count * 2 >= line.text.count
        }.max { $0.height < $1.height }
        guard let name else { return nil }
        let clean = name.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SetupReading(value: clean, summary: specs.prefix(3).joined(separator: " · "))
    }

    // MARK: - Text helpers

    /// If the line starts with these words (ignoring case and punctuation),
    /// returns whatever follows them on the same line.
    static func leadingWords(of text: String, match words: [String]) -> String? {
        var rest = Substring(text.lowercased())
        for word in words {
            rest = rest.drop { !$0.isLetter && !$0.isNumber }
            guard rest.hasPrefix(word) else { return nil }
            rest = rest.dropFirst(word.count)
            // "unit" must not match "unity"; "range" must not match "ranges".
            if let next = rest.first, next.isLetter || next.isNumber { return nil }
        }
        return String(rest)
    }

    /// The nearest text to the right of a label on the same row.
    static func valueBeside(_ label: ScreenTextLine, in lines: [ScreenTextLine]) -> String? {
        lines.filter { other in
            other != label && other.x >= label.maxX - 0.005
                && abs(other.midY - label.midY) <= 0.6 * max(label.height, other.height)
        }.min { $0.x < $1.x }?.text
    }

    private static func onOff(in text: String) -> Bool? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words {
            if ["on", "0n", "enabled", "yes"].contains(word) { return true }
            if ["off", "0ff", "disabled", "no"].contains(word) { return false }
        }
        return nil
    }
}

/// One reading can be a misread. A value is accepted only after two scans in a
/// row agree on it.
nonisolated struct SetupReadingConfirmer {
    private var pending: [SetupItemID: SetupReading] = [:]

    /// Returns the readings confirmed by this scan.
    mutating func confirm(_ scan: [SetupItemID: SetupReading]) -> [SetupItemID: SetupReading] {
        let confirmed = scan.filter { pending[$0.key] == $0.value }
        pending = scan
        return confirmed
    }

    mutating func reset() { pending = [:] }
}
