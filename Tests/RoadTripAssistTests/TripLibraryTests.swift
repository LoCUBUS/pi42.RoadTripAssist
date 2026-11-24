import CoreLocation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
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

    func testLegacyWaypointDetailsDecodeWithoutCategory() throws {
        let legacy = Data(#"{"stayMinutes":0,"notes":"","rating":0,"status":"pending","overnight":false}"#.utf8)
        let details = try JSONDecoder().decode(WaypointDetails.self, from: legacy)
        XCTAssertNil(details.category)
    }

    func testLegacyRoadTripDecodesWithoutPhotos() throws {
        let encoded = try JSONEncoder().encode(RoadTrip(name: "Alt", notes: ""))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "photos")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RoadTrip.self, from: legacy)
        XCTAssertTrue(decoded.photos.isEmpty)
        XCTAssertNil(decoded.departureDate)
    }

    func testLegacyPhotoDecodesWithoutRotation() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","fileExtension":"jpg","originalName":"photo.jpg"}"#.utf8)

        let photo = try JSONDecoder().decode(TripPhoto.self, from: data)

        XCTAssertEqual(photo.rotationQuarterTurns, 0)
        XCTAssertEqual(photo.caption, "")
    }

    func testPhotoMetadataReadsEXIFDateAndGPSCoordinates() throws {
        let metadata = try PhotoMetadata.read(from: makeImageData())

        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = TimeZone(secondsFromGMT: 7_200)
        dateComponents.year = 2026
        dateComponents.month = 7
        dateComponents.day = 18
        dateComponents.hour = 19
        dateComponents.minute = 25
        dateComponents.second = 30
        XCTAssertEqual(metadata.capturedAt, dateComponents.date)
        XCTAssertEqual(metadata.coordinate?.latitude, -47.25)
        XCTAssertEqual(metadata.coordinate?.longitude, 11.5)
    }

    func testPhotoAssignmentSuggestionChoosesWaypointRouteAndStage() {
        let start = stop("Start", latitude: 0, longitude: 0)
        let destination = stop("Ziel", latitude: 0, longitude: 0.1)
        let leg = RouteLeg(duration: 100, distance: 11_000, coordinates: [start.coordinate, destination.coordinate])
        let stage = TripStage(waypoints: [start, destination], legs: [leg], waypointStayMinutes: [0, 0],
                              budgetMinutes: nil, endsWithOvernight: false)

        XCTAssertEqual(
            PhotoAssignmentSuggester.suggest(
                at: CLLocationCoordinate2D(latitude: 0, longitude: 0.001), waypoints: [start, destination],
                stages: [stage], routeLegs: [leg]
            ),
            .waypoint(start.id)
        )
        XCTAssertEqual(
            PhotoAssignmentSuggester.suggest(
                at: CLLocationCoordinate2D(latitude: 0.005, longitude: 0.05), waypoints: [start, destination],
                stages: [stage], routeLegs: [leg]
            ),
            .routeSegment(from: start.id, to: destination.id)
        )
        XCTAssertEqual(
            PhotoAssignmentSuggester.suggest(
                at: CLLocationCoordinate2D(latitude: 0.05, longitude: 0.1), waypoints: [start, destination],
                stages: [stage], routeLegs: [leg]
            ),
            .stage(destination.id)
        )
        XCTAssertNil(PhotoAssignmentSuggester.suggest(
            at: CLLocationCoordinate2D(latitude: 1, longitude: 1), waypoints: [start, destination],
            stages: [stage], routeLegs: [leg]
        ))
    }

    @MainActor
    func testPhotoImportCopiesAssetAndPersistsConfirmedAssignment() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let waypoint = stop("Aussicht", latitude: -47.25, longitude: 11.5)
        library.planner.setStart(waypoint)
        let imageData = try makeImageData()
        let tripID = try XCTUnwrap(library.selectedID)

        try await library.addPhoto(data: imageData, originalName: "original.jpg", tripID: tripID)
        let trip = try XCTUnwrap(library.selectedTrip)
        let photo = try XCTUnwrap(trip.photos.first)
        XCTAssertEqual(try Data(contentsOf: library.photoURL(for: photo, tripID: trip.id)), imageData)
        XCTAssertEqual(photo.assignment, PhotoAssignment(target: .waypoint(waypoint.id), status: .suggested))

        try library.confirmPhotoSuggestion(photoID: photo.id, tripID: trip.id)
        try library.updatePhotoCaption("Abendlicht", photoID: photo.id, tripID: trip.id)
        let reopened = TripLibrary(store: store)
        let reopenedPhoto = try XCTUnwrap(reopened.selectedTrip?.photos.first)
        XCTAssertEqual(reopenedPhoto.caption, "Abendlicht")
        XCTAssertEqual(reopenedPhoto.assignment?.status, .confirmed)
        XCTAssertEqual(try reopened.photoURL(for: reopenedPhoto, tripID: trip.id).checkResourceIsReachable(), true)

        try reopened.deletePhoto(reopenedPhoto.id, tripID: trip.id)
        XCTAssertTrue(reopened.selectedTrip?.photos.isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.photoURL(for: reopenedPhoto, tripID: trip.id).path))
    }

    @MainActor
    func testPhotoLocationCanBeAddedAsWaypointAndAssigned() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TripLibrary(store: TripStore(url: directory.appending(path: "trips.json")))
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        library.planner.setStart(stop("Start", latitude: 0, longitude: 0))
        library.planner.setDestination(stop("Ziel", latitude: 1, longitude: 1))
        try await library.addPhoto(data: makeImageData(), originalName: "Aussicht.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)

        let waypoint = try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID)

        XCTAssertEqual(waypoint.name, "Aussicht")
        XCTAssertEqual(waypoint.coordinate.latitude, -47.25, accuracy: 0.0001)
        XCTAssertEqual(waypoint.coordinate.longitude, 11.5, accuracy: 0.0001)
        XCTAssertTrue(library.planner.orderedWaypoints.contains(waypoint))
        XCTAssertEqual(library.planner.waypointDetails(for: waypoint).category, .photo)
        XCTAssertEqual(library.selectedTrip?.photos.first?.assignment,
                       PhotoAssignment(target: .waypoint(waypoint.id), status: .confirmed))
    }

    @MainActor
    func testPhotoLocationReusesNearbyWaypointWithoutChangingItsDetails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TripLibrary(store: TripStore(url: directory.appending(path: "trips.json")))
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let existing = stop("Vorhandener Ort", latitude: -47.25, longitude: 11.5)
        library.planner.setStart(existing)
        library.planner.setDestination(stop("Ziel", latitude: -47, longitude: 12))
        library.planner.updateDetails(WaypointDetails(stayMinutes: 45, category: .viewpoint), for: existing)
        try await library.addPhoto(data: makeImageData(), originalName: "Aussicht.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)

        let waypoint = try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID)

        XCTAssertEqual(waypoint.id, existing.id)
        XCTAssertEqual(library.planner.orderedWaypoints.count, 2)
        XCTAssertEqual(library.planner.waypointDetails(for: existing).category, .viewpoint)
        XCTAssertEqual(library.planner.waypointDetails(for: existing).stayMinutes, 45)
        XCTAssertEqual(library.selectedTrip?.photos.first?.assignment,
                       PhotoAssignment(target: .waypoint(existing.id), status: .confirmed))
    }

    @MainActor
    func testPhotoDeletionRestoresMediaAndMetadataWhenSavingFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let data = try makeImageData()
        try await library.addPhoto(data: data, originalName: "photo.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)
        let archive = directory.appending(path: "trips.backup")
        try FileManager.default.moveItem(at: store.url, to: archive)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try library.deletePhoto(photo.id, tripID: tripID))
        XCTAssertNotNil(library.saveError)
        XCTAssertEqual(library.selectedTrip?.photos, [photo])
        XCTAssertEqual(try Data(contentsOf: library.photoURL(for: photo, tripID: tripID)), data)

        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.moveItem(at: archive, to: store.url)
        try library.deletePhoto(photo.id, tripID: tripID)
        XCTAssertTrue(library.selectedTrip?.photos.isEmpty == true)
        XCTAssertTrue(try store.load().first?.photos.isEmpty == true)
    }

    @MainActor
    func testFirstTripIsSelectedWhenNoPreviousSelectionExists() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let first = RoadTrip(name: "Erste Route", notes: "")
        let second = RoadTrip(name: "Zweite Route", notes: "")
        try store.save([first, second])

        let library = TripLibrary(store: store)

        XCTAssertEqual(library.selectedID, first.id)
        XCTAssertEqual(try store.loadSelectedTripID(), first.id)
        library.select(second.id)
        try store.saveSelectedTripID(UUID())

        let recovered = TripLibrary(store: store)

        XCTAssertEqual(recovered.selectedID, first.id)
        XCTAssertEqual(try store.loadSelectedTripID(), first.id)
    }

    @MainActor
    func testSelectedTripSaveFailureCanBeRetried() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        try FileManager.default.createDirectory(at: store.selectedTripURL, withIntermediateDirectories: false)

        library.updateTrip(id: nil, name: "Tour", notes: "")

        let selectedID = try XCTUnwrap(library.selectedID)
        XCTAssertNotNil(library.selectedTripSaveError)
        XCTAssertEqual(library.selectedTrip?.name, "Tour")

        try FileManager.default.removeItem(at: store.selectedTripURL)
        library.retrySelectedTripSave()

        XCTAssertNil(library.selectedTripSaveError)
        XCTAssertEqual(try store.loadSelectedTripID(), selectedID)
    }

    @MainActor
    func testPhotoRotationPersistsAndCanBeReversed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let imageData = try makeImageData()
        try await library.addPhoto(data: imageData, originalName: "photo.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)

        try library.rotatePhoto(photoID: photo.id, tripID: tripID, clockwise: true)
        try library.rotatePhoto(photoID: photo.id, tripID: tripID, clockwise: true)
        let reopened = TripLibrary(store: store)
        let reopenedPhoto = try XCTUnwrap(reopened.selectedTrip?.photos.first)
        XCTAssertEqual(reopenedPhoto.rotationQuarterTurns, 2)
        XCTAssertEqual(try Data(contentsOf: reopened.photoURL(for: reopenedPhoto, tripID: tripID)), imageData)

        try reopened.rotatePhoto(photoID: photo.id, tripID: tripID, clockwise: false)
        XCTAssertEqual(reopened.selectedTrip?.photos.first?.rotationQuarterTurns, 1)
        try reopened.rotatePhoto(photoID: photo.id, tripID: tripID, clockwise: false)
        XCTAssertEqual(reopened.selectedTrip?.photos.first?.rotationQuarterTurns, 0)
    }

    func testOvernightSymbolTakesPrecedenceWithoutDiscardingCategory() {
        for category in WaypointCategory.allCases {
            var details = WaypointDetails(category: category)
            XCTAssertEqual(details.systemImage, category.systemImage)
            details.overnight = true
            XCTAssertEqual(details.systemImage, "bed.double.fill")
            details.overnight = false
            XCTAssertEqual(details.systemImage, category.systemImage)
            XCTAssertEqual(details.category, category)
        }
    }

    func testWaypointAppearanceUsesCategoryOvernightAndEndpointRoles() {
        let unclassified = WaypointDetails()
        let classified = WaypointDetails(category: .viewpoint)
        let overnight = WaypointDetails(overnight: true, category: .viewpoint)

        let plain = WaypointAppearance(details: unclassified, isStart: false, isDestination: false)
        XCTAssertEqual(plain.color, .red)
        XCTAssertEqual(plain.systemImage, "mappin")
        let category = WaypointAppearance(details: classified, isStart: false, isDestination: false)
        XCTAssertEqual(category.color, .green)
        XCTAssertEqual(category.systemImage, WaypointCategory.viewpoint.systemImage)
        let hotel = WaypointAppearance(details: overnight, isStart: false, isDestination: true)
        XCTAssertEqual(hotel.color, .blue)
        XCTAssertEqual(hotel.systemImage, "bed.double.fill")
        let uncategorizedHotel = WaypointAppearance(details: WaypointDetails(overnight: true),
                                                    isStart: false, isDestination: false)
        XCTAssertEqual(uncategorizedHotel.color, .blue)
        XCTAssertEqual(uncategorizedHotel.systemImage, "bed.double.fill")
        let start = WaypointAppearance(details: unclassified, isStart: true, isDestination: false)
        XCTAssertEqual(start.color, .red)
        XCTAssertEqual(start.systemImage, "play.fill")
        let destination = WaypointAppearance(details: classified, isStart: false, isDestination: true)
        XCTAssertEqual(destination.color, .green)
        XCTAssertEqual(destination.systemImage, "flag.checkered")

        let photo = WaypointAppearance(details: WaypointDetails(category: .photo),
                                       isStart: false, isDestination: false)
        XCTAssertEqual(photo.color, .purple)
        XCTAssertEqual(photo.systemImage, "photo.fill")
        let photoWithStay = WaypointAppearance(details: WaypointDetails(stayMinutes: 1, category: .photo),
                                               isStart: false, isDestination: false)
        XCTAssertEqual(photoWithStay.color, .green)
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
                                                       overnight: true, stageBudgetMinutes: 240,
                                                       category: .viewpoint), for: hotel)
        library.planner.setVisitStatus(.skipped, for: hotel)

        let reopened = TripLibrary(store: store)
        let model = reopened.planner
        XCTAssertEqual(model.stages.map(\.budgetMinutes), [240, 300])
        XCTAssertEqual(model.waypointDetails(for: hotel),
                       WaypointDetails(stayMinutes: 45, notes: "Späte Ankunft", rating: 4, status: .skipped,
                                       overnight: true, stageBudgetMinutes: 240, category: .viewpoint))
        XCTAssertEqual(model.nextWaypoint, finish)
        model.setVisitStatus(.pending, for: hotel)
        XCTAssertEqual(model.nextWaypoint, hotel)
        model.removeStop(hotel)
        XCTAssertEqual(model.stages.map(\.id), [finish.id])
        XCTAssertNil(try store.load().first?.waypoints.details[hotel.id])
    }
    @MainActor
    func testTripDepartureDatesPersistSwitchAndCanBeRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let firstDate = Date(timeIntervalSince1970: 2_000_000_000)
        let secondDate = firstDate.addingTimeInterval(86_400)
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Erste", notes: "", departureDate: firstDate)
        let firstID = try XCTUnwrap(library.selectedID)
        XCTAssertEqual(library.planner.departureDate, firstDate)
        library.updateTrip(id: nil, name: "Zweite", notes: "", departureDate: secondDate)
        let secondID = try XCTUnwrap(library.selectedID)
        XCTAssertEqual(library.planner.departureDate, secondDate)

        library.updateTrip(id: firstID, name: "Umbenannt", notes: "")
        XCTAssertEqual(library.planner.departureDate, secondDate)
        XCTAssertEqual(library.trips.first { $0.id == firstID }?.departureDate, firstDate)
        library.select(firstID)
        XCTAssertEqual(library.planner.departureDate, firstDate)

        let reopened = TripLibrary(store: store)
        XCTAssertEqual(reopened.selectedID, firstID)
        XCTAssertEqual(reopened.planner.departureDate, firstDate)
        reopened.updateTrip(id: firstID, name: "Umbenannt", notes: "", departureDate: nil)
        XCTAssertNil(reopened.planner.departureDate)
        reopened.select(secondID)
        XCTAssertEqual(reopened.planner.departureDate, secondDate)
        let saved = try store.load()
        XCTAssertNil(saved.first { $0.id == firstID }?.departureDate)
        XCTAssertEqual(saved.first { $0.id == secondID }?.departureDate, secondDate)
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
        library.planner.optimizeRoute()
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
        XCTAssertEqual(reopened.selectedID, coastID)
        XCTAssertEqual(reopened.selectedTrip?.name, "Küste")
        XCTAssertEqual(reopened.planner.orderedWaypoints, [coastStart])
        XCTAssertFalse(reopened.planner.automaticRouting)
        reopened.select(tourID)
        XCTAssertEqual(reopened.selectedTrip?.name, "Alpen")
        XCTAssertEqual(reopened.selectedTrip?.notes, "Über die Alpen")
        XCTAssertEqual(reopened.planner.orderedWaypoints, [start, second, first, destination])
        XCTAssertEqual(reopened.planner.stops.map { $0.coordinate.longitude }, [2, 1])
        XCTAssertTrue(reopened.planner.manualOrder)
        reopened.select(coastID)

        reopened.delete(coastID)
        XCTAssertEqual(reopened.selectedID, tourID)
        XCTAssertEqual(reopened.planner.orderedWaypoints, [start, second, first, destination])
        XCTAssertEqual(try store.load().map(\.id), [tourID])
        XCTAssertEqual(TripLibrary(store: store).selectedID, tourID)
        reopened.planner.addStop(stop("Dritter Halt", longitude: 1.5))
        XCTAssertEqual(Array(reopened.planner.stops.prefix(2)), [second, first])
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

    private func stop(_ name: String, latitude: Double, longitude: Double) -> RoadStop {
        RoadStop(name: name, subtitle: "", coordinate: .init(latitude: latitude, longitude: longitude))
    }

    private func makeImageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString,
                                                                          1, nil))
        let gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: 47.25,
            kCGImagePropertyGPSLatitudeRef as String: "S",
            kCGImagePropertyGPSLongitude as String: 11.5,
            kCGImagePropertyGPSLongitudeRef as String: "E"
        ]
        let exif: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: "2026:07:18 19:25:30",
            kCGImagePropertyExifOffsetTimeOriginal as String: "+02:00"
        ]
        let properties: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: gps,
            kCGImagePropertyExifDictionary as String: exif
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
