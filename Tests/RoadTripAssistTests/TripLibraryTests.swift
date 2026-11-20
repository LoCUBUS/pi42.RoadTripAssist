import CoreLocation
import XCTest
@testable import RoadTripAssist

final class TripLibraryTests: XCTestCase {
    func testStageBudgetUsesHoursAndMinutesWithoutChangingStoredValues() {
        XCTAssertEqual(DurationInputFormat.string(390), "06:30")
        XCTAssertEqual(DurationInputFormat.minutes("06:30"), 390)
        XCTAssertEqual(DurationInputFormat.minutes("6:30"), 390)
        XCTAssertEqual(DurationInputFormat.minutes("26:15"), 1575)
        XCTAssertEqual(DurationInputFormat.minutes(DurationInputFormat.string(Int.max)), Int.max)
        for invalid in ["390", "06:60", "06:3", "00:00", "-01:30", "1:30:", "\(Int.max):00"] {
            XCTAssertNil(DurationInputFormat.minutes(invalid), invalid)
        }
    }

    func testStayDurationAllowsZeroButRejectsInvalidMinutes() {
        XCTAssertEqual(DurationInputFormat.minutes("00:00", allowsZero: true), 0)
        XCTAssertEqual(DurationInputFormat.minutes("01:15", allowsZero: true), 75)
        XCTAssertNil(DurationInputFormat.minutes("00:60", allowsZero: true))
    }

    @MainActor
    func testStageDetailsAndProgressSurviveReopeningAndStayWithTheWaypoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appendingPathComponent("trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Etappenreise", notes: "")
        let start = stop("Start", longitude: 0)
        let hotel = stop("Hotel", longitude: 1)
        let finish = stop("Ziel", longitude: 2)
        library.planner.setStart(start)
        library.planner.setDestination(finish)
        library.planner.addStop(hotel)
        library.planner.setDefaultStageBudget(300)
        library.planner.updateDetails(WaypointDetails(stayMinutes: 45, notes: "Späte Ankunft", rating: 4,
                                                       overnight: true, stageBudgetMinutes: 240), for: hotel)
        library.planner.setVisitStatus(.skipped, for: hotel)

