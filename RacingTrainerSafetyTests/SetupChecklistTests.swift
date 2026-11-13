import XCTest

/// The setup checklist's rules: what counts as ready, what each gap tells the
/// player, and when the panel opens and closes by itself.
final class SetupChecklistTests: XCTestCase {
    private func signals(width: Int = 1920, height: Int = 1080, live: Bool = true, minimap: Bool = true,
                         route: Bool = true, noWaypoint: Bool = false, speed: Bool = true) -> SetupSignals {
        SetupSignals(receivingFrames: live, frameWidth: width, frameHeight: height, minimapVisible: minimap,
                     routeDetected: route, noWaypoint: noWaypoint, speedReadable: speed)
    }

    /// Everything read from the game's screens.
    private var confirmed: SetupPreferences {
        var preferences = SetupPreferences()
        XCTAssertTrue(preferences.apply(SetupReading(value: "km/h", summary: "km/h"), for: .speedUnit))
        XCTAssertTrue(preferences.apply(SetupReading(value: "auto", summary: ""), for: .steeringAngle))
        XCTAssertTrue(preferences.apply(SetupReading(value: "", summary: "Auto steering off · Auto braking off"), for: .assists))
        XCTAssertTrue(preferences.apply(SetupReading(value: "BMW M4", summary: "Top speed 290 km/h"), for: .car))
        return preferences
    }

    private func status(_ id: SetupItemID, _ items: [SetupItem]) -> SetupItemStatus? {
        items.first { $0.id == id }?.status
    }

    private func detail(_ id: SetupItemID, _ items: [SetupItem]) -> String {
        items.first { $0.id == id }?.detail ?? ""
    }

    /// A menu row: a label on the left and, optionally, its value on the right.
    private func row(_ label: String, _ value: String? = nil, y: Double) -> [ScreenTextLine] {
        var lines = [ScreenTextLine(text: label, x: 0.20, y: y, width: 0.012 * Double(label.count), height: 0.03)]
        if let value { lines.append(ScreenTextLine(text: value, x: 0.70, y: y + 0.002, width: 0.012 * Double(value.count), height: 0.028)) }
        return lines
    }

    func testEverythingFoundAndReadIsReady() {
        let items = SetupChecklist.evaluate(signals: signals(), preferences: confirmed)
        XCTAssertEqual(items.map(\.id), SetupItemID.allCases, "One row per item, in a fixed order")
        XCTAssertTrue(items.allSatisfy { $0.status == .done })
        XCTAssertTrue(SetupChecklist.isReady(items))
        XCTAssertEqual(SetupChecklist.openCount(items, required: true), 0)
        XCTAssertEqual(detail(.video, items), "Receiving 1920 × 1080")
        XCTAssertEqual(detail(.speedUnit, items), "km/h, read from the game")
        XCTAssertTrue(detail(.steeringAngle, items).contains("per car"))
        XCTAssertEqual(detail(.car, items), "BMW M4 · Top speed 290 km/h")
    }

    func testNoFramesMakesEverythingBehindItWait() {
        // The analyzer keeps its last values when frames stop; they must not show as found.
        let items = SetupChecklist.evaluate(signals: signals(live: false), preferences: confirmed)
        XCTAssertEqual(status(.video, items), .missing)
        for id in [SetupItemID.picture, .minimap, .route, .speed] {
            XCTAssertEqual(status(id, items), .waiting, "\(id)")
        }
        XCTAssertFalse(SetupChecklist.isReady(items))
    }

    func testWrongPictureShapeIsNamedAndBlocksHUDChecks() {
        let items = SetupChecklist.evaluate(signals: signals(width: 1440, height: 1080), preferences: confirmed)
        XCTAssertEqual(status(.picture, items), .missing)
        XCTAssertTrue(detail(.picture, items).contains("1440 × 1080"))
        XCTAssertEqual(status(.minimap, items), .waiting)
        XCTAssertEqual(status(.speed, items), .waiting)
        XCTAssertEqual(SetupChecklist.openCount(items, required: true), 1, "Waiting rows are not separate things to fix")
        // Slightly off 16:9 (within the analyzer's own tolerance) still passes.
        let near = SetupChecklist.evaluate(signals: signals(width: 1916, height: 1080), preferences: confirmed)
        XCTAssertEqual(status(.picture, near), .done)
    }

