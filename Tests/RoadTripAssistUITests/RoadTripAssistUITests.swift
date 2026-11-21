import AppKit
import MapKit
import XCTest

final class RoadTripAssistUITests: XCTestCase {
    @MainActor
    func testWaypointCategoryAndOvernightSurviveReopening() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        let stageList = app.descendants(matching: .any)["stage-list"].firstMatch
        XCTAssertTrue(stageList.waitForExistence(timeout: 5))
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        app.buttons["stage-waypoint-2"].click()
        XCTAssertTrue(app.descendants(matching: .any)["inline-waypoint-details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        let category = app.popUpButtons["waypoint-category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.click()
        app.menuItems["View Point"].click()
        app.buttons["save-waypoint-details"].click()
        XCTAssertFalse(app.descendants(matching: .any)["inline-waypoint-details"].exists)
        assertValue("View Point", of: app.descendants(matching: .any)["stage-waypoint-2"].firstMatch)
        app.buttons["waypoint-details-2"].click()
        app.checkBoxes["waypoint-overnight"].click()
        app.buttons["save-waypoint-details"].click()
        XCTAssertTrue(app.buttons["show-stage-2"].waitForExistence(timeout: 5))
        assertValue("Übernachtung", of: app.descendants(matching: .any)["stage-waypoint-2"].firstMatch)
        app.terminate()

        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        let reopenedList = app.descendants(matching: .any)["stage-list"].firstMatch
        reopenedList.scroll(byDeltaX: 0, deltaY: -180)
        assertValue("Übernachtung", of: app.descendants(matching: .any)["stage-waypoint-2"].firstMatch)
        app.buttons["toggle-overnight-2"].click()
        assertValue("View Point", of: app.descendants(matching: .any)["stage-waypoint-2"].firstMatch)
        app.buttons["waypoint-details-2"].click()
        XCTAssertEqual(category.value as? String, "View Point")
        category.click()
        app.menuItems["Keine Kategorie"].click()
        app.buttons["save-waypoint-details"].click()
        assertValue("Wegpunkt", of: app.descendants(matching: .any)["stage-waypoint-2"].firstMatch)
    }

    @MainActor
    func testInlineWaypointDetailsProtectUnsavedChanges() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        let stageList = app.descendants(matching: .any)["stage-list"].firstMatch
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        let row = app.buttons["stage-waypoint-2"]
        row.click()
        let stay = app.textFields["waypoint-stay"]
        XCTAssertTrue(stay.waitForExistence(timeout: 5))
        stay.click()
        stay.typeKey("a", modifierFlags: .command)
        stay.typeText("00:25")
        app.buttons["waypoint-details-1"].click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Weiter bearbeiten"].click()
        assertValue("00:25", of: stay)
        app.buttons["new-trip"].click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Weiter bearbeiten"].click()
        assertValue("00:25", of: stay)
        row.click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Weiter bearbeiten"].click()
        assertValue("00:25", of: stay)
        app.radioButtons["Route"].click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Verwerfen"].click()
        XCTAssertFalse(app.descendants(matching: .any)["inline-waypoint-details"].exists)
        app.radioButtons["Etappen"].click()
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        row.click()
        assertValue("00:00", of: stay)
        app.buttons["cancel-waypoint-details"].click()
        XCTAssertFalse(app.descendants(matching: .any)["inline-waypoint-details"].exists)
    }

    @MainActor
    func testInlineStageBudgetCanBeEditedAndInheritsDefault() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        app.buttons["default-stage-budget"].click()
        let defaultBudget = app.textFields["default-stage-budget-input"]
        XCTAssertTrue(defaultBudget.waitForExistence(timeout: 5))
        defaultBudget.click()
        defaultBudget.typeText("06:30")
        app.buttons["Speichern"].click()