        let reopened = TripLibrary(store: store)
        let model = reopened.planner
        XCTAssertEqual(model.stages.map(\.budgetMinutes), [240, 300])
        XCTAssertEqual(model.waypointDetails(for: hotel),
                       WaypointDetails(stayMinutes: 45, notes: "Späte Ankunft", rating: 4, status: .skipped,
                                       overnight: true, stageBudgetMinutes: 240))
        XCTAssertEqual(model.nextWaypoint, finish)
        model.setVisitStatus(.pending, for: hotel)
        XCTAssertEqual(model.nextWaypoint, hotel)
        model.removeStop(hotel)
        XCTAssertEqual(model.stages.map(\.id), [finish.id])
        XCTAssertNil(try store.load().first?.waypoints.details[hotel.id])
    }
    @MainActor
    func testTripsAndOrderedWaypointsSurviveReopeningAndStaySeparate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "data/trips.json"))
        let start = stop("Start", longitude: 0)
        let first = stop("Erster Halt", longitude: 1)
        let second = stop("Zweiter Halt", longitude: 2)
        let destination = stop("Ziel", longitude: 3)
        let fasterPairs = [[start, second], [second, first], [first, destination]]
        let planner = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            RouteLeg(duration: fasterPairs.contains([from, to]) ? 1 : 10,
                     distance: 100, coordinates: [])
        })
        let library = TripLibrary(store: store, planner: planner)
        XCTAssertNil(library.loadError)
        XCTAssertTrue(library.trips.isEmpty)
        library.updateTrip(id: nil, name: "Tour", notes: "")
        let tourID = try XCTUnwrap(library.selectedID)
        library.updateTrip(id: tourID, name: "  Alpen  ", notes: "Über die Alpen")

        library.planner.setStart(start)
        library.planner.setDestination(destination)
        library.planner.addStop(second)
        library.planner.addStop(first)
        XCTAssertEqual(library.planner.stops, [first, second])
        library.planner.enableAutomaticRouting()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while library.planner.isOptimizing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.planner.suggestion?.orderedStops, [second, first])
        library.planner.acceptSuggestion()
        library.updateTrip(id: nil, name: "Küste", notes: "")
        let coastID = try XCTUnwrap(library.selectedID)
        XCTAssertTrue(library.planner.orderedWaypoints.isEmpty)
        XCTAssertFalse(library.planner.automaticRouting)
        XCTAssertNil(library.planner.roadPreview)
        let coastStart = stop("Küste", longitude: 5)
        library.planner.setStart(coastStart)
        XCTAssertNil(library.saveError)

        let reopened = TripLibrary(store: store)
        XCTAssertEqual(reopened.selectedID, tourID)
        XCTAssertEqual(reopened.selectedTrip?.name, "Alpen")
        XCTAssertEqual(reopened.selectedTrip?.notes, "Über die Alpen")
        XCTAssertEqual(reopened.planner.orderedWaypoints, [start, second, first, destination])
        XCTAssertEqual(reopened.planner.stops.map { $0.coordinate.longitude }, [2, 1])
        XCTAssertFalse(reopened.planner.automaticRouting)
        reopened.select(coastID)
        XCTAssertEqual(reopened.planner.orderedWaypoints, [coastStart])

        reopened.delete(coastID)
        XCTAssertEqual(reopened.selectedID, tourID)
        XCTAssertEqual(reopened.planner.orderedWaypoints, [start, second, first, destination])
        XCTAssertEqual(try store.load().map(\.id), [tourID])
    }

    @MainActor
    func testUnreadableArchiveIsNotOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let brokenArchive = Data("invalid JSON".utf8)
        try brokenArchive.write(to: store.url)

        let library = TripLibrary(store: store)
        XCTAssertNotNil(library.loadError)
        library.updateTrip(id: nil, name: "Neue Reise", notes: "")
        XCTAssertTrue(library.trips.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.url), brokenArchive)
    }

    @MainActor
    func testManualOrderPersistsAcrossEditsAndReopening() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let start = stop("Start", longitude: 0)
        let a = stop("A", longitude: 1)
        let b = stop("B", longitude: 2)
        let end = stop("Ziel", longitude: 4)
        let c = stop("C", longitude: 3)
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Tour", notes: "")
        library.planner.setStart(start)
        library.planner.setDestination(end)
        library.planner.addStop(a)
        library.planner.addStop(b)
        library.planner.moveStop(b, by: -1)
        library.planner.addStop(c)
        XCTAssertEqual(library.planner.stops, [b, a, c])

        let reopened = TripLibrary(store: store)
        XCTAssertTrue(reopened.planner.manualOrder)
        XCTAssertEqual(reopened.planner.stops, [b, a, c])
        reopened.planner.useProvisionalOrder()
        XCTAssertEqual(reopened.planner.stops, [a, b, c])
        XCTAssertFalse(try store.load()[0].waypoints.manualOrder)
    }

    func testOlderWaypointsDecodeWithoutManualOrder() throws {
        let waypoints = try JSONDecoder().decode(TripWaypoints.self, from: Data("{\"stops\":[]}".utf8))
        XCTAssertFalse(waypoints.manualOrder)
        XCTAssertTrue(waypoints.stops.isEmpty)
    }

    @MainActor
    func testSaveFailureCanBeRetriedWithoutLosingChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)

        library.updateTrip(id: nil, name: "Tour", notes: "")
        XCTAssertNotNil(library.saveError)
        XCTAssertEqual(library.selectedTrip?.name, "Tour")

        try FileManager.default.removeItem(at: store.url)
        library.save()
        XCTAssertNil(library.saveError)
        XCTAssertEqual(try store.load().map(\.name), ["Tour"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func stop(_ name: String, longitude: Double) -> RoadStop {
        RoadStop(name: name, subtitle: "", coordinate: .init(latitude: 0, longitude: longitude))
    }
}