    func testRouteWaitsForTheMinimapAndExplainsAMissingWaypoint() {
        let noMap = SetupChecklist.evaluate(signals: signals(minimap: false, route: false), preferences: confirmed)
        XCTAssertEqual(status(.minimap, noMap), .missing)
        XCTAssertEqual(status(.route, noMap), .waiting)

        let noWaypoint = SetupChecklist.evaluate(signals: signals(route: false, noWaypoint: true), preferences: confirmed)
        XCTAssertEqual(status(.route, noWaypoint), .missing)
        XCTAssertTrue(detail(.route, noWaypoint).contains("Set a waypoint"))
        XCTAssertEqual(SetupChecklist.openCount(noWaypoint, required: true), 1)
    }

    func testAnOpenGameMenuIsNotReportedAsAFault() {
        var inMenu = signals(minimap: false, route: false, speed: false)
        inMenu.gameMenuOpen = true
        let items = SetupChecklist.evaluate(signals: inMenu, preferences: confirmed)
        for id in [SetupItemID.minimap, .route, .speed] {
            XCTAssertEqual(status(id, items), .waiting, "\(id)")
            XCTAssertTrue(detail(id, items).contains("Game menu open"), "\(id)")
        }
        XCTAssertEqual(SetupChecklist.openCount(items, required: true), 0)
        XCTAssertFalse(SetupChecklist.isReady(items), "A menu is not the road")
    }

    func testNothingIsTickedUntilTheAppHasReadIt() {
        // The stored default unit is km/h, but the app has not seen it.
        let items = SetupChecklist.evaluate(signals: signals(), preferences: SetupPreferences())
        for id in [SetupItemID.speedUnit, .steeringAngle, .assists, .car] {
            XCTAssertEqual(status(id, items), .showMe, "\(id)")
        }
        XCTAssertFalse(SetupChecklist.isReady(items))
        XCTAssertEqual(SetupChecklist.openCount(items, required: true), 1)
        XCTAssertEqual(SetupChecklist.openCount(items, required: false), 3)
        XCTAssertTrue(detail(.steeringAngle, items).contains("Wheel Controls"))
    }

    func testMenuItemsNeverBlockGuidanceAndCanBeReadAgain() {
        var preferences = SetupPreferences()
        _ = preferences.apply(SetupReading(value: "mph", summary: "mph"), for: .speedUnit)
        XCTAssertTrue(SetupChecklist.isReady(SetupChecklist.evaluate(signals: signals(), preferences: preferences)))
        XCTAssertFalse(preferences.apply(SetupReading(value: "mph", summary: "mph"), for: .speedUnit), "Same reading: no change")

        preferences.clear(.speedUnit)
        XCTAssertFalse(preferences.readFromScreen.contains(.speedUnit))
        let items = SetupChecklist.evaluate(signals: signals(), preferences: preferences)
        XCTAssertEqual(status(.speedUnit, items), .showMe)

        // A value the player entered is labelled as theirs; a later reading replaces it.
        preferences.steeringRange = "540"
        XCTAssertEqual(detail(.steeringAngle, SetupChecklist.evaluate(signals: signals(), preferences: preferences)),
                       "540°, entered by you")
        _ = preferences.apply(SetupReading(value: "900", summary: "900°"), for: .steeringAngle)
        XCTAssertEqual(detail(.steeringAngle, SetupChecklist.evaluate(signals: signals(), preferences: preferences)),
                       "900°, read from the game")
        preferences.steeringRange = "9"
        XCTAssertEqual(status(.steeringAngle, SetupChecklist.evaluate(signals: signals(), preferences: preferences)), .showMe)

        let ids: Set<SetupItemID> = [.car, .speedUnit]
        XCTAssertEqual(SetupChecklistStorage.decode(SetupChecklistStorage.encode(ids)), ids)
        XCTAssertEqual(SetupChecklistStorage.decode("car,nonsense,"), [.car])
    }

    // MARK: - Reading the screen