        let heading = app.buttons["stage-details-1"]
        heading.click()
        let budget = app.textFields["stage-budget-input"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        budget.click()
        budget.typeText("00:00")
        XCTAssertFalse(app.buttons["save-stage-budget"].isEnabled)
        budget.typeKey("a", modifierFlags: .command)
        budget.typeText("01:15")
        heading.click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Weiter bearbeiten"].click()
        assertValue("01:15", of: budget)
        app.radioButtons["Route"].click()
        XCTAssertTrue(app.sheets["alert"].buttons["Weiter bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Weiter bearbeiten"].click()
        app.buttons["save-stage-budget"].click()
        XCTAssertTrue(app.staticTexts["Zeitbudget: 01:15"].waitForExistence(timeout: 5))

        app.terminate()
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        XCTAssertTrue(app.staticTexts["Zeitbudget: 01:15"].waitForExistence(timeout: 5))
        heading.click()
        assertValue("01:15", of: budget)
        budget.click()
        budget.typeKey("a", modifierFlags: .command)
        budget.typeKey(.delete, modifierFlags: [])
        app.buttons["save-stage-budget"].click()
        XCTAssertTrue(app.staticTexts["Zeitbudget: 06:30"].waitForExistence(timeout: 5))
        heading.click()
        assertValue("", of: budget)
        app.buttons["cancel-stage-budget"].click()
    }

    @MainActor
    func testRouteInspectorCanBeHiddenAndRestored() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        let route = app.textFields["waypoint-start"]
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        let toggle = app.buttons["toggle-route-inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertFalse(route.exists)
        toggle.click()
        assertValue("Startstadt", of: route)
        assertValue("Zielstadt", of: app.textFields["waypoint-destination"])
    }

    @MainActor
    func testRemovingOvernightStopFromStageRequiresConfirmation() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        let stageList = app.descendants(matching: .any)["stage-list"].firstMatch
        XCTAssertTrue(stageList.waitForExistence(timeout: 5))
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        app.buttons["toggle-overnight-2"].click()

        let stageTwo = app.buttons["show-stage-2"]
        XCTAssertTrue(stageTwo.waitForExistence(timeout: 5))
        let removeStop = app.buttons["remove-stage-waypoint-2"]
        XCTAssertFalse(app.buttons["remove-stage-waypoint-1"].exists)
        XCTAssertFalse(app.buttons["remove-stage-waypoint-3"].exists)
        removeStop.click()
        app.buttons["Abbrechen"].click()
        XCTAssertTrue(removeStop.exists)
        XCTAssertTrue(stageTwo.exists)

        removeStop.click()
        app.buttons["Entfernen"].click()
        XCTAssertFalse(stageTwo.exists)
        XCTAssertFalse(removeStop.exists)
        app.radioButtons["Route"].click()
        assertValue("Startstadt", of: app.textFields["waypoint-start"])
        assertValue("Zielstadt", of: app.textFields["waypoint-destination"])
        XCTAssertFalse(app.textFields["waypoint-stop-1"].exists)
    }

    @MainActor
    func testLateOvernightBudgetPointCanBeHiddenAndRestored() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        app.buttons["default-stage-budget"].click()
        let budget = app.textFields["default-stage-budget-input"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        budget.click()
        budget.typeText("00:05")
        app.buttons["Speichern"].click()
        let stageList = app.descendants(matching: .any)["stage-list"].firstMatch
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        app.buttons["toggle-overnight-2"].click()
        stageList.scroll(byDeltaX: 0, deltaY: 400)
        app.buttons["Automatische Berechnung aktivieren"].click()
        app.buttons["Aktivieren"].click()

        let point = app.buttons["budget-placeholder-1"]
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        let confirm = app.buttons["confirm-budget-overrun-1"]
        XCTAssertEqual(confirm.label, "Übernachtung 5 min nach Budget bestätigen")
        confirm.click()
        app.buttons["Abbrechen"].click()
        XCTAssertTrue(point.exists)
        confirm.click()
        app.buttons["Budgetpunkt ausblenden"].click()
        XCTAssertFalse(point.exists)
        XCTAssertTrue(app.buttons["budget-placeholder-2"].exists)
        app.buttons["restore-budget-point-1"].click()
        XCTAssertTrue(point.waitForExistence(timeout: 5))
    }

