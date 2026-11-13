import SwiftUI

/// Dark HUD colours, matching the practice overlay. The panel sits on gameplay
/// video, so it carries its own background instead of following the system theme.
private enum SetupPalette {
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.08)
    static let tile = Color(white: 0.18)
    static let stroke = Color.white.opacity(0.10)
    static let label = Color.white.opacity(0.68)
    static let amber = Color(red: 0.98, green: 0.66, blue: 0.10)
    static let green = Color(red: 0.24, green: 0.84, blue: 0.40)
}

/// The expanded checklist. The app ticks the items; the player only moves
/// through the game's screens so the app can read them. Pure presentation: it
/// shows the items it is given and owns no detection and no timing.
struct SetupChecklistPanel: View {
    let items: [SetupItem]
    @Binding var preferences: SetupPreferences
    @Binding var hudProfile: String
    var scale: CGFloat = 1
    /// Video is arriving, so the app is looking at the screen right now.
    var isWatching = true
    /// Called when the player changes something, so the panel is not closed under them.
    var onInteraction: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Rows where the player chose to enter the value instead of showing it.
    @State private var manualEntry: Set<SetupItemID> = []
    @State private var angleText = ""

    private var isReady: Bool { SetupChecklist.isReady(items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            header
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
        }
        .padding(16 * scale)
        .frame(width: 304 * scale, alignment: .leading)
        .background(SetupPalette.panel.opacity(reduceTransparency ? 1 : 0.92),
                    in: RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
            .strokeBorder(SetupPalette.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup checklist")
    }

    private var header: some View {
        let open = SetupChecklist.openCount(items, required: true)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("Setup")
                    .font(.system(size: 16 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                Text(isReady ? "Ready for guidance" : open == 0 ? "Checking…" : "\(open) to fix before guidance works")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(isReady ? SetupPalette.green : SetupPalette.amber)
            }
            Spacer(minLength: 8 * scale)
            Button(action: onClose) {
                Text(isReady ? "Done" : "Hide")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(SetupPalette.tile, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Close the checklist. The Setup button brings it back.")
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            sectionTitle("Needed for guidance")
            ForEach(items.filter { $0.id.isRequired }) { row($0) }
            Rectangle().fill(SetupPalette.stroke).frame(height: 1)
            sectionTitle("Read from the game's menus")
            ForEach(items.filter { !$0.id.isRequired }) { row($0) }
            Text(isWatching
                 ? "The app is reading the screen. Move through the game's menus and each item ticks when it's seen. Guidance doesn't use these three yet."
                 : "Play the video or connect the capture card so the app can read the screen.")
                .font(.system(size: 11 * scale))
                .foregroundStyle(SetupPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(SetupPalette.label)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SetupItem) -> some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            statusIcon(item.status)
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(item.title)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                // A finished road row needs no explanation; a read row shows what was read.
                if item.status != .done || item.id == .video || item.id.isReadFromMenus {
                    Text(item.detail)
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(SetupPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                control(for: item)
            }
            Spacer(minLength: 0)
        }
    }

    /// Shape and colour both carry the state, so it never depends on colour alone.
    private func statusIcon(_ status: SetupItemStatus) -> some View {
        let symbol: String, color: Color, word: String
        switch status {
        case .done: symbol = "checkmark.circle.fill"; color = SetupPalette.green; word = "Done"
        case .missing: symbol = "exclamationmark.triangle.fill"; color = SetupPalette.amber; word = "Not found"
        case .waiting: symbol = "circle.dotted"; color = SetupPalette.label; word = "Waiting"
        case .showMe: symbol = "text.viewfinder"; color = .white; word = "Not read yet"
        }
        return Image(systemName: symbol)
            .font(.system(size: 14 * scale, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18 * scale, height: 17 * scale)
            .accessibilityLabel(word)
    }

    @ViewBuilder
    private func control(for item: SetupItem) -> some View {
        if item.id == .speed, item.status == .missing {
            choices([("Standard HUD", "motorfest-standard-v1"), ("Reference HUD", "reference-video2-v1")],
                    selected: hudProfile) { hudProfile = $0 }
        } else if item.id.isReadFromMenus {
            if manualEntry.contains(item.id) {
                manualControl(for: item.id)
            } else if item.status == .done {
                linkButton(item.id == .car ? "Switched cars? Read it again" : "Read it again") {
                    preferences.clear(item.id)
                    onInteraction()
                }
            } else if item.id != .assists {
                linkButton("Enter it yourself") {
                    if item.id == .steeringAngle { angleText = "" }
                    manualEntry.insert(item.id)
                    onInteraction()
                }
            }
        }
    }

    /// The fallback for when the app can't read a screen. Anything entered here
    /// is marked as the player's, and a later screen reading replaces it.
    @ViewBuilder
    private func manualControl(for id: SetupItemID) -> some View {
        switch id {
        case .speedUnit:
            choices([("km/h", "km/h"), ("mph", "mph")],
                    selected: preferences.speedUnitConfirmed ? preferences.speedUnit : nil) {
                preferences.speedUnit = $0
                preferences.speedUnitConfirmed = true
                preferences.readFromScreen.remove(.speedUnit)
            }
        case .steeringAngle:
            HStack(spacing: 5 * scale) {
                field("e.g. 900", text: $angleText, width: 76 * scale)
                    .onChange(of: angleText) { _, typed in commitAngle(typed) }
                    .accessibilityLabel("Steering range in degrees")
                Text("degrees")
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(SetupPalette.label)
            }
        case .car:
            field("Car name", text: Binding(
                get: { preferences.carName },
                set: {
                    preferences.carName = $0
                    preferences.carSpecs = ""
                    preferences.readFromScreen.remove(.car)
                    onInteraction()
                }), width: 200 * scale)
                .accessibilityLabel("Car name")
        default:
            EmptyView()
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5 * scale, weight: .medium))
                .foregroundStyle(.white)
                .underline()
        }
        .buttonStyle(.plain)
        .padding(.top, 1 * scale)
    }

    private func choices(_ options: [(title: String, value: String)], selected: String?,
                         pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6 * scale) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selected
                Button {
                    pick(option.value)
                    onInteraction()
                } label: {
                    Text(option.title)
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .padding(.horizontal, 10 * scale)
                        .padding(.vertical, 5 * scale)
                        .background(isSelected ? Color.white : SetupPalette.tile, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.top, 2 * scale)
    }

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5 * scale))
            .foregroundStyle(.white)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 5 * scale)
            .frame(width: width)
            .background(SetupPalette.tile, in: RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
            .padding(.top, 2 * scale)
    }

    /// Digits only. An out-of-range entry stays on screen but is not saved.
    private func commitAngle(_ typed: String) {
        let digits = String(typed.filter(\.isNumber).prefix(4))
        guard digits == typed else { angleText = digits; return }
        onInteraction()
        let value = Int(digits) ?? 0
        preferences.steeringRange = SetupChecklist.isValidSteeringAngle(value) ? String(value) : ""
        preferences.readFromScreen.remove(.steeringAngle)
    }
}

/// The closed state: a small button that reopens the checklist. It turns into a
/// warning only after something needed has been missing for a while.
struct SetupChecklistButton: View {
    let openRequired: Int
    let needsAttention: Bool
    var scale: CGFloat = 1
    var action: () -> Void = {}

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(needsAttention ? "Setup · \(openRequired) to fix" : "Setup")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13 * scale, weight: .medium))
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 9 * scale)
            .background(SetupPalette.panel.opacity(reduceTransparency ? 1 : 0.90), in: Capsule())
            .overlay(Capsule().strokeBorder(needsAttention ? SetupPalette.amber.opacity(0.7) : SetupPalette.stroke,
                                            lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Show the setup checklist")
        .accessibilityLabel(needsAttention ? "Setup, \(openRequired) to fix" : "Setup checklist")
    }

    private var symbol: String {
        needsAttention ? "exclamationmark.triangle.fill" : openRequired == 0 ? "checkmark.circle.fill" : "checklist"
    }

    private var tint: Color {
        needsAttention ? SetupPalette.amber : openRequired == 0 ? SetupPalette.green : .white
    }
}