    func testUnitIsReadFromTheSettingsRowAndFromTheSpeedometer() {
        XCTAssertEqual(SetupScreenMatcher.read(row("Unit", "Metric", y: 0.3))[.speedUnit]?.value, "km/h")
        XCTAssertEqual(SetupScreenMatcher.read(row("UNIT", "< Imperial >", y: 0.3))[.speedUnit]?.value, "mph")
        XCTAssertEqual(SetupScreenMatcher.read(row("Unit Imperial", y: 0.3))[.speedUnit]?.value, "mph", "Label and value merged into one line")

        // The HUD prints the unit under the speed, as in the test recordings.
        let hud = [ScreenTextLine(text: "267", x: 0.077, y: 0.866, width: 0.086, height: 0.062),
                   ScreenTextLine(text: "km/h", x: 0.099, y: 0.930, width: 0.025, height: 0.016)]
        XCTAssertEqual(SetupScreenMatcher.read(hud)[.speedUnit]?.value, "km/h")
        XCTAssertNil(SetupScreenMatcher.read([ScreenTextLine(text: "MPH", x: 0.5, y: 0.2, width: 0.03, height: 0.02)])[.speedUnit],
                     "A unit-like word high on the screen is not the speedometer")

        // Words that only contain the label must not match, and the value must be on the same row.
        XCTAssertNil(SetupScreenMatcher.read(row("United Kingdom", "Metric", y: 0.3))[.speedUnit])
        let otherRow = row("Unit", y: 0.3) + [ScreenTextLine(text: "Imperial", x: 0.7, y: 0.5, width: 0.1, height: 0.03)]
        XCTAssertNil(SetupScreenMatcher.read(otherRow)[.speedUnit])
    }

    func testSteeringRangeIsReadFromWheelControls() {
        let page = row("Force Feedback", "65", y: 0.20) + row("Gearbox", "Sequential", y: 0.26)
        XCTAssertEqual(SetupScreenMatcher.read(page + row("Dynamic Range", "On", y: 0.32))[.steeringAngle]?.value, "auto")
        XCTAssertNil(SetupScreenMatcher.read(page + row("Dynamic Range", "Off", y: 0.32))[.steeringAngle],
                     "Off with no angle on screen is not a reading")
        let fixed = page + row("Dynamic Range", "Off", y: 0.32) + row("Steering Range", "900°", y: 0.38)
        XCTAssertEqual(SetupScreenMatcher.read(fixed)[.steeringAngle], SetupReading(value: "900", summary: "900°"))
        XCTAssertNil(SetupScreenMatcher.read(page + row("Steering Range", "65", y: 0.38))[.steeringAngle], "Out of range")
        XCTAssertTrue(SetupScreenMatcher.looksLikeSettingsMenu(page))
        XCTAssertFalse(SetupScreenMatcher.looksLikeSettingsMenu(row("WINDWARD COAST", y: 0.5) + row("km/h", y: 0.93)))
    }

    func testAssistsNeedBothRowsAndCarNeedsSpecs() {
        let assists = row("Auto Braking", "Off", y: 0.2) + row("Auto Steering", "On", y: 0.26) + row("ABS", "Off", y: 0.32)
        XCTAssertEqual(SetupScreenMatcher.read(assists)[.assists]?.summary, "Auto steering on · Auto braking off")
        XCTAssertNil(SetupScreenMatcher.read(row("Auto Steering", "On", y: 0.26))[.assists])

        let title = ScreenTextLine(text: "BMW M4 Competition", x: 0.1, y: 0.1, width: 0.4, height: 0.06)
        let car = [title] + row("Top Speed", "290 km/h", y: 0.5) + row("Power", "503 hp", y: 0.56) + row("Category", "Street", y: 0.62)
        XCTAssertEqual(SetupScreenMatcher.read(car)[.car]?.value, "BMW M4 Competition")
        XCTAssertEqual(SetupScreenMatcher.read(car)[.car]?.summary, "Top speed 290 km/h · Power 503 hp")
        XCTAssertNil(SetupScreenMatcher.read([title] + row("Top Speed", "290 km/h", y: 0.5))[.car], "One spec row is not a car screen")
    }

    func testAReadingNeedsTwoScansInARowToCount() {
        var confirmer = SetupReadingConfirmer()
        let metric = [SetupItemID.speedUnit: SetupReading(value: "km/h", summary: "km/h")]
        let imperial = [SetupItemID.speedUnit: SetupReading(value: "mph", summary: "mph")]
        XCTAssertTrue(confirmer.confirm(metric).isEmpty)
        XCTAssertEqual(confirmer.confirm(metric), metric)
        XCTAssertTrue(confirmer.confirm(imperial).isEmpty, "A different value starts over")
        XCTAssertTrue(confirmer.confirm([:]).isEmpty)
        XCTAssertTrue(confirmer.confirm(imperial).isEmpty, "A gap starts over")
        confirmer.reset()
        XCTAssertTrue(confirmer.confirm(imperial).isEmpty)
    }