    @MainActor
    func testStageBudgetPlaceholderFocusesSearchAreaWithoutAddingAStop() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments += ["--ui-testing-stages", "--ui-testing-budget-placeholder"]
        launchPlanner(app)
        app.radioButtons["Etappen"].click()
        app.buttons["default-stage-budget"].click()
        let budget = app.textFields["default-stage-budget-input"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        budget.click()
        budget.typeText("00:05")
        app.buttons["Speichern"].click()
        let placeholder = app.buttons["budget-placeholder-1"]
        XCTAssertFalse(placeholder.exists)

        app.buttons["Automatische Berechnung aktivieren"].click()
        app.buttons["Aktivieren"].click()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        placeholder.click()
        let stageButton = app.buttons["show-stage-1"]
        XCTAssertEqual(stageButton.label, "Auf der Karte ausgewählt")
        XCTAssertTrue(app.buttons["Gesamtroute auf der Karte"].exists)
        XCTAssertFalse(app.buttons["show-stage-2"].exists)
        let map = app.descendants(matching: .any)["planner-map"].firstMatch
        app.buttons["default-stage-budget"].click()
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        budget.click()
        budget.typeKey("a", modifierFlags: .command)
        budget.typeKey(.delete, modifierFlags: [])
        app.buttons["Speichern"].click()
        XCTAssertFalse(placeholder.exists)
        let withoutCircle = map.screenshot()
        app.buttons["default-stage-budget"].click()
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        budget.click()
        budget.typeText("00:05")
        app.buttons["Speichern"].click()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        assertCircleOutline(map.screenshot(), comparedTo: withoutCircle)
        app.radioButtons["Route"].click()
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
        XCTAssertFalse(app.textFields["waypoint-stop-2"].exists)
    }

    private func assertCircleOutline(_ withCircle: XCUIScreenshot, comparedTo withoutCircle: XCUIScreenshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for (name, screenshot) in [("With search circle", withCircle), ("Without search circle", withoutCircle)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            add(attachment)
        }
        guard let marked = NSBitmapImageRep(data: withCircle.pngRepresentation),
              let unmarked = NSBitmapImageRep(data: withoutCircle.pngRepresentation),
              marked.pixelsWide == unmarked.pixelsWide, marked.pixelsHigh == unmarked.pixelsHigh else {
            XCTFail("Could not compare map screenshots of the same size", file: file, line: line)
            return
        }
        let span = min(marked.pixelsWide, marked.pixelsHigh)
        let centerX = marked.pixelsWide / 2
        let centerY = marked.pixelsHigh / 2
        var interiorSamples = 0
        var changedInterior = 0
        var orangeOutline = 0
        for dy in stride(from: -span * 2 / 5, through: span * 2 / 5, by: 2) {
            for dx in stride(from: -span * 2 / 5, through: span * 2 / 5, by: 2) {
                let radius = hypot(Double(dx), Double(dy)) / Double(span)
                // Skip the center marker and route, which passes horizontally through this fixture.
                let interior = radius < 0.19 && abs(dy) > span / 12
                let outline = (0.20...0.37).contains(radius)
                guard interior || outline,
                      let before = marked.colorAt(x: centerX + dx, y: centerY + dy)?.usingColorSpace(.sRGB),
                      let after = unmarked.colorAt(x: centerX + dx, y: centerY + dy)?.usingColorSpace(.sRGB)
                else { continue }
                let changed = max(abs(before.redComponent - after.redComponent),
                                  abs(before.greenComponent - after.greenComponent),
                                  abs(before.blueComponent - after.blueComponent)) > 0.04
                if interior {
                    interiorSamples += 1
                    if changed { changedInterior += 1 }
                } else if changed && before.redComponent > 0.7 &&
                            before.redComponent - before.greenComponent > 0.15 &&
                            before.greenComponent - before.blueComponent > 0.15 {
                    orangeOutline += 1
                }
            }
        }
        XCTAssertGreaterThan(orangeOutline, 40, "The orange outline must be visible", file: file, line: line)
        XCTAssertGreaterThan(interiorSamples, 0, file: file, line: line)
        XCTAssertLessThan(Double(changedInterior) / Double(max(1, interiorSamples)), 0.05,
                          "The map inside the circle must remain unchanged", file: file, line: line)
    }

