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

    @MainActor
    func testLodgingToursSurviveEncodingAndUnrelatedPlannerEdits() throws {
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let tourStart = hotel.newOccurrence()
        let tourEnd = hotel.newOccurrence()
        let museum = stop("Museum", latitude: 50, longitude: 1.1)
        let tour = LodgingTour(
            anchorID: hotel.id,
            waypoints: TripWaypoints(start: tourStart, stops: [museum], destination: tourEnd,
                                     stageModes: [tourEnd.id: .walking], isRoundTrip: true)
        )
        let waypoints = TripWaypoints(start: stop("Start", latitude: 50, longitude: 0),
                                     stops: [hotel], destination: stop("Ziel", latitude: 50, longitude: 2),
                                     details: [hotel.id: WaypointDetails(overnight: true)],
                                     lodgingTours: [tour])
        let decoded = try JSONDecoder().decode(TripWaypoints.self, from: JSONEncoder().encode(waypoints))
        let planner = TripPlannerViewModel()
        planner.loadWaypoints(decoded)
        var saved: TripWaypoints?
        planner.onWaypointsChanged = { saved = $0 }

        planner.updateDetails(WaypointDetails(notes: "Notiz", overnight: true), for: hotel)

        let savedTour = try XCTUnwrap(saved?.lodgingTours.first)
        XCTAssertEqual(savedTour.id, tour.id)
        XCTAssertEqual(savedTour.anchorID, hotel.id)
        XCTAssertEqual(savedTour.waypoints.start, tourStart)
        XCTAssertEqual(savedTour.waypoints.stops, [museum])
        XCTAssertEqual(savedTour.waypoints.destination, tourEnd)
        XCTAssertEqual(savedTour.waypoints.stageModes[tourEnd.id], .walking)
    }

    func testStandaloneRoundTripMergePreservesExplicitBudgetsTransitAndPhotos() throws {
        let start = stop("Start", latitude: 50, longitude: 1)
        let hotel = stop("Hotel", latitude: 50, longitude: 1.1)
        let museum = stop("Museum", latitude: 50, longitude: 1.2)
        let end = start.newOccurrence()
        let transit = TransitLeg(from: hotel.id, to: museum.id)
        let overrun = StageBudgetOverrun(waypointIDs: [start.id, hotel.id], budgetMinutes: 45,
                                         arrivalMinutes: 55)
        let photo = TripPhoto(fileExtension: "jpg", originalName: "photo.jpg", capturedAt: nil,
                              coordinate: nil, assignment: .init(target: .stage(hotel.id), status: .confirmed))
        var trip = RoadTrip(name: "Tour", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel, museum], destination: end,
            details: [hotel.id: WaypointDetails(notes: "Notiz", overnight: true, stageBudgetMinutes: 45,
                                                acceptedBudgetOverrun: overrun),
                      museum.id: WaypointDetails(stayMinutes: 30)],
            defaultStageBudgetMinutes: 90, stageModes: [hotel.id: .walking, end.id: .driving],
            transitLegs: [transit], isRoundTrip: true
        ), photos: [photo])

        let notice = try XCTUnwrap(RoundTripMigration.mergeStandalone(&trip))

        XCTAssertTrue(notice.contains("Nicht alle Etappen"))
        XCTAssertTrue(notice.contains("zurückgesetzt"))
        XCTAssertEqual(trip.waypoints.stops, [hotel, museum])
        XCTAssertEqual(trip.waypoints.details[hotel.id]?.notes, "Notiz")
        XCTAssertEqual(trip.waypoints.details[hotel.id]?.overnight, false)
        XCTAssertNil(trip.waypoints.details[hotel.id]?.stageBudgetMinutes)
        XCTAssertNil(trip.waypoints.details[hotel.id]?.acceptedBudgetOverrun)
        XCTAssertEqual(trip.waypoints.details[museum.id]?.stayMinutes, 30)
        XCTAssertEqual(trip.waypoints.details[end.id]?.stageBudgetMinutes, 45)
        XCTAssertEqual(trip.waypoints.stageModes, [end.id: .walking])
        XCTAssertEqual(trip.waypoints.transitLegs, [transit])
        XCTAssertEqual(trip.photos.first?.assignment, .init(target: .stage(end.id), status: .confirmed))
        XCTAssertNil(try RoundTripMigration.mergeStandalone(&trip))
    }

    func testStandaloneRoundTripMergeFailsWithoutModifyingOverflowingTrip() throws {
        let start = stop("Start", latitude: 50, longitude: 1)
        let hotel = stop("Hotel", latitude: 50, longitude: 1.1)
        let end = start.newOccurrence()
        var trip = RoadTrip(name: "Tour", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel], destination: end,
            details: [hotel.id: WaypointDetails(overnight: true, stageBudgetMinutes: Int.max),
                      end.id: WaypointDetails(stageBudgetMinutes: 1)], isRoundTrip: true
        ))
        let before = try JSONEncoder().encode(trip)

        XCTAssertThrowsError(try RoundTripMigration.mergeStandalone(&trip))
        let after = try JSONEncoder().encode(trip)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: before) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: after) as? NSDictionary)
    }

    func testExtractsMultipleToursAtDestinationAndMigratesSegments() throws {
        let start = stop("Start", latitude: 50, longitude: 0)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let museum = stop("Museum", latitude: 50, longitude: 1.1)
        let park = stop("Park", latitude: 50, longitude: 1.2)
        let firstReturn = hotel.newOccurrence()
        let secondReturn = hotel.newOccurrence()
        let assignment = PhotoAssignment(target: .routeSegment(from: firstReturn.id, to: park.id),
                                         status: .suggested)
        let photo = TripPhoto(fileExtension: "jpg", originalName: "photo.jpg", capturedAt: nil,
                              coordinate: nil, assignment: assignment)
        let firstTransit = TransitLeg(from: hotel.id, to: museum.id)
        let secondTransit = TransitLeg(from: firstReturn.id, to: park.id)
        var trip = RoadTrip(name: "Reise", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel, museum, firstReturn, park], destination: secondReturn,
            details: [hotel.id: WaypointDetails(overnight: true),
                      firstReturn.id: WaypointDetails(overnight: true, stageBudgetMinutes: 45),
                      secondReturn.id: WaypointDetails(overnight: true)],
            stageModes: [firstReturn.id: .walking, secondReturn.id: .walking],
            transitLegs: [firstTransit, secondTransit],
            roundTripAnchors: [firstReturn.id: hotel.id, secondReturn.id: hotel.id]
        ), photos: [photo])

        XCTAssertNotNil(try RoundTripMigration.extractLodgingTours(&trip))

        XCTAssertEqual(trip.waypoints.destination, hotel)
        XCTAssertTrue(trip.waypoints.stops.isEmpty)
        XCTAssertTrue(trip.waypoints.roundTripAnchors.isEmpty)
        XCTAssertEqual(trip.waypoints.lodgingTours.count, 2)
        let first = trip.waypoints.lodgingTours[0]
        let second = trip.waypoints.lodgingTours[1]
        XCTAssertEqual(first.anchorID, hotel.id)
        XCTAssertEqual(second.anchorID, hotel.id)
        let firstStart = try XCTUnwrap(first.waypoints.start)
        let secondStart = try XCTUnwrap(second.waypoints.start)
        XCTAssertNotEqual(firstStart.id, hotel.id)
        XCTAssertNotEqual(secondStart.id, firstReturn.id)
        XCTAssertNotEqual(secondStart.id, firstStart.id)
        XCTAssertEqual(first.waypoints.stops, [museum])
        XCTAssertEqual(first.waypoints.destination, firstReturn)
        XCTAssertEqual(second.waypoints.stops, [park])
        XCTAssertEqual(second.waypoints.destination, secondReturn)
        XCTAssertEqual(first.waypoints.details[firstReturn.id]?.stageBudgetMinutes, 45)
        XCTAssertEqual(first.waypoints.transitLegs, [TransitLeg(from: firstStart.id, to: museum.id)])
        XCTAssertEqual(second.waypoints.transitLegs, [TransitLeg(from: secondStart.id, to: park.id)])
        XCTAssertEqual(trip.photos.first?.assignment,
                       .init(target: .routeSegment(from: secondStart.id, to: park.id), status: .suggested))
        XCTAssertNil(try RoundTripMigration.extractLodgingTours(&trip))
    }

    func testExtractingTourMapsOnwardSegmentsAndResetsChangedStageAcceptance() throws {
        let start = stop("Start", latitude: 50, longitude: 0)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let museum = stop("Museum", latitude: 50, longitude: 1.1)
        let returned = hotel.newOccurrence()
        let end = stop("Ziel", latitude: 50, longitude: 2)
        let accepted = StageBudgetOverrun(waypointIDs: [returned.id, end.id], budgetMinutes: 45,
                                          arrivalMinutes: 55)
        let photo = TripPhoto(fileExtension: "jpg", originalName: "photo.jpg", capturedAt: nil,
                              coordinate: nil, assignment: .init(
                                target: .routeSegment(from: returned.id, to: end.id), status: .confirmed))
        var trip = RoadTrip(name: "Reise", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel, museum, returned], destination: end,
            details: [hotel.id: WaypointDetails(overnight: true),
                      returned.id: WaypointDetails(overnight: true),
                      end.id: WaypointDetails(overnight: true, stageBudgetMinutes: 45,
                                              acceptedBudgetOverrun: accepted)],
            transitLegs: [TransitLeg(from: returned.id, to: end.id)],
            roundTripAnchors: [returned.id: hotel.id]
        ), photos: [photo])

        let notice = try XCTUnwrap(RoundTripMigration.extractLodgingTours(&trip))

        XCTAssertTrue(notice.contains("zurückgesetzt"))
        XCTAssertEqual(trip.waypoints.stops, [hotel])
        XCTAssertEqual(trip.waypoints.destination, end)
        XCTAssertNil(trip.waypoints.details[end.id]?.acceptedBudgetOverrun)
        XCTAssertEqual(trip.waypoints.transitLegs, [TransitLeg(from: hotel.id, to: end.id)])
        XCTAssertEqual(trip.photos.first?.assignment,
                       .init(target: .routeSegment(from: hotel.id, to: end.id), status: .confirmed))
    }

    func testExtractingAmbiguousTourFailsWithoutModifyingTrip() throws {
        let start = stop("Start", latitude: 50, longitude: 0)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let invalidReturn = stop("Anderswo", latitude: 50, longitude: 2)
        var trip = RoadTrip(name: "Reise", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel], destination: invalidReturn,
            details: [hotel.id: WaypointDetails(overnight: true)],
            roundTripAnchors: [invalidReturn.id: hotel.id]
        ))
        let before = try JSONEncoder().encode(trip)

        XCTAssertThrowsError(try RoundTripMigration.extractLodgingTours(&trip))
        let after = try JSONEncoder().encode(trip)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: before) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: after) as? NSDictionary)
    }

    @MainActor
    func testMigrationIsAtomicAcrossTripsAndPersistsAfterRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let start = stop("Start", latitude: 50, longitude: 0)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let returned = hotel.newOccurrence()
        let valid = RoadTrip(name: "Gut", notes: "", waypoints: TripWaypoints(
            start: start, stops: [hotel], destination: returned,
            details: [hotel.id: WaypointDetails(overnight: true)],
            roundTripAnchors: [returned.id: hotel.id]
        ))
        var invalid = valid
        invalid.id = UUID()
        invalid.name = "Ungültig"
        invalid.waypoints.roundTripAnchors[returned.id] = UUID()
        try store.save([valid, invalid])
        let original = try Data(contentsOf: store.url)

        let failed = TripLibrary(store: store)
        XCTAssertNotNil(failed.loadError)
        XCTAssertTrue(failed.trips.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.url), original)

        try store.save([valid])
        failed.retryLoad()
        XCTAssertNil(failed.loadError)
        let tour = try XCTUnwrap(failed.selectedTrip?.waypoints.lodgingTours.first)
        XCTAssertEqual(failed.selectedTrip?.waypoints.destination, hotel)
        XCTAssertFalse(try XCTUnwrap(failed.selectedTrip).migrationNotices.isEmpty)
        let reopened = TripLibrary(store: store)
        XCTAssertEqual(reopened.selectedTrip?.waypoints.lodgingTours.first?.id, tour.id)
        XCTAssertEqual(reopened.selectedTrip?.waypoints.lodgingTours.first?.waypoints.start?.id, tour.waypoints.start?.id)
        XCTAssertEqual(reopened.selectedTrip?.migrationNotices.count, 1)
    }

    @MainActor
    func testConvertingTripFlattensToursAndPreservesPhotoAndTransitIdentities() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let start = stop("Start", latitude: 50, longitude: 0)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let museum = stop("Museum", latitude: 50, longitude: 1.1)
        let tourStart = hotel.newOccurrence()
        let tourEnd = hotel.newOccurrence()
        let tour = LodgingTour(anchorID: hotel.id, waypoints: TripWaypoints(
            start: tourStart, stops: [museum], destination: tourEnd,
            details: [tourEnd.id: WaypointDetails(stageBudgetMinutes: 60)],
            stageModes: [tourEnd.id: .driving], transitLegs: [TransitLeg(from: tourStart.id, to: museum.id)],
            isRoundTrip: true
        ))
        let photo = TripPhoto(fileExtension: "jpg", originalName: "photo.jpg", capturedAt: nil,
                              coordinate: nil, assignment: .init(
                                target: .routeSegment(from: tourStart.id, to: museum.id), status: .confirmed))
        let trip = RoadTrip(name: "Reise", notes: "", waypoints: TripWaypoints(
            start: start, destination: hotel, details: [hotel.id: WaypointDetails(overnight: true, stageBudgetMinutes: 90)],
            stageModes: [hotel.id: .walking], lodgingTours: [tour]
        ), photos: [photo])
        try store.save([trip])
        let library = TripLibrary(store: store)

        library.updateTrip(id: trip.id, name: "Reise", notes: "", departureDate: nil, isRoundTrip: true)

        let converted = try XCTUnwrap(library.selectedTrip)
        let newEnd = try XCTUnwrap(converted.waypoints.destination)
        XCTAssertTrue(converted.waypoints.isRoundTrip)
        XCTAssertTrue(converted.waypoints.lodgingTours.isEmpty)
        XCTAssertEqual(converted.waypoints.stops, [hotel, museum, tourEnd])
        XCTAssertEqual(library.planner.stages.count, 1)
        XCTAssertEqual(converted.waypoints.stageModes[newEnd.id], .walking)
        XCTAssertEqual(converted.waypoints.details[newEnd.id]?.stageBudgetMinutes, 150)
        XCTAssertTrue(converted.waypoints.transitLegs.contains(TransitLeg(from: hotel.id, to: museum.id)))
        XCTAssertEqual(converted.photos.first?.assignment,
                       .init(target: .routeSegment(from: hotel.id, to: museum.id), status: .confirmed))
        XCTAssertEqual(TripLibrary(store: store).planner.stages.count, 1)
    }

    func testConvertingIncludesTourAnchoredAtStart() throws {
        let start = stop("Unterkunft", latitude: 50, longitude: 0)
        let end = stop("Ziel", latitude: 50, longitude: 2)
        let museum = stop("Museum", latitude: 50, longitude: 0.1)
        let tourStart = start.newOccurrence()
        let tourEnd = start.newOccurrence()
        let tour = LodgingTour(anchorID: start.id, waypoints: TripWaypoints(
            start: tourStart, stops: [museum], destination: tourEnd, isRoundTrip: true
        ))
        var trip = RoadTrip(name: "Reise", notes: "", waypoints: TripWaypoints(
            start: start, destination: end, details: [start.id: WaypointDetails(overnight: true)],
            lodgingTours: [tour]
        ))

        _ = try RoundTripMigration.convertToStandalone(&trip)

        XCTAssertEqual(trip.waypoints.stops, [museum, tourEnd, end])
        XCTAssertTrue(trip.waypoints.lodgingTours.isEmpty)
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

    func testPhotoSuggestionsSearchTourContextsWithoutConnectingThem() {
        let a = stop("Hauptreise A", latitude: 0, longitude: 0)
        let b = stop("Hauptreise B", latitude: 0, longitude: 0.1)
        let c = stop("Tour A", latitude: 1, longitude: 0)
        let d = stop("Tour B", latitude: 1, longitude: 0.1)
        let first = PhotoAssignmentSuggester.Context(waypoints: [a, b], stages: [], routeLegs: [
            RouteLeg(duration: 1, distance: 1, coordinates: [a.coordinate, b.coordinate])
        ])
        let second = PhotoAssignmentSuggester.Context(waypoints: [c, d], stages: [], routeLegs: [
            RouteLeg(duration: 1, distance: 1, coordinates: [c.coordinate, d.coordinate])
        ])
        XCTAssertEqual(PhotoAssignmentSuggester.suggest(
            at: .init(latitude: 1.005, longitude: 0.05), contexts: [first, second]
        ), .routeSegment(from: c.id, to: d.id))
        XCTAssertNil(PhotoAssignmentSuggester.suggest(
            at: .init(latitude: 0.5, longitude: 0.05), contexts: [first, second]
        ))
    }

    func testTransitSchematicLineIsNotUsedForPhotoSegmentSuggestions() {
        let start = stop("Start", latitude: 0, longitude: 0)
        let end = stop("Ziel", latitude: 0, longitude: 0.1)
        let leg = RouteLeg(duration: 100, distance: 11_000,
                           coordinates: [start.coordinate, end.coordinate], isTransit: true)
        let stage = TripStage(waypoints: [start, end], legs: [leg], waypointStayMinutes: [0, 0],
                              budgetMinutes: nil, endsWithOvernight: false)
        let target = PhotoAssignmentSuggester.suggest(at: .init(latitude: 0.005, longitude: 0.05),
                                                      waypoints: [start, end], stages: [stage], routeLegs: [leg])
        XCTAssertEqual(target, .stage(end.id))
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
    func testDeletingEarlierRoundTripPreservesLaterPhotoSegmentAssignment() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Tour", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let hotel = stop("Hotel", latitude: 50, longitude: 1)
        let park = stop("Park", latitude: 50, longitude: 1.1)
        let planner = library.planner
        planner.setStart(stop("Start", latitude: 50, longitude: 0))
        planner.setDestination(stop("Ende", latitude: 50, longitude: 2))
        planner.addStop(hotel)
        planner.updateDetails(WaypointDetails(overnight: true), for: hotel)
        planner.addLodgingTour(at: hotel)
        let firstID = try XCTUnwrap(planner.lodgingTours.first?.id)
        planner.addLodgingTour(at: hotel)
        let secondID = try XCTUnwrap(planner.lodgingTours.last?.id)
        let secondTour = try XCTUnwrap(planner.tourPlanners[secondID])
        secondTour.addStop(park)
        let oldStart = try XCTUnwrap(secondTour.start)
        try await library.addPhoto(data: makeImageData(), originalName: "photo.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)
        try library.updatePhotoAssignment(.routeSegment(from: oldStart.id, to: park.id),
                                          photoID: photo.id, tripID: tripID)
        try await library.addPhoto(data: makeImageData(), originalName: "other.jpg", tripID: tripID)
        let other = try XCTUnwrap(library.selectedTrip?.photos.last)
        try library.updatePhotoAssignment(.waypoint(park.id), photoID: other.id, tripID: tripID)

        planner.removeLodgingTour(firstID)
        let reopened = TripLibrary(store: store)
        let migratedStart = try XCTUnwrap(reopened.selectedTrip?.waypoints.lodgingTours.first?.waypoints.start)
        XCTAssertEqual(migratedStart.id, oldStart.id)
        XCTAssertEqual(reopened.selectedTrip?.photos.first?.assignment?.target,
                       .routeSegment(from: migratedStart.id, to: park.id))
        XCTAssertEqual(reopened.selectedTrip?.photos.last?.assignment?.target, .waypoint(park.id))
    }

    @MainActor
    func testChangingTripTypePreservesStagesAndPhotoAssignments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Tour", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let start = stop("Start", latitude: 50, longitude: 0)
        let end = stop("Ziel", latitude: 50, longitude: 1)
        let planner = library.planner
        planner.setStart(start)
        planner.setDestination(end)
        planner.setMode(.walking, for: planner.stages[0])
        planner.updateDetails(WaypointDetails(stageBudgetMinutes: 120), for: end)
        planner.setTransit(true, from: start, to: end)
        try await library.addPhoto(data: makeImageData(), originalName: "photo.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)
        try library.updatePhotoAssignment(.stage(end.id), photoID: photo.id, tripID: tripID)

        library.updateTrip(id: tripID, name: "Tour", notes: "", departureDate: nil, isRoundTrip: true)
        let returnPoint = try XCTUnwrap(planner.destination)
        XCTAssertEqual(planner.stops, [end])
        XCTAssertEqual(returnPoint.coordinate.latitude, start.coordinate.latitude)
        XCTAssertEqual(returnPoint.coordinate.longitude, start.coordinate.longitude)
        XCTAssertEqual(planner.mode(for: planner.stages[0]), .walking)
        XCTAssertEqual(planner.stages[0].budgetMinutes, 120)
        XCTAssertTrue(planner.isTransit(from: start, to: end))
        XCTAssertEqual(library.selectedTrip?.photos.first?.assignment?.target, .stage(returnPoint.id))

        library.updateTrip(id: tripID, name: "Tour", notes: "", departureDate: nil, isRoundTrip: false)
        XCTAssertEqual(planner.destination, end)
        XCTAssertTrue(planner.stops.isEmpty)
        XCTAssertEqual(planner.mode(for: planner.stages[0]), .walking)
        XCTAssertEqual(planner.stages[0].budgetMinutes, 120)
        XCTAssertEqual(library.selectedTrip?.photos.first?.assignment?.target, .stage(end.id))
        let reopened = TripLibrary(store: store)
        XCTAssertEqual(reopened.selectedTrip?.photos.first?.assignment?.target, .stage(end.id))
        XCTAssertFalse(reopened.planner.isRoundTrip)
    }

    @MainActor
    func testEditingTripMetadataDoesNotChangeItsType() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TripLibrary(store: TripStore(url: directory.appending(path: "trips.json")))
        library.updateTrip(id: nil, name: "Tour", notes: "", departureDate: nil, isRoundTrip: true)
        let id = try XCTUnwrap(library.selectedID)
        library.updateTrip(id: id, name: "Anders", notes: "", departureDate: Date())
        XCTAssertTrue(library.planner.isRoundTrip)
        XCTAssertTrue(library.selectedTrip?.waypoints.isRoundTrip == true)
    }

    @MainActor
    func testChangingRoundTripStartKeepsReturnIdentityAndAssignments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TripLibrary(store: TripStore(url: directory.appending(path: "trips.json")))
        library.updateTrip(id: nil, name: "Tour", notes: "", departureDate: nil, isRoundTrip: true)
        let id = try XCTUnwrap(library.selectedID)
        let planner = library.planner
        planner.setStart(stop("Start", latitude: 50, longitude: 0))
        let returnPoint = try XCTUnwrap(planner.destination)
        try await library.addPhoto(data: makeImageData(), originalName: "photo.jpg", tripID: id)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)
        try library.updatePhotoAssignment(.stage(returnPoint.id), photoID: photo.id, tripID: id)
        let newStart = stop("Neuer Start", latitude: 51, longitude: 1)
        planner.setStart(newStart)
        XCTAssertEqual(planner.destination?.id, returnPoint.id)
        XCTAssertEqual(planner.destination?.coordinate.latitude, newStart.coordinate.latitude)
        XCTAssertEqual(library.selectedTrip?.photos.first?.assignment?.target, .stage(returnPoint.id))
    }

    @MainActor
    func testConvertingTripBeforeSettingStartRetainsFinalStageSettings() {
        let model = TripPlannerViewModel()
        let end = stop("Ziel", latitude: 50, longitude: 1)
        model.loadWaypoints(TripWaypoints(destination: end,
                                           details: [end.id: WaypointDetails(stageBudgetMinutes: 120)],
                                           stageModes: [end.id: .walking]))
        model.setRoundTrip(true)
        model.setStart(stop("Start", latitude: 50, longitude: 0))
        XCTAssertEqual(model.stops, [end])
        XCTAssertEqual(model.mode(for: model.stages[0]), .walking)
        XCTAssertEqual(model.stages[0].budgetMinutes, 120)
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
    func testPhotoLocationUsesSelectedTourRatherThanNearbyMainWaypoint() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(url: directory.appending(path: "trips.json"))
        let library = TripLibrary(store: store)
        library.updateTrip(id: nil, name: "Fotoreise", notes: "")
        let tripID = try XCTUnwrap(library.selectedID)
        let mainWaypoint = stop("Hauptreise", latitude: -47.25, longitude: 11.5)
        let hotel = stop("Hotel", latitude: -47.3, longitude: 11.6)
        library.planner.setStart(mainWaypoint)
        library.planner.setDestination(stop("Ziel", latitude: -47, longitude: 12))
        library.planner.addStop(hotel)
        library.planner.updateDetails(WaypointDetails(overnight: true), for: hotel)
        library.planner.addLodgingTour(at: hotel)
        let tourID = try XCTUnwrap(library.planner.lodgingTours.first?.id)
        let tour = try XCTUnwrap(library.planner.tourPlanners[tourID])
        try await library.addPhoto(data: makeImageData(), originalName: "Aussicht.jpg", tripID: tripID)
        let photo = try XCTUnwrap(library.selectedTrip?.photos.first)

        let waypoint = try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID, tourID: tourID)
        XCTAssertNotEqual(waypoint.id, mainWaypoint.id)
        XCTAssertFalse(library.planner.orderedWaypoints.contains(waypoint))
        XCTAssertTrue(tour.stops.contains(waypoint))
        XCTAssertEqual(tour.waypointDetails(for: waypoint).category, .photo)
        XCTAssertEqual(try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID, tourID: tourID).id,
                       waypoint.id)
        XCTAssertEqual(tour.stops.count, 1)

        let reopened = TripLibrary(store: store)
        XCTAssertEqual(reopened.planner.lodgingTours.first?.waypoints.stops, [waypoint])
        XCTAssertEqual(reopened.selectedTrip?.photos.first?.assignment,
                       PhotoAssignment(target: .waypoint(waypoint.id), status: .confirmed))
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
        XCTAssertFalse(waypoints.isRoundTrip)
        XCTAssertTrue(waypoints.stageModes.isEmpty)
        XCTAssertTrue(waypoints.roundTripAnchors.isEmpty)
        XCTAssertTrue(waypoints.transitLegs.isEmpty)
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