    func testBriefDropoutIsHeldButARealLossShows() {
        var stabilizer = SetupSignalStabilizer()
        XCTAssertTrue(stabilizer.update(signals(), at: 10).minimapVisible)
        let lost = signals(minimap: false, route: false, noWaypoint: true, speed: false)

        let brief = stabilizer.update(lost, at: 11.5)
        XCTAssertTrue(brief.minimapVisible && brief.routeDetected && brief.speedReadable)
        XCTAssertFalse(brief.noWaypoint, "A held route cannot also be a missing waypoint")

        let gone = stabilizer.update(lost, at: 12.1)
        XCTAssertFalse(gone.minimapVisible || gone.routeDetected || gone.speedReadable)
        XCTAssertTrue(gone.noWaypoint)
    }

    func testHoldDoesNotCrossASourceChangeOrABackwardClock() {
        var stabilizer = SetupSignalStabilizer()
        _ = stabilizer.update(signals(), at: 10)
        // The analyzer reports size 0 right after a reset.
        _ = stabilizer.update(signals(width: 0, height: 0, minimap: false, route: false, speed: false), at: 10.5)
        XCTAssertFalse(stabilizer.update(signals(minimap: false, route: false, speed: false), at: 11).minimapVisible)

        _ = stabilizer.update(signals(), at: 20)
        XCTAssertFalse(stabilizer.update(signals(minimap: false, route: false, speed: false), at: 19).minimapVisible)
    }

    func testPanelOpensOnceAfterTheGraceAndClosesWhenReady() {
        var panel = SetupChecklistPresentation()
        panel.update(isReady: false, at: 100)
        panel.update(isReady: false, at: 102)
        XCTAssertFalse(panel.isExpanded, "Detection gets a moment before the panel appears")
        panel.update(isReady: false, at: 102.6)
        XCTAssertTrue(panel.isExpanded)

        panel.update(isReady: true, at: 105)
        XCTAssertTrue(panel.isExpanded, "A single ready sample is not enough")
        panel.update(isReady: true, at: 106.6)
        XCTAssertFalse(panel.isExpanded)

        // Losing the route mid-drive flags the button; it never reopens the panel.
        panel.update(isReady: false, at: 200)
        panel.update(isReady: false, at: 204)
        XCTAssertFalse(panel.needsAttention)
        panel.update(isReady: false, at: 205.1)
        XCTAssertTrue(panel.needsAttention)
        XCTAssertFalse(panel.isExpanded)
        panel.update(isReady: true, at: 206)
        XCTAssertFalse(panel.needsAttention)
    }

    func testAlreadyReadySessionNeverShowsThePanel() {
        var panel = SetupChecklistPresentation()
        for step in 0..<20 { panel.update(isReady: true, at: 50 + Double(step) * 0.5) }
        XCTAssertFalse(panel.isExpanded)
        panel.update(isReady: false, at: 70)
        panel.update(isReady: false, at: 73)
        XCTAssertFalse(panel.isExpanded, "After setup completed once, only the player reopens it")
    }

    func testThePlayerKeepsControlOfThePanel() {
        // Editing an answer keeps the panel open even once everything is ready.
        var editing = SetupChecklistPresentation()
        editing.update(isReady: false, at: 10)
        editing.update(isReady: false, at: 13)
        XCTAssertTrue(editing.isExpanded)
        editing.userInteracted()
        editing.update(isReady: true, at: 14)
        editing.update(isReady: true, at: 20)
        XCTAssertTrue(editing.isExpanded)
        editing.toggle()
        XCTAssertFalse(editing.isExpanded)

        // Closing it early stops the automatic opening.
        var dismissed = SetupChecklistPresentation()
        dismissed.update(isReady: false, at: 10)
        dismissed.toggle()
        dismissed.toggle()
        XCTAssertFalse(dismissed.isExpanded)
        dismissed.update(isReady: false, at: 30)
        XCTAssertFalse(dismissed.isExpanded)
        XCTAssertTrue(dismissed.needsAttention)

        // Opening it by hand clears the warning and keeps it open when ready.
        dismissed.toggle()
        XCTAssertTrue(dismissed.isExpanded)
        XCTAssertFalse(dismissed.needsAttention)
        dismissed.update(isReady: true, at: 40)
        dismissed.update(isReady: true, at: 45)
        XCTAssertTrue(dismissed.isExpanded)
    }
}