    private func assertAlternativeLines(before: XCUIScreenshot, shown: XCUIScreenshot, hidden: XCUIScreenshot,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let before = NSBitmapImageRep(data: before.pngRepresentation),
              let shown = NSBitmapImageRep(data: shown.pngRepresentation),
              let hidden = NSBitmapImageRep(data: hidden.pngRepresentation),
              before.pixelsWide == shown.pixelsWide, before.pixelsHigh == shown.pixelsHigh,
              before.pixelsWide == hidden.pixelsWide, before.pixelsHigh == hidden.pixelsHigh else {
            XCTFail("Could not compare map screenshots of the same size", file: file, line: line)
            return
        }
        var appeared = 0
        var disappeared = 0
        for y in stride(from: shown.pixelsHigh / 5, to: shown.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: shown.pixelsWide, by: 2) {
                guard let original = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let purple = shown.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let restored = hidden.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let changed = max(abs(purple.redComponent - original.redComponent),
                                  abs(purple.greenComponent - original.greenComponent),
                                  abs(purple.blueComponent - original.blueComponent)) > 0.1
                if changed && purple.redComponent - purple.greenComponent > 0.12 &&
                    purple.blueComponent - purple.greenComponent > 0.12 {
                    appeared += 1
                    if max(abs(restored.redComponent - original.redComponent),
                           abs(restored.greenComponent - original.greenComponent),
                           abs(restored.blueComponent - original.blueComponent)) < 0.1 {
                        disappeared += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(appeared, 20, "Alternative lines must be visible", file: file, line: line)
        XCTAssertGreaterThan(disappeared, 20, "Alternative lines must disappear when hidden", file: file, line: line)
    }

    @MainActor
    func testSplitStageAndSkipToNextMapsDestination() throws {
        continueAfterFailure = false
        let (app, directory) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-stages")
        launchPlanner(app)

        app.radioButtons["Etappen"].click()
        assertValue("Nächstes Ziel: Zwischenstadt A", of: app.staticTexts["next-waypoint"])
        app.buttons["default-stage-budget"].click()
        let defaultBudget = app.textFields["default-stage-budget-input"]
        XCTAssertTrue(defaultBudget.waitForExistence(timeout: 5))
        defaultBudget.click()
        defaultBudget.typeText("06:30")
        app.buttons["Speichern"].click()
        XCTAssertEqual(app.buttons["default-stage-budget"].label, "Standard-Zeitbudget: 06:30")

        let stageList = app.descendants(matching: .any)["stage-list"].firstMatch
        XCTAssertTrue(stageList.waitForExistence(timeout: 5))
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        let overnight = app.buttons["toggle-overnight-2"]
        XCTAssertTrue(overnight.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toggle-overnight-1"].exists)
        app.buttons["open-stage-waypoint-2"].click()
        try assertHandoff(in: directory, name: "Zwischenstadt A", longitude: "12.0")
        let secondStage = app.buttons["show-stage-2"]
        overnight.click()
        XCTAssertTrue(secondStage.waitForExistence(timeout: 5))
        overnight.click()
        XCTAssertFalse(secondStage.exists)
        overnight.click()
        XCTAssertTrue(secondStage.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toggle-overnight-3"].exists)
        let details = app.buttons["waypoint-details-2"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.click()
        let budget = app.textFields["stage-budget-override"]
        XCTAssertTrue(budget.waitForExistence(timeout: 3))
        let stay = app.textFields["waypoint-stay"]
        assertValue("00:00", of: stay)
        stay.click()
        stay.typeKey("a", modifierFlags: .command)
        stay.typeText("00:45")
        budget.click()
        budget.typeText("01:15")
        app.buttons["save-waypoint-details"].click()
        XCTAssertTrue(app.buttons["show-stage-2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value == %@", "Zeitbudget: 01:15"))
            .firstMatch.waitForExistence(timeout: 5))
        stageList.scroll(byDeltaX: 0, deltaY: 400)
        app.buttons["stage-details-1"].click()
        let stageBudget = app.textFields["stage-budget-input"]
        assertValue("01:15", of: stageBudget)
        stageBudget.click()
        stageBudget.typeKey("a", modifierFlags: .command)
        stageBudget.typeText("01:20")
        app.buttons["save-stage-budget"].click()
        XCTAssertTrue(app.staticTexts["Zeitbudget: 01:20"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Zeitbudget: 06:30"].waitForExistence(timeout: 5))
        assertValue("Verweilzeit: 45 min", of: app.staticTexts["Verweilzeit: 45 min"].firstMatch)
        let stageTime = app.staticTexts["stage-totals-1"]
        assertValue("Etappenzeit: 45 min + ausstehende Fahrzeit", of: stageTime)

        stageList.scroll(byDeltaX: 0, deltaY: 400)
        app.buttons["Automatische Berechnung aktivieren"].click()
        app.buttons["Aktivieren"].click()
        assertValue("Etappenzeit: 55 min · davon Fahrt: 10 min", of: stageTime)
        stageList.scroll(byDeltaX: 0, deltaY: -180)
        details.click()
        assertValue("00:45", of: stay)
        stay.click()
        stay.typeKey("a", modifierFlags: .command)
        stay.typeText("01:15")
        app.buttons["save-waypoint-details"].click()
        assertValue("Etappenzeit: 1 h 25 min · davon Fahrt: 10 min", of: stageTime)

        stageList.scroll(byDeltaX: 0, deltaY: 400)
        app.buttons["open-next-waypoint"].click()
        try assertHandoff(in: directory, name: "Zwischenstadt A", longitude: "12.0")
        app.buttons["skip-next-waypoint"].click()
        assertValue("Nächstes Ziel: Zielstadt", of: app.staticTexts["next-waypoint"])
        app.buttons["open-next-waypoint"].click()
        try assertHandoff(in: directory, name: "Zielstadt", longitude: "14.0")
    }
    @MainActor
    func testMapPOICanBeAddedDirectlyAsAnOvernightStop() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments += ["--ui-testing-stages", "--ui-testing-poi"]
        launchPlanner(app)
        let map = app.descendants(matching: .any)["planner-map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertValue("Testcafe", of: app.staticTexts["map-poi-name"])
        let overnight = app.buttons["add-map-poi-overnight"]
        overnight.click()
        assertValue("Testcafe", of: app.textFields["waypoint-stop-2"])
        XCTAssertFalse(overnight.isEnabled)
        XCTAssertFalse(app.buttons["add-map-poi"].isEnabled)
        app.radioButtons["Etappen"].click()
        XCTAssertTrue(app.buttons["show-stage-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["toggle-overnight-3"].label, "Übernachtungsmarkierung entfernen")
    }

    @MainActor
    func testMapPOIDetailsAndAddToRoute() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-poi")
        launchPlanner(app)
        createTrip(in: app)
        choose("Startstadt", in: "start", app: app)
        choose("Zielstadt", in: "destination", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt A", in: "new-stop", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt B", in: "new-stop", app: app)

        let map = app.descendants(matching: .any)["planner-map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let add = app.buttons["add-map-poi"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        assertValue("Kein Ort an dieser Stelle gefunden.", of: app.staticTexts["map-poi-message"])
        XCTAssertFalse(add.exists)

        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertValue("Testcafe", of: app.staticTexts["map-poi-name"])
        assertValue("Teststraße 1", of: app.staticTexts["map-poi-address"])
        XCTAssertFalse(app.textFields["waypoint-stop-3"].exists)
        XCTAssertTrue(add.isEnabled)
        add.click()

        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
        assertValue("Testcafe", of: app.textFields["waypoint-stop-2"])
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-3"])
        XCTAssertFalse(add.isEnabled)
    }

    @MainActor
    func testPlanTripReorderStopsAndReopenTrip() throws {
        continueAfterFailure = false
        let (app, directory) = try makeTestApp()
        defer { app.terminate() }
        launchPlanner(app)
        createTrip(in: app)

        choose("Startstadt", in: "start", app: app)
        choose("Zielstadt", in: "destination", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt A", in: "new-stop", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt B", in: "new-stop", app: app)
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-2"])

        app.buttons["Automatische Berechnung aktivieren"].click()
        app.buttons["Aktivieren"].click()
        let distance = app.staticTexts["route-distance"]
        assertValue("Strecke: 3 km", of: distance)
        app.buttons["move-up-stop-2"].click()
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-1"])
        assertValue("Strecke: 5 km", of: distance)

        app.buttons["open-maps-stop-1"].click()
        try assertHandoff(in: directory, name: "Zwischenstadt B", longitude: "13.0")
        app.buttons["open-maps-destination"].click()
        try assertHandoff(in: directory, name: "Zielstadt", longitude: "14.0")

        app.terminate()
        launchPlanner(app)
        let trip = app.staticTexts.matching(NSPredicate(format: "value == %@", "Testreise")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 5))
        assertValue("Startstadt", of: app.textFields["waypoint-start"])
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-1"])
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-2"])
        assertValue("Zielstadt", of: app.textFields["waypoint-destination"])
        app.buttons["Nach Luftlinie sortieren"].click()
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
    }

    @MainActor
    func testOptimizationMustBeRequestedAndAccepted() throws {
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-optimization")
        launchPlanner(app)
        createTrip(in: app)
        choose("Startstadt", in: "start", app: app)
        choose("Zielstadt", in: "destination", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt A", in: "new-stop", app: app)
        app.buttons["Zwischenziel hinzufügen"].click()
        choose("Zwischenstadt B", in: "new-stop", app: app)
        app.buttons["Automatische Berechnung aktivieren"].click()
        app.buttons["Aktivieren"].click()
        assertValue("Strecke: 3 km", of: app.staticTexts["route-distance"])
        app.buttons["move-up-stop-2"].click()
        assertValue("Strecke: 5 km", of: app.staticTexts["route-distance"])
        XCTAssertFalse(app.buttons["Vorschlag übernehmen"].exists)
        app.buttons["optimize-route"].click()
        let accept = app.buttons["Vorschlag übernehmen"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-1"])
        let controls = app.descendants(matching: .any)["routing-controls"].firstMatch
        XCTAssertTrue(controls.exists)
        XCTAssertLessThanOrEqual(controls.frame.height, 160, "Routing controls should leave room for the waypoint list")
        let map = app.descendants(matching: .any)["planner-map"].firstMatch
        let beforeAlternatives = map.screenshot()
        app.buttons["alternative-connections"].click()
        let showAlternatives = app.descendants(matching: .any)["show-alternative-connections"].firstMatch
        XCTAssertTrue(showAlternatives.waitForExistence(timeout: 5))
        showAlternatives.click()
        XCTAssertTrue(app.staticTexts["map-alternatives-indicator"].exists)
        let shownAlternatives = map.screenshot()
        let connection = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Startstadt → Zwischenstadt A")
        ).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.click()
        XCTAssertTrue(connection.label.contains("ausgewählt"))
        showAlternatives.click()
        XCTAssertFalse(app.staticTexts["map-alternatives-indicator"].exists)
        assertAlternativeLines(before: beforeAlternatives, shown: shownAlternatives, hidden: map.screenshot())
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Vorschlagsdetails"].click()
        let order = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Zwischenstadt A → Zwischenstadt B")
        ).firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Vorschlag auf Karte zeigen"].click()
        XCTAssertTrue(app.buttons["Aktuelle Route auf Karte zeigen"].exists)
        XCTAssertTrue(app.staticTexts["map-suggestion-indicator"].exists)
        assertValue("Zwischenstadt B", of: app.textFields["waypoint-stop-1"])
        app.buttons["Aktuelle Route auf Karte zeigen"].click()
        XCTAssertFalse(app.staticTexts["map-suggestion-indicator"].exists)
        accept.click()
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
        assertValue("Strecke: 3 km", of: app.staticTexts["route-distance"])
        app.terminate()
        launchPlanner(app)
        assertValue("Zwischenstadt A", of: app.textFields["waypoint-stop-1"])
        XCTAssertTrue(app.buttons["Nach Luftlinie sortieren"].exists)
    }

    @MainActor
    func testAppleMapsOpensPublicLandmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROADTRIP_LIVE_MAPS"] == "1",
                          "Opt in to opening Apple Maps with a public destination.")
        continueAfterFailure = false
        let (app, _) = try makeTestApp()
        defer { app.terminate() }
        app.launchArguments.append("--ui-testing-open-maps")
        launchPlanner(app)
        createTrip(in: app)
        choose("Brandenburger Tor", in: "destination", app: app)
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        app.buttons["open-maps-destination"].click()
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(maps.windows.firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    private func makeTestApp() throws -> (XCUIApplication, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoadTripAssistUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLocale", "de_DE", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["ROADTRIP_UI_TEST_DIRECTORY"] = directory.path
        return (app, directory)
    }

    @MainActor
    private func createTrip(in app: XCUIApplication) {
        app.buttons["new-trip"].click()
        let name = app.textFields["trip-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText("Testreise")
        XCTAssertEqual(name.value as? String, "Testreise")
        app.buttons["Speichern"].click()
    }

    @MainActor
    private func launchPlanner(_ app: XCUIApplication) {
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuItems["Routenplaner öffnen"].click()
        }
        XCTAssertTrue(app.buttons["new-trip"].waitForExistence(timeout: 5), "Planner window did not open")
    }

    @MainActor
    private func choose(_ city: String, in id: String, app: XCUIApplication) {
        let field = app.textFields["waypoint-\(id)"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(city)
        let result = app.buttons["search-result-0"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "No search result for \(city)")
        result.click()
    }

    private func assertHandoff(in directory: URL, name: String, longitude: String) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("maps-handoff.json"))
        let record = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(record, ["name": name, "longitude": longitude, "latitude": "50.0",
                                "mode": MKLaunchOptionsDirectionsModeDriving])
    }

    @MainActor
    private func assertValue(_ expected: String, of element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let match = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed, "Expected \(expected) in \(element)")
    }
}
