import MapKit
import XCTest

final class RoadTripAssistUITests: XCTestCase {
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
