import Combine
import CoreLocation
import MapKit
import XCTest
@testable import RoadTripAssist

final class ProgressiveRoutingTests: XCTestCase {
    @MainActor
    func testLodgingTourUsesIndependentRoutingAndPersistsEdits() async throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let end = stop("Ziel", 50, 2)
        let museum = stop("Museum", 50, 1.1)
        let service = MapKitRouteService { from, to, _, _ in
            if from.name == "Museum" {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            }
            return RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: end,
                                          manualOrder: true, details: [hotel.id: WaypointDetails(overnight: true)]))
        var saved: TripWaypoints?
        model.onWaypointsChanged = { saved = $0 }
        model.addLodgingTour(at: hotel)
        let tourID = try XCTUnwrap(model.lodgingTours.first?.id)
        let tour = try XCTUnwrap(model.tourPlanners[tourID])
        tour.addStop(museum)
        XCTAssertEqual(saved?.lodgingTours.first?.waypoints.stops, [museum])
        XCTAssertEqual(model.orderedWaypoints, [start, hotel, end])

        model.enableAutomaticRouting()
        tour.enableAutomaticRouting()
        try await waitForRouting(model)
        try await waitForRouting(tour)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertNotNil(model.roadPreview)
        XCTAssertEqual(tour.routeStatus, .failed)
        XCTAssertFalse(tour.currentConnections.isEmpty)
        XCTAssertNil(tour.roadPreview)
        XCTAssertNil(model.completeJourneyTotals)

        model.removeLodgingTour(tourID)
        XCTAssertTrue(model.lodgingTours.isEmpty)
        XCTAssertNil(model.tourPlanners[tourID])
        XCTAssertTrue(saved?.lodgingTours.isEmpty == true)
    }

    @MainActor
    func testTourSearchKeepsRepeatedPlacesDistinctAcrossContexts() async throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let destination = stop("Ziel", 50, 2)
        let model = TripPlannerViewModel(findPlaces: { query in
            query == hotel.name ? [hotel] : [destination]
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: destination,
                                          manualOrder: true, details: [hotel.id: WaypointDetails(overnight: true)]))
        var saved: TripWaypoints?
        model.onWaypointsChanged = { saved = $0 }
        model.addLodgingTour(at: hotel)
        model.addLodgingTour(at: hotel)
        let first = try XCTUnwrap(model.tourPlanners[model.lodgingTours[0].id])
        let second = try XCTUnwrap(model.tourPlanners[model.lodgingTours[1].id])

        for tour in [first, second] {
            tour.updateSearch(destination.name, in: .newStop)
            try await waitForSearch(tour)
            XCTAssertTrue(tour.chooseSearchResult(destination, in: .newStop, distinctOccurrence: true))
        }
        let firstStop = try XCTUnwrap(first.stops.first)
        let secondStop = try XCTUnwrap(second.stops.first)
        XCTAssertEqual(firstStop.name, destination.name)
        XCTAssertNotEqual(firstStop.id, destination.id)
        XCTAssertNotEqual(firstStop.id, secondStop.id)

        first.updateSearch(hotel.name, in: .stop(firstStop.id))
        try await waitForSearch(first)
        XCTAssertTrue(first.chooseSearchResult(hotel, in: .stop(firstStop.id), distinctOccurrence: true))
        let replacement = try XCTUnwrap(first.stops.first)
        XCTAssertEqual(replacement.name, hotel.name)
        XCTAssertNotEqual(replacement.id, hotel.id)
        XCTAssertEqual(model.orderedWaypoints, [start, hotel, destination])

        let restored = try JSONDecoder().decode(TripWaypoints.self, from: JSONEncoder().encode(XCTUnwrap(saved)))
        try RoundTripMigration.validate(restored)
        XCTAssertEqual(restored.lodgingTours[0].waypoints.stops, [replacement])
        XCTAssertEqual(restored.lodgingTours[1].waypoints.stops, [secondStop])
    }

    @MainActor
    func testJourneyTotalsRequireAllRoutesAndDoNotCountLodgingTwice() async throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let end = stop("Ziel", 50, 2)
        let museum = stop("Museum", 50, 1.1)
        let service = MapKitRouteService { from, to, _, _ in
            RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: end,
                                          manualOrder: true,
                                          details: [hotel.id: WaypointDetails(stayMinutes: 60, overnight: true)]))
        model.addLodgingTour(at: hotel)
        let tour = try XCTUnwrap(model.tourPlanners[try XCTUnwrap(model.lodgingTours.first?.id)])
        tour.addStop(museum)
        tour.updateDetails(WaypointDetails(stayMinutes: 10), for: museum)
        let tourEnd = try XCTUnwrap(tour.destination)
        tour.updateDetails(WaypointDetails(stayMinutes: 60), for: tourEnd)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertNil(model.completeJourneyTotals)

        tour.enableAutomaticRouting()
        try await waitForRouting(tour)
        let total = try XCTUnwrap(model.completeJourneyTotals)
        XCTAssertEqual(total.duration, 4_600)
        XCTAssertEqual(total.distance, 400)
    }

    @MainActor
    func testLiveDiagnosticsIncludesEarlierFailureAndPendingWalkingRequest() async throws {
        let start = stop("Start", 50, 0)
        let middle = stop("Mitte", 50, 0.01)
        let end = stop("Ziel", 50, 0.02)
        let started = expectation(description: "second request started")
        let service = MapKitRouteService { from, to, _, _ in
            if from == start {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            }
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [middle], destination: end, manualOrder: true))
        model.setMode(.walking, for: model.stages[0])
        model.enableAutomaticRouting()
        await fulfillment(of: [started], timeout: 5)

        let diagnostic = model.liveRoutingDiagnostic()
        XCTAssertTrue(model.isOptimizing)
        XCTAssertTrue(diagnostic.contains("Domain: NSURLErrorDomain"))
        XCTAssertTrue(diagnostic.contains("Aktuelle Anfrage: „Mitte“"))
        XCTAssertTrue(diagnostic.contains("„Ziel“"))
        XCTAssertTrue(diagnostic.contains("Verkehrsmittel: Zu Fuß"))
        XCTAssertTrue(diagnostic.contains("1 von 2 abgeschlossen"))

        model.pauseRouting()
        XCTAssertNil(model.currentRequest)
        XCTAssertTrue(model.liveRoutingDiagnostic().contains("Berechnung pausiert"))
        XCTAssertFalse(model.liveRoutingDiagnostic().contains("Aktuelle Anfrage:"))
    }

    @MainActor
    func testStageModesAndTransitUseSeparateCachedConnections() async throws {
        let start = stop("Start", 50, 0)
        let overnight = stop("Hotel", 50, 1)
        let end = stop("Ziel", 50, 2)
        var requests: [(String, MapKitRouteService.Transport)] = []
        let service = MapKitRouteService { from, to, _, mode in
            requests.append(("\(from.name)-\(to.name)", mode))
            return RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [overnight], destination: end,
                                           manualOrder: true, details: [overnight.id: WaypointDetails(overnight: true)]))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(requests.map(\.1), [.driving, .driving])

        model.setMode(.walking, for: model.stages[1])
        try await waitForRouting(model)
        XCTAssertEqual(requests.map(\.1), [.driving, .driving, .walking])
        model.setTransit(true, from: overnight, to: end)
        try await waitForRouting(model)
        XCTAssertEqual(requests.last?.1, .transit)
        XCTAssertTrue(model.roadPreview?.legs.last?.isTransit == true)

        model.setMode(.driving, for: model.stages[1])
        try await waitForRouting(model)
        XCTAssertTrue(model.isTransit(from: overnight, to: end))
        XCTAssertFalse(model.roadPreview?.legs.last?.isTransit == true)
        model.setMode(.walking, for: model.stages[1])
        try await waitForRouting(model)
        XCTAssertTrue(model.roadPreview?.legs.last?.isTransit == true)
        XCTAssertEqual(requests.count, 4)
    }

    @MainActor
    func testReorderingRemovesOnlyDisconnectedTransitMarkersEvenWhileDriving() {
        let start = stop("Start", 50, 0)
        let first = stop("A", 50, 1)
        let second = stop("B", 50, 2)
        let end = stop("Ziel", 50, 3)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: start, stops: [first, second], destination: end,
                                           manualOrder: true))
        model.setMode(.walking, for: model.stages[0])
        model.setTransit(true, from: first, to: second)
        model.setMode(.driving, for: model.stages[0])
        model.moveStop(first, by: 1)
        XCTAssertFalse(model.isTransit(from: first, to: second))
        XCTAssertNotNil(model.transitNotice)
    }

    @MainActor
    func testOptimizationUsesTransitOnlyForMarkedDirectedPair() async throws {
        let start = stop("Start", 50, 0)
        let a = stop("A", 50, 1)
        let b = stop("B", 50, 2)
        let end = stop("Ziel", 50, 3)
        var requests: [(String, MapKitRouteService.Transport)] = []
        let service = MapKitRouteService { from, to, _, mode in
            let pair = "\(from.name)-\(to.name)"
            requests.append((pair, mode))
            let fast = ["Start-B", "B-A", "A-Ziel"].contains(pair)
            return RouteLeg(duration: fast ? 1 : 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end, manualOrder: true))
        model.setMode(.walking, for: model.stages[0])
        model.setTransit(true, from: a, to: b)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(model.suggestion?.orderedStops, [b, a])
        XCTAssertTrue(model.suggestionRemovesTransit)
        XCTAssertTrue(model.isTransit(from: a, to: b))
        XCTAssertEqual(requests.first(where: { $0.0 == "A-B" })?.1, .transit)
        XCTAssertEqual(requests.first(where: { $0.0 == "B-A" })?.1, .walking)
        model.acceptSuggestion()
        XCTAssertFalse(model.isTransit(from: a, to: b))
    }

    @MainActor
    func testTransitRequestAndSchematicLegDoNotPretendToHaveGeometry() {
        let from = stop("Start", 50, 1)
        let to = stop("Ziel", 50, 2)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(MapKitRouteService.directionsRequest(from: from, to: to, departureDate: date,
                                                            mode: .walking).transportType, .walking)
        XCTAssertEqual(MapKitRouteService.directionsRequest(from: from, to: to, departureDate: date,
                                                            mode: .transit).transportType, .transit)
        let leg = RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate], isTransit: true)
        XCTAssertNil(leg.coordinate(atFraction: 0.5))
    }

    @MainActor
    func testFailedTransitLeavesOtherConnectionsAvailable() async throws {
        let start = stop("Start", 50, 0)
        let a = stop("A", 50, 1)
        let end = stop("Ziel", 50, 2)
        let service = MapKitRouteService { from, to, _, mode in
            if mode == .transit { return nil }
            return RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [a], destination: end, manualOrder: true))
        model.setMode(.walking, for: model.stages[0])
        model.setTransit(true, from: start, to: a)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertNil(model.roadPreview)
        XCTAssertEqual(model.unavailableConnections.map(\.from.id), [start.id])
        XCTAssertEqual(model.currentConnections.map(\.from.id), [a.id])
        XCTAssertTrue(model.isTransit(from: start, to: a))
    }

    @MainActor
    func testRoundTripOptimizationDoesNotChangeMainJourney() async throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let museum = stop("Museum", 50, 1.1)
        let park = stop("Park", 50, 1.2)
        let end = stop("Ziel", 50, 2)
        let service = MapKitRouteService { from, to in
            let fast = ["Hotel-Park", "Park-Museum", "Museum-Hotel"].contains("\(from.name)-\(to.name)")
            return RouteLeg(duration: fast ? 1 : 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: end,
                                           manualOrder: true, details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        let tour = try XCTUnwrap(model.tourPlanners[try XCTUnwrap(model.lodgingTours.first?.id)])
        tour.addStop(museum)
        tour.addStop(park)
        model.enableAutomaticRouting()
        tour.enableAutomaticRouting()
        try await waitForRouting(model)
        try await waitForRouting(tour)
        tour.optimizeRoute()
        try await waitForRouting(tour)
        XCTAssertEqual(tour.suggestion?.orderedStops, [park, museum])
        tour.acceptSuggestion()
        XCTAssertEqual(tour.stages[0].waypoints.map(\.name), ["Hotel", "Park", "Museum", "Hotel"])
        XCTAssertEqual(model.orderedWaypoints, [start, hotel, end])
        XCTAssertEqual(model.routeStatus, .finished)
    }

    @MainActor
    func testRoundTripsAtSameHotelRemainSeparateAndCanBeDeleted() throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let end = stop("Ziel", 50, 2)
        let first = stop("Museum", 50, 1.1)
        let second = stop("Park", 50, 1.2)
        let model = TripPlannerViewModel()
        var saved: TripWaypoints?
        model.onWaypointsChanged = { saved = $0 }
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: end, manualOrder: true,
                                           details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        let firstID = try XCTUnwrap(model.lodgingTours.first?.id)
        model.tourPlanners[firstID]?.addStop(first)
        model.addLodgingTour(at: hotel)
        let secondID = try XCTUnwrap(model.lodgingTours.last?.id)
        model.tourPlanners[secondID]?.addStop(second)
        XCTAssertEqual(model.stages.count, 2)
        XCTAssertEqual(model.tourPlanners[firstID]?.stages[0].waypoints.map(\.name), ["Hotel", "Museum", "Hotel"])
        XCTAssertEqual(model.tourPlanners[secondID]?.stages[0].waypoints.map(\.name), ["Hotel", "Park", "Hotel"])

        let encoded = try JSONEncoder().encode(XCTUnwrap(saved))
        let decoded = try JSONDecoder().decode(TripWaypoints.self, from: encoded)
        let reopened = TripPlannerViewModel()
        reopened.loadWaypoints(decoded)
        XCTAssertEqual(reopened.stages.count, 2)
        XCTAssertEqual(reopened.lodgingTours.count, 2)
        reopened.removeLodgingTour(firstID)
        XCTAssertEqual(reopened.lodgingTours.map(\.id), [secondID])
        XCTAssertEqual(reopened.tourPlanners[secondID]?.stages[0].waypoints.map(\.name), ["Hotel", "Park", "Hotel"])
    }

    @MainActor
    func testStandaloneRoundTripClosesAtStart() {
        let start = stop("Unterkunft", 50, 1)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(isRoundTrip: true))
        model.setStart(start)
        XCTAssertTrue(model.hasEndpoints)
        XCTAssertNotEqual(model.start?.id, model.destination?.id)
        XCTAssertEqual(model.start?.coordinate.latitude, model.destination?.coordinate.latitude)
        XCTAssertEqual(model.start?.coordinate.longitude, model.destination?.coordinate.longitude)
        XCTAssertTrue(model.isRoundTripStage(model.stages[0]))
    }

    @MainActor
    func testRoundTripsAtFinalDestinationCanBeDeletedWithoutLosingDestination() {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: start, destination: hotel,
                                           details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        model.addLodgingTour(at: hotel)
        XCTAssertEqual(model.lodgingTours.count, 2)
        for id in model.lodgingTours.map(\.id) { model.removeLodgingTour(id) }
        XCTAssertTrue(model.lodgingTours.isEmpty)
        XCTAssertEqual(model.stages.count, 1)
        XCTAssertEqual(model.destination, hotel)
    }

    @MainActor
    func testChangingHotelMovesRoundTripEndpointsAndInvalidatesCachedLegs() async throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let replacement = stop("Neues Hotel", 50, 1.5)
        let end = stop("Ziel", 50, 2)
        var requests = 0
        let service = MapKitRouteService { from, to in
            requests += 1
            return RouteLeg(duration: 100, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service, findPlaces: { _ in [replacement] })
        model.loadWaypoints(TripWaypoints(start: start, stops: [hotel], destination: end,
                                           manualOrder: true, details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        let tour = try XCTUnwrap(model.tourPlanners[try XCTUnwrap(model.lodgingTours.first?.id)])
        let attraction = stop("Museum", 50, 1.1)
        tour.addStop(attraction)
        model.enableAutomaticRouting()
        tour.enableAutomaticRouting()
        try await waitForRouting(model)
        try await waitForRouting(tour)
        let count = requests
        model.updateSearch("Neues Hotel", in: .stop(hotel.id))
        try await waitForSearch(model)
        XCTAssertTrue(model.chooseSearchResult(replacement, in: .stop(hotel.id)))
        try await waitForRouting(model)
        try await waitForRouting(tour)
        XCTAssertGreaterThan(requests, count)
        XCTAssertEqual(tour.stages[0].waypoints.map(\.name), ["Neues Hotel", "Museum", "Neues Hotel"])
        XCTAssertEqual(tour.start?.coordinate.longitude, 1.5)
        XCTAssertEqual(tour.destination?.coordinate.longitude, 1.5)
        XCTAssertEqual(model.stages[0].end.id, hotel.id)
    }

    @MainActor
    func testChangingDestinationUpdatesAllTourEndpointsInOneSavedSnapshot() throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let replacement = stop("Neues Hotel", 50, 2)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: start, destination: hotel,
                                          details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        model.addLodgingTour(at: hotel)
        var saved: [TripWaypoints] = []
        model.onWaypointsChanged = { saved.append($0) }

        model.setDestination(replacement)

        XCTAssertEqual(saved.count, 1)
        let snapshot = try XCTUnwrap(saved.first)
        XCTAssertNoThrow(try RoundTripMigration.validate(snapshot))
        XCTAssertEqual(snapshot.destination?.id, hotel.id)
        XCTAssertEqual(snapshot.destination?.coordinate.longitude, 2)
        XCTAssertEqual(snapshot.lodgingTours.map { $0.waypoints.start?.coordinate.longitude }, [2, 2])
        XCTAssertEqual(snapshot.lodgingTours.map { $0.waypoints.destination?.coordinate.longitude }, [2, 2])
        model.removeStop(hotel)
        XCTAssertEqual(model.destination?.id, hotel.id)
    }

    @MainActor
    func testChangingStartLodgingPreservesItsTours() throws {
        let hotel = stop("Hotel", 50, 0)
        let end = stop("Ziel", 50, 2)
        let replacement = stop("Neues Hotel", 50, 1)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: hotel, destination: end,
                                          details: [hotel.id: WaypointDetails(overnight: true)]))
        model.addLodgingTour(at: hotel)
        var saved: TripWaypoints?
        model.onWaypointsChanged = { saved = $0 }

        model.setStart(replacement)

        let snapshot = try XCTUnwrap(saved)
        XCTAssertNoThrow(try RoundTripMigration.validate(snapshot))
        XCTAssertEqual(snapshot.start?.id, hotel.id)
        XCTAssertEqual(snapshot.lodgingTours.first?.waypoints.start?.coordinate.longitude, 1)
        XCTAssertEqual(snapshot.lodgingTours.first?.waypoints.destination?.coordinate.longitude, 1)
    }

    @MainActor
    func testLodgingToursInheritUpdatedDefaultBudget() throws {
        let start = stop("Start", 50, 0)
        let hotel = stop("Hotel", 50, 1)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: start, destination: hotel,
                                          details: [hotel.id: WaypointDetails(overnight: true)],
                                          defaultStageBudgetMinutes: 90))
        model.addLodgingTour(at: hotel)
        let tour = try XCTUnwrap(model.tourPlanners[try XCTUnwrap(model.lodgingTours.first?.id)])
        XCTAssertEqual(tour.stages.first?.budgetMinutes, 90)
        XCTAssertTrue(tour.stages.first?.endsWithOvernight == true)
        var saved: [TripWaypoints] = []
        model.onWaypointsChanged = { saved.append($0) }

        model.setDefaultStageBudget(120)

        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.lodgingTours.first?.waypoints.defaultStageBudgetMinutes, 120)
        XCTAssertEqual(tour.stages.first?.budgetMinutes, 120)
    }

    @MainActor
    func testDepartureDateRecalculatesCachedLegsAndReachesOptimization() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var dates: [Date?] = []
        let service = MapKitRouteService { _, _, date in
            dates.append(date)
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(dates.count, 3)
        XCTAssertTrue(dates.allSatisfy { $0 == nil })

        model.setDepartureDate(date)
        XCTAssertNil(model.roadPreview)
        try await waitForRouting(model)
        XCTAssertEqual(dates.count, 6)
        XCTAssertTrue(dates.suffix(3).allSatisfy { $0 == date })

        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(dates.count, 9)
        XCTAssertTrue(dates.suffix(3).allSatisfy { $0 == date })
        model.setDepartureDate(date)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(dates.count, 9)

        model.setDepartureDate(nil)
        try await waitForRouting(model)
        XCTAssertEqual(dates.count, 12)
        XCTAssertTrue(dates.suffix(3).allSatisfy { $0 == nil })
        XCTAssertNotNil(model.roadPreview)
    }

    @MainActor
    func testDirectionsRequestIncludesOptionalDepartureDate() {
        let start = stop("Start", 50, 11)
        let end = stop("Ziel", 51, 12)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let request = MapKitRouteService.directionsRequest(from: start, to: end, departureDate: date)
        XCTAssertEqual(request.departureDate, date)
        XCTAssertEqual(request.transportType, .automobile)
        XCTAssertNil(MapKitRouteService.directionsRequest(from: start, to: end, departureDate: nil).departureDate)
    }

    @MainActor
    func testChangingDepartureDateRechecksPreviouslyUnavailableConnection() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 1)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var dates: [Date?] = []
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _, date in
            dates.append(date)
            return date == nil ? nil : RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertEqual(model.unavailableConnections.count, 1)

        model.setDepartureDate(date)
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertTrue(model.unavailableConnections.isEmpty)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates.last!, date)
    }

    @MainActor
    func testChangingDepartureDateCancelsInFlightRoute() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 1)
        let oldDate = Date(timeIntervalSince1970: 2_000_000_000)
        let newDate = oldDate.addingTimeInterval(86_400)
        let started = expectation(description: "Old departure date request started")
        var dates: [Date?] = []
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _, date in
            dates.append(date)
            if date == oldDate {
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, destination: end), departureDate: oldDate)
        model.enableAutomaticRouting()
        await fulfillment(of: [started], timeout: 2)
        model.setDepartureDate(newDate)
        try await waitForRouting(model)

        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(dates, [oldDate, newDate])
        XCTAssertNotNil(model.roadPreview)
        XCTAssertNil(model.routingError)
    }

    func testWaypointFocusRegionShowsApproximatelyTenKilometersAroundWaypoint() {
        let waypoint = stop("Aussicht", 50, 12)
        let region = waypointFocusRegion(for: waypoint)
        XCTAssertEqual(region.center.latitude, waypoint.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(region.center.longitude, waypoint.coordinate.longitude, accuracy: 0.000001)
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let north = CLLocation(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                               longitude: region.center.longitude)
        let east = CLLocation(latitude: region.center.latitude,
                              longitude: region.center.longitude + region.span.longitudeDelta / 2)
        XCTAssertEqual(center.distance(from: north), 10_000, accuracy: 150)
        XCTAssertEqual(center.distance(from: east), 10_000, accuracy: 150)
    }

    @MainActor
    func testStageOptimizationKeepsAnchorAndNeverFetchesCrossStageAlternatives() async throws {
        let start = stop("Start", 50, 0)
        let a = stop("A", 50, 1)
        let b = stop("B", 50, 2)
        let overnight = stop("Overnight", 50, 3)
        let c = stop("C", 50, 4)
        let d = stop("D", 50, 5)
        let finish = stop("Finish", 50, 6)
        let cheap = Set(["Start-B", "B-A", "A-Overnight", "Overnight-D", "D-C", "C-Finish"])
        var pairs: [String] = []
        let service = MapKitRouteService { from, to in
            let pair = "\(from.name)-\(to.name)"
            pairs.append(pair)
            return RouteLeg(duration: cheap.contains(pair) ? 60 : 600, distance: 100,
                            coordinates: [from.coordinate, to.coordinate])
        }
        var preview: PlannedRoute?
        var connections: [RouteConnection] = []
        let result = try await service.planRoute(
            start: start, stops: [a, b, overnight, c, d], destination: finish, anchors: [overnight.id], optimize: true,
            onPreview: { preview = $0 }, onConnections: { connections = $0 }, onProgress: { _, _ in }
        )
        XCTAssertEqual(preview?.orderedStops, [a, b, overnight, c, d])
        XCTAssertEqual(result.orderedStops, [b, a, overnight, d, c])
        XCTAssertEqual(result.duration, 360)
        XCTAssertEqual(Set(pairs), cheap.union(["Start-A", "A-B", "B-Overnight", "Overnight-C", "C-D", "D-Finish"]))
        XCTAssertEqual(pairs.count, 12)
        XCTAssertEqual(Set(connections.map { "\($0.from.name)-\($0.to.name)" }), Set(pairs))
        XCTAssertTrue(connections.allSatisfy { $0.leg.coordinates.count == 2 })
    }

    @MainActor
    func testStageTotalsUseOnlyTheirOwnLegsAndCountSharedOvernightStayOnce() async throws {
        let start = stop("Start", 50, 0)
        let overnight = stop("Overnight", 50, 1)
        let finish = stop("Finish", 50, 3)
        let service = MapKitRouteService { from, to in
            RouteLeg(duration: Double(to.coordinate.longitude - from.coordinate.longitude) * 600,
                     distance: 100, coordinates: [from.coordinate, to.coordinate])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(
            start: start, stops: [overnight], destination: finish,
            details: [start.id: WaypointDetails(stayMinutes: 2),
                      overnight.id: WaypointDetails(stayMinutes: 15, overnight: true, stageBudgetMinutes: 25),
                      finish.id: WaypointDetails(stayMinutes: 3)],
            defaultStageBudgetMinutes: 60
        ))
        XCTAssertEqual(model.stages.map(\.waypoints), [[start, overnight], [overnight, finish]])
        XCTAssertTrue(model.stages.allSatisfy { $0.totalDuration == nil })
        model.enableAutomaticRouting()
        for _ in 0..<100 where model.isOptimizing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(model.stages.map(\.driveDuration), [600, 1200])
        XCTAssertEqual(model.stages.map(\.totalDuration), [1620, 1380])
        XCTAssertEqual(model.stages.map(\.budgetMinutes), [25, 60])
        XCTAssertEqual(model.stages.map { $0.coordinates.map(\.longitude) }, [[0, 1], [1, 3]])
        XCTAssertNil(model.stages[0].budgetPlaceholder, "The budget runs out at the planned overnight stop")
        XCTAssertNil(model.stages[0].budgetOverrun, "Only time before arrival counts for the confirmation")
        model.setDefaultStageBudget(10)
        let nextPlaceholder = try XCTUnwrap(model.stages[1].budgetPlaceholder)
        XCTAssertEqual(nextPlaceholder.afterWaypointID, overnight.id)
        XCTAssertEqual(nextPlaceholder.coordinate.longitude, 2, accuracy: 0.00001)

        var details = model.waypointDetails(for: overnight)
        details.stageBudgetMinutes = 10
        model.updateDetails(details, for: overnight)
        let overrun = try XCTUnwrap(model.stages[0].budgetOverrun)
        XCTAssertEqual(overrun.arrivalMinutes - overrun.budgetMinutes, 2)
        XCTAssertNotNil(model.stages[0].budgetPlaceholder)
        XCTAssertNil(model.stages[1].budgetOverrun, "A stage without an overnight stop cannot be accepted")

        model.acceptBudgetOverrun(overrun, endingAt: overnight)
        XCTAssertTrue(model.stages[0].isBudgetOverrunAccepted)
        XCTAssertNil(model.stages[0].budgetPlaceholder)
        XCTAssertEqual(model.stages[0].totalDuration, 1620)
        let saved = try JSONEncoder().encode(model.waypointDetails(for: overnight))
        XCTAssertEqual(try JSONDecoder().decode(WaypointDetails.self, from: saved).acceptedBudgetOverrun, overrun)

        var startDetails = model.waypointDetails(for: start)
        startDetails.stayMinutes = 3
        model.updateDetails(startDetails, for: start)
        XCTAssertFalse(model.stages[0].isBudgetOverrunAccepted)
        XCTAssertNotNil(model.stages[0].budgetPlaceholder)
        let updatedOverrun = try XCTUnwrap(model.stages[0].budgetOverrun)
        model.acceptBudgetOverrun(updatedOverrun, endingAt: overnight)
        model.clearBudgetOverrunAcceptance(endingAt: overnight)
        XCTAssertNotNil(model.stages[0].budgetPlaceholder)
    }

    func testStageBudgetPlaceholderFollowsRoadGeometryAndIncludesStays() throws {
        let start = stop("Start", 0, 0)
        let corner = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let pause = stop("Pause", 0, 4)
        let end = stop("Ende", 0, 5)
        let legs = [
            RouteLeg(duration: 1_200, distance: 444_000, coordinates: [start.coordinate, corner, pause.coordinate]),
            RouteLeg(duration: 600, distance: 111_000, coordinates: [pause.coordinate, end.coordinate])
        ]
        func stage(budget: Int?, hasRoute: Bool = true) -> TripStage {
            TripStage(waypoints: [start, pause, end], legs: hasRoute ? legs : nil, waypointStayMinutes: [5, 10, 0],
                      budgetMinutes: budget, endsWithOvernight: false)
        }
        let onRoad = try XCTUnwrap(stage(budget: 15).budgetPlaceholder)
        XCTAssertEqual(onRoad.afterWaypointID, start.id)
        XCTAssertEqual(onRoad.coordinate.longitude, 2, accuracy: 0.00001)
        let atPause = try XCTUnwrap(stage(budget: 30).budgetPlaceholder)
        XCTAssertEqual(atPause.afterWaypointID, pause.id)
        XCTAssertEqual(atPause.coordinate.longitude, pause.coordinate.longitude)
        XCTAssertNil(stage(budget: 45).budgetPlaceholder)
        XCTAssertNil(stage(budget: nil).budgetPlaceholder)
        XCTAssertNil(stage(budget: 15, hasRoute: false).budgetPlaceholder)
    }
    @MainActor
    func testMapPOIIsInsertedWithoutChangingManualStopOrderOrAddingDuplicates() {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 4)
        let b = stop("B", 3, 4)
        let end = stop("Ziel", 3, 0)
        let cafe = stop("Café", 1.5, 4)
        let model = TripPlannerViewModel()
        model.addMapPOI(cafe)
        XCTAssertTrue(model.stops.isEmpty)

        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end, manualOrder: true))
        model.addMapPOI(cafe)
        model.addMapPOI(stop("CAFE", 1.5001, 4))

        XCTAssertEqual(model.orderedWaypoints, [start, a, cafe, b, end])
        XCTAssertTrue(model.manualOrder)
    }

    @MainActor
    func testMapOvernightInsertionKeepsExistingProvisionalOrder() {
        let start = stop("Start", 50, 11)
        let intermediate = stop("Zwischenziel", 50, 12)
        let end = stop("Ziel", 50, 14)
        let cafe = stop("Café", 50, 12.5)
        let model = TripPlannerViewModel()
        model.setStart(start)
        model.setDestination(end)
        model.addStop(intermediate)
        model.addMapPOI(cafe, asOvernight: true)
        XCTAssertEqual(model.stops, [intermediate, cafe])
        XCTAssertTrue(model.waypointDetails(for: cafe).overnight)
    }

    @MainActor
    func testLiveNearbyPOIsIncludeUnboundCoffee() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROADTRIP_LIVE_POI"] == "1",
                          "Opt in to locating a public cafe via MapKit.")
        let service = MapKitRouteService()
        let matches = try await service.search(for: "Unbound Coffee Innsbruck")
        let cafe = try XCTUnwrap(matches.first { $0.name.localizedCaseInsensitiveContains("Unbound") })
        let area = try XCTUnwrap(MapPOISearchArea(center: cafe.coordinate, clickTolerance: 30))
        let nearby = try await service.nearbyPOIs(in: area)
        XCTAssertTrue(area.nearestPOI(in: nearby)?.stop.matchesMapPlace(cafe) == true)
    }

    func testMapClickPicksNearestPlaceAndRejectsDistantResults() throws {
        let origin = stop("Klick", 50, 12)
        func poi(_ name: String, _ longitude: Double) -> MapPointOfInterest {
            MapPointOfInterest(stop: stop(name, 50, longitude), phoneNumber: nil, website: nil)
        }
        let nearest = poi("Café", 12.00008)
        let second = poi("Laden", 12.0002)
        let distant = poi("Weit weg", 12.001)
        let area = try XCTUnwrap(MapPOISearchArea(center: origin.coordinate, clickTolerance: 20))
        XCTAssertEqual(area.nearestPOI(in: [distant, second, nearest])?.id, nearest.id)
        XCTAssertNil(area.nearestPOI(in: [distant]))
        let zoomedOut = try XCTUnwrap(MapPOISearchArea(center: origin.coordinate, clickTolerance: 500))
        XCTAssertNil(zoomedOut.nearestPOI(in: [distant]))
    }

    @MainActor
    func testPublishesRoadPreviewBeforeCheckingAlternativeOrders() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let provisional = RoadStop.provisionalOrder(start: start, stops: [b, a], destination: end)
        XCTAssertEqual(provisional, [a, b])

        var requests: [String] = []
        var steps: [RouteCalculationStep] = []
        let fasterPairs = ["Start-B", "B-A", "A-Ziel"]
        let service = MapKitRouteService { from, to in
            let pair = "\(from.name)-\(to.name)"
            requests.append(pair)
            return RouteLeg(duration: fasterPairs.contains(pair) ? 1 : 10,
                            distance: fasterPairs.contains(pair) ? 200 : 100, coordinates: [])
        }
        let optimized = try await service.planRoute(
            start: start, stops: provisional, destination: end, optimize: true,
            onPreview: { preview in
                XCTAssertEqual(requests, ["Start-A", "A-B", "B-Ziel"])
                XCTAssertEqual(preview?.orderedStops, [a, b])
                XCTAssertEqual(preview?.duration, 30)
                XCTAssertEqual(preview?.distance, 300)
                XCTAssertEqual(steps, (0...3).map { .streetRoute(done: $0, total: 3) })
            },
            onProgress: { _, _ in },
            onStep: { steps.append($0) }
        )
        XCTAssertEqual(steps, (0...3).map { .streetRoute(done: $0, total: 3) }
                       + (0...3).map { .alternativeLegs(done: $0, total: 3) }
                       + [.comparingOrders])
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(optimized.orderedStops, [b, a])
        XCTAssertEqual(optimized.duration, 3)
        XCTAssertEqual(optimized.distance, 600)
    }

    @MainActor
    func testAddingFifthStopOnlyFetchesTenNewDirectedLegs() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 6)
        let stops = (1...5).map { stop("Stop \($0)", 0, Double($0)) }
        var requests = 0
        let service = MapKitRouteService { _, _ in
            requests += 1
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        }
        _ = try await service.planRoute(start: start, stops: Array(stops.prefix(4)), destination: end, optimize: true,
                                        onPreview: { _ in }, onProgress: { _, _ in })
        XCTAssertEqual(requests, 20)
        var steps: [RouteCalculationStep] = []
        let result = try await service.planRoute(
            start: start, stops: stops, destination: end, optimize: true,
            onPreview: { preview in
                XCTAssertEqual(preview?.orderedStops, stops)
                XCTAssertEqual(requests, 22)
            },
            onProgress: { _, total in XCTAssertEqual(total, 10) },
            onStep: { steps.append($0) }
        )
        XCTAssertEqual(requests, 30)
        XCTAssertEqual(result.duration, 6)
        XCTAssertEqual(result.distance, 600)
        XCTAssertEqual(steps.first, .streetRoute(done: 0, total: 2))
        XCTAssertTrue(steps.contains(.alternativeLegs(done: 0, total: 8)))

        steps.removeAll()
        _ = try await service.planRoute(start: start, stops: stops, destination: end, optimize: true,
                                        onPreview: { XCTAssertNotNil($0) },
                                        onProgress: { _, total in XCTAssertEqual(total, 0) },
                                        onStep: { steps.append($0) })
        XCTAssertEqual(steps, [.comparingOrders])
    }

    @MainActor
    func testFixedRouteInsertsPOIWithOnlyTwoNewLegsAndDoesNotOptimizeAutomatically() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 3)
        let end = stop("Ziel", 0, 4)
        let poi = stop("POI", 0, 2)
        var requests: [String] = []
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            requests.append("\(from.name)-\(to.name)")
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(requests, ["Start-A", "A-B", "B-Ziel"])
        XCTAssertNil(model.suggestion)
        XCTAssertTrue(model.alternativeConnections.isEmpty)

        model.fixCurrentOrder()
        XCTAssertTrue(model.manualOrder)
        model.addMapPOI(poi)
        try await waitForRouting(model)
        XCTAssertEqual(model.stops, [a, poi, b])
        XCTAssertEqual(model.roadPreview?.orderedStops, [a, poi, b])
        XCTAssertEqual(requests, ["Start-A", "A-B", "B-Ziel", "A-POI", "POI-B"])
        XCTAssertNil(model.suggestion)

        model.removeStop(poi)
        try await waitForRouting(model)
        XCTAssertEqual(model.stops, [a, b])
        XCTAssertEqual(requests.count, 5)
    }

    @MainActor
    func testLargeStageCalculatesCurrentRouteButExplicitOptimizationReportsLimit() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 20)
        let stops = (1...19).map { stop("Stop \($0)", 0, Double($0)) }
        var requests = 0
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _ in
            requests += 1
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: stops, destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(requests, 20)
        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertNotNil(model.roadPreview)
        XCTAssertNotNil(model.routingError)
        XCTAssertEqual(requests, 20)
    }

    @MainActor
    func testViewModelDoesNotReorderPreviewUntilSuggestionIsAccepted() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let fasterPairs = [[start, b], [b, a], [a, end]]
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            RouteLeg(duration: fasterPairs.contains([from, to]) ? 1 : 10,
                     distance: fasterPairs.contains([from, to]) ? 200 : 100, coordinates: [])
        })
        model.setStart(start)
        model.addStop(a)
        XCTAssertTrue(model.stops.isEmpty)
        model.setDestination(end)
        model.addStop(b)
        model.addStop(a)
        XCTAssertEqual(model.stops, [a, b])

        model.enableAutomaticRouting()
        model.pauseRouting()
        XCTAssertEqual(model.routeStatus, .paused)
        model.enableAutomaticRouting()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isOptimizing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.suggestion)
        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(model.suggestion?.orderedStops, [b, a])
        XCTAssertEqual(Set(model.alternativeConnections.map { "\($0.from.name)-\($0.to.name)" }),
                       Set(["Start-B", "B-A", "A-Ziel"]))
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(model.stops, [a, b])
        model.acceptSuggestion()
        XCTAssertEqual(model.stops, [b, a])
        XCTAssertTrue(model.manualOrder)
        XCTAssertEqual(model.roadPreview?.duration, 3)
        XCTAssertEqual(model.roadPreview?.distance, 600)
        XCTAssertNil(model.suggestion)
        XCTAssertEqual(Set(model.alternativeConnections.map { "\($0.from.name)-\($0.to.name)" }),
                       Set(["Start-A", "A-B", "B-Ziel"]))
        model.addStop(stop("C", 0, 1.5))
        XCTAssertTrue(model.alternativeConnections.isEmpty)
        model.pauseRouting()
    }

    @MainActor
    func testManualMoveRecalculatesWithoutReplacingTheSelectedOrder() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _ in
            RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.setStart(start)
        model.setDestination(end)
        model.addStop(a)
        model.addStop(b)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.roadPreview?.orderedStops, [a, b])

        model.moveStop(b, by: -1)
        XCTAssertEqual(model.stops, [b, a])
        XCTAssertTrue(model.manualOrder)
        XCTAssertNil(model.roadPreview)
        try await waitForRouting(model)
        XCTAssertEqual(model.roadPreview?.orderedStops, [b, a])
        XCTAssertEqual(model.stops, [b, a])
        model.moveStop(b, by: -1)
        XCTAssertEqual(model.stops, [b, a])
        model.useProvisionalOrder()
        XCTAssertEqual(model.stops, [a, b])
        XCTAssertFalse(model.manualOrder)
        model.pauseRouting()
    }

    @MainActor
    func testNetworkFailureKeepsPreviewAndAllowsRetry() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        var failAlternative = true
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            if failAlternative && from == a && to == end {
                throw URLError(.notConnectedToInternet)
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.setStart(start)
        model.setDestination(end)
        model.addStop(a)
        model.addStop(b)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertEqual(model.roadPreview?.orderedStops, [a, b])
        XCTAssertTrue(model.routingError?.contains("Internetverbindung") == true)
        XCTAssertTrue(model.routingError?.contains("„A“ → „Ziel“") == true)
        XCTAssertFalse(model.routingError?.contains("Parkplatz") == true)
        XCTAssertTrue(model.routingDiagnostic?.contains("Domain: NSURLErrorDomain") == true)
        XCTAssertTrue(model.routingDiagnostic?.contains("Code: -1009") == true)
        XCTAssertEqual(model.alternativeConnections.map { "\($0.from.name)-\($0.to.name)" }, ["Start-B"])

        failAlternative = false
        model.retryRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertNil(model.routingError)
        XCTAssertNil(model.routingDiagnostic)
        XCTAssertEqual(model.roadPreview?.orderedStops, [a, b])
        XCTAssertEqual(model.alternativeConnections.count, 3)
    }

    @MainActor
    func testChangingOvernightBoundaryClearsAlternativeConnections() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _ in
            RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        model.optimizeRoute()
        try await waitForRouting(model)
        XCTAssertEqual(model.alternativeConnections.count, 3)
        var details = model.waypointDetails(for: a)
        details.overnight = true
        model.updateDetails(details, for: a)
        XCTAssertTrue(model.alternativeConnections.isEmpty)
        try await waitForRouting(model)
        XCTAssertEqual(model.roadPreview?.orderedStops, [a, b])
        XCTAssertTrue(model.alternativeConnections.isEmpty)
    }

    @MainActor
    func testUnavailableCurrentLegReportsFailureAndCanBeRetried() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 1)
        var available = false
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _ in
            available ? RouteLeg(duration: 1, distance: 100, coordinates: []) : nil
        })
        model.setStart(start)
        model.setDestination(end)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertNil(model.roadPreview)
        XCTAssertTrue(model.routingError?.contains("„Start“ → „Ziel“") == true)
        XCTAssertTrue(model.routingError?.contains("Parkplatz") == true)
        XCTAssertTrue(model.routingError?.contains("weder den betroffenen Wegpunkt noch den Grund") == true)
        XCTAssertTrue(model.routingDiagnostic?.contains("keine weitere Fehlerursache") == true)
        available = true
        model.retryRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertNotNil(model.roadPreview)
    }

    @MainActor
    func testUnavailableConnectionsIdentifyAllAffectedPairs() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            from == a && to == b ? RouteLeg(duration: 1, distance: 100, coordinates: []) : nil
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)

        XCTAssertEqual(model.routeStatus, .failed)
        let error = try XCTUnwrap(model.routingError)
        XCTAssertTrue(error.contains("„Start“ → „A“"))
        XCTAssertTrue(error.contains("„B“ → „Ziel“"))
        XCTAssertFalse(error.contains("„A“ → „B“"))
        XCTAssertEqual(model.currentConnections.map { "\($0.from.name)-\($0.to.name)" }, ["A-B"])
        XCTAssertEqual(model.unavailableConnections.map { "\($0.from.name)-\($0.to.name)" },
                       ["Start-A", "B-Ziel"])
    }

    @MainActor
    func testTechnicalFailureDoesNotPreventLaterCurrentConnections() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let end = stop("Ziel", 0, 2)
        var fail = true
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            if from == start && to == a && fail { throw URLError(.timedOut) }
            return RouteLeg(duration: 1, distance: 100, coordinates: [from.coordinate, to.coordinate])
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a], destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)

        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertEqual(model.currentConnections.map { "\($0.from.name)-\($0.to.name)" }, ["A-Ziel"])
        XCTAssertTrue(model.unavailableConnections.isEmpty)
        XCTAssertTrue(model.routingError?.contains("„Start“ → „A“") == true)
        XCTAssertEqual(model.currentRequestErrors.count, 1)

        fail = false
        model.retryRouting()
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertNotNil(model.roadPreview)
    }

    @MainActor
    func testMultipleTechnicalFailuresRemainIdentifiable() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            if from == a && to == b {
                return RouteLeg(duration: 1, distance: 100, coordinates: [])
            }
            throw URLError(.timedOut)
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)

        XCTAssertEqual(model.currentConnections.map { "\($0.from.name)-\($0.to.name)" }, ["A-B"])
        XCTAssertEqual(model.currentRequestErrors.count, 2)
        XCTAssertTrue(model.currentRequestErrors[0].contains("„Start“ → „A“"))
        XCTAssertTrue(model.currentRequestErrors[1].contains("„B“ → „Ziel“"))
        let diagnostic = try XCTUnwrap(model.routingDiagnostic)
        XCTAssertTrue(diagnostic.contains("„Start“ ("))
        XCTAssertTrue(diagnostic.contains("„Ziel“ ("))
        XCTAssertEqual(diagnostic.components(separatedBy: "Code: -1001").count - 1, 2)
    }

    @MainActor
    func testDirectionsNotFoundPreservesMapKitErrorAndRetryClearsIt() async throws {
        let start = stop("Start", 50, 10)
        let end = stop("Ziel", 51, 11)
        var requests = 0
        let service = MapKitRouteService { _, _ in
            requests += 1
            if requests == 1 {
                throw NSError(domain: MKErrorDomain, code: Int(MKError.Code.directionsNotFound.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "MapKit-Testfehler"])
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        }
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)

        XCTAssertEqual(model.routeStatus, .failed)
        XCTAssertEqual(model.unavailableConnections.count, 1)
        let diagnostic = try XCTUnwrap(model.routingDiagnostic)
        XCTAssertTrue(diagnostic.contains("Domain: \(MKErrorDomain), Code: \(MKError.Code.directionsNotFound.rawValue)"))
        XCTAssertTrue(diagnostic.contains("MapKit-Testfehler"))
        XCTAssertTrue(model.currentRequestErrors.isEmpty)

        model.retryRouting()
        try await waitForRouting(model)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertNil(model.routingDiagnostic)
    }

    @MainActor
    func testDiagnosticIncludesUnderlyingErrorAndAppTimeout() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let end = stop("Ziel", 0, 2)
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, _ in
            if from == start {
                throw NSError(domain: "OuterDomain", code: 42, userInfo: [
                    NSLocalizedDescriptionKey: "Außerer Fehler",
                    NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1009,
                                                  userInfo: [NSLocalizedDescriptionKey: "Offline"])
                ])
            }
            throw MapKitRouteError.timeout("A", "Ziel")
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a], destination: end, manualOrder: true))
        model.enableAutomaticRouting()
        try await waitForRouting(model)

        let diagnostic = try XCTUnwrap(model.routingDiagnostic)
        XCTAssertTrue(diagnostic.contains("Domain: OuterDomain, Code: 42"))
        XCTAssertTrue(diagnostic.contains("Domain: NSURLErrorDomain, Code: -1009"))
        XCTAssertTrue(diagnostic.contains("App-seitiges Zeitlimit von 12 Sekunden"))
        XCTAssertEqual(model.currentRequestErrors.count, 2)
    }

    @MainActor
    func testParkingSuggestionsCheckBothAdjacentConnectionsAndKeepOriginalWaypoint() async throws {
        let start = stop("Start", 0, 0)
        let blocked = stop("Aussicht", 0, 1)
        let end = stop("Ziel", 0, 2)
        let unreachable = stop("Parkplatz ohne Zufahrt", 0, 1.001)
        let accessible = stop("Parkplatz", 0, 1.002)
        var requests: [String] = []
        let departureDate = Date(timeIntervalSince1970: 2_000_000_000)
        var dates: [Date?] = []
        let service = MapKitRouteService(fetchLeg: { from, to, date in
            dates.append(date)
            requests.append("\(from.name)-\(to.name)")
            if from == start && to == blocked { return nil }
            if from == unreachable && to == end {
                throw NSError(domain: MKErrorDomain, code: Int(MKError.Code.directionsNotFound.rawValue))
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [from.coordinate, to.coordinate])
        }, findParking: { waypoint in
            XCTAssertEqual(waypoint, blocked)
            return [unreachable, accessible]
        })
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, stops: [blocked], destination: end, manualOrder: true),
                            departureDate: departureDate)
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        model.searchParking(near: blocked)
        for _ in 0..<100 where model.isSearchingParking { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertFalse(model.isSearchingParking)
        XCTAssertNil(model.parkingSearchError)
        XCTAssertEqual(model.parkingSuggestions, [accessible])
        XCTAssertTrue(requests.contains("Start-Parkplatz"))
        XCTAssertTrue(requests.contains("Parkplatz-Ziel"))
        XCTAssertTrue(dates.allSatisfy { $0 == departureDate })
        XCTAssertEqual(model.orderedWaypoints, [start, blocked, end])
        model.setDestination(stop("Neues Ziel", 0, 3))
        XCTAssertTrue(model.parkingSuggestions.isEmpty)
    }

    @MainActor
    func testParkingSearchErrorsAreReportedWithoutOfferingUnverifiedCandidates() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 1)
        let candidate = stop("Parkplatz", 0, 1.001)
        let service = MapKitRouteService(fetchLeg: { from, to in
            if to == candidate { throw URLError(.notConnectedToInternet) }
            return nil
        }, findParking: { _ in [candidate] })
        let model = TripPlannerViewModel(routeService: service)
        model.loadWaypoints(TripWaypoints(start: start, destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        model.searchParking(near: end)
        for _ in 0..<100 where model.isSearchingParking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.parkingSuggestions.isEmpty)
        XCTAssertTrue(model.parkingSearchError?.contains("Internetverbindung") == true)
    }

    @MainActor
    func testOptimizationCanRecoverFromUnavailableCurrentOrder() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let service = MapKitRouteService { from, to in
            if from == a && to == b {
                throw NSError(domain: MKErrorDomain, code: Int(MKError.Code.directionsNotFound.rawValue))
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        }
        let route = try await service.planRoute(
            start: start, stops: [a, b], destination: end, optimize: true,
            onPreview: { XCTAssertNil($0) }, onProgress: { _, _ in }
        )
        XCTAssertEqual(route.orderedStops, [b, a])
    }

    @MainActor
    func testOptimizationReportsUnavailableCurrentConnectionsWhenNoOrderWorks() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let end = stop("Ziel", 0, 2)
        let service = MapKitRouteService { _, _ in nil }
        do {
            _ = try await service.planRoute(
                start: start, stops: [a], destination: end, optimize: true,
                onPreview: { _ in }, onProgress: { _, _ in }
            )
            XCTFail("Expected an unavailable route")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("„Start“ → „A“"))
            XCTAssertTrue(error.localizedDescription.contains("„A“ → „Ziel“"))
        }
    }

    @MainActor
    func testMovingStopCancelsAnInFlightRoute() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let requestStarted = expectation(description: "Old route request started")
        var firstRequest = true
        let model = TripPlannerViewModel(routeService: MapKitRouteService { _, _ in
            if firstRequest {
                firstRequest = false
                requestStarted.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.setStart(start)
        model.setDestination(end)
        model.addStop(a)
        model.addStop(b)
        model.enableAutomaticRouting()
        await fulfillment(of: [requestStarted], timeout: 2)
        model.moveStop(b, by: -1)
        try await waitForRouting(model)
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(model.roadPreview?.orderedStops, [b, a])
        XCTAssertEqual(model.stops, [b, a])
        XCTAssertNil(model.routingError)
    }

    @MainActor
    func testEditingDuringOptimizationCancelsItAndCalculatesOnlyTheNewOrder() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let alternativeStarted = expectation(description: "Alternative request started")
        var requests: [String] = []
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            let pair = "\(from.name)-\(to.name)"
            requests.append(pair)
            if pair == "Start-B" {
                alternativeStarted.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
            return RouteLeg(duration: 1, distance: 100, coordinates: [])
        })
        model.loadWaypoints(TripWaypoints(start: start, stops: [a, b], destination: end))
        model.enableAutomaticRouting()
        try await waitForRouting(model)
        model.optimizeRoute()
        await fulfillment(of: [alternativeStarted], timeout: 2)
        model.removeStop(b)
        XCTAssertTrue(model.alternativeConnections.isEmpty)
        try await waitForRouting(model)
        XCTAssertEqual(model.roadPreview?.orderedStops, [a])
        XCTAssertNil(model.suggestion)
        XCTAssertNil(model.routingError)
        XCTAssertTrue(model.alternativeConnections.isEmpty)
        XCTAssertEqual(requests, ["Start-A", "A-B", "B-Ziel", "Start-B", "A-Ziel"])
    }

    @MainActor
    func testSearchNetworkFailureCanBeRetried() async throws {
        let result = stop("Berlin", 52.52, 13.4)
        var attempts = 0
        let model = TripPlannerViewModel(findPlaces: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return [result]
        })
        model.updateSearch("Berlin", in: .start)
        try await waitForSearch(model)
        XCTAssertTrue(model.errorMessage?.contains("Internetverbindung") == true)
        model.updateSearch(model.query, in: .start)
        try await waitForSearch(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.searchResults, [result])
    }

    @MainActor
    func testMapItemPreservesWaypointNameAndCoordinates() {
        let waypoint = stop("Berlin", 52.52, 13.4)
        let item = MapKitRouteService.mapItem(for: waypoint)
        XCTAssertEqual(item.name, waypoint.name)
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        XCTAssertEqual(coordinate.latitude, waypoint.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, waypoint.coordinate.longitude, accuracy: 0.000001)
    }

    @MainActor
    private func waitForRouting(_ model: TripPlannerViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isOptimizing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isOptimizing)
    }

    @MainActor
    func testInlineSearchDebouncesTypingAndDoesNotReplaceWaypointUntilSelection() async throws {
        let current = stop("Bayreuth", 49.94, 11.58)
        let result = stop("Berlin", 52.52, 13.40)
        var queries: [String] = []
        let model = TripPlannerViewModel(findPlaces: { query in
            queries.append(query)
            return [result]
        })
        model.setStart(current)
        model.updateSearch("Be", in: .start)
        model.updateSearch("Ber", in: .start)
        model.updateSearch("Berlin", in: .start)
        try await waitForSearch(model)

        XCTAssertEqual(queries, ["Berlin"])
        XCTAssertEqual(model.start, current)
        XCTAssertFalse(model.chooseSearchResult(result, in: .destination))
        XCTAssertTrue(model.chooseSearchResult(result, in: .start))
        XCTAssertEqual(model.start, result)
        XCTAssertEqual(model.fieldText(.start), "Berlin")
    }

    @MainActor
    func testSwitchingFieldsDiscardsPreviousSearchAndCanAddIntermediateStop() async throws {
        let start = stop("Bayreuth", 49.94, 11.58)
        let destination = stop("Mailand", 45.46, 9.19)
        let middle = stop("Innsbruck", 47.27, 11.40)
        let replacement = stop("Bozen", 46.50, 11.35)
        let oldSearchStarted = expectation(description: "Previous search started")
        let model = TripPlannerViewModel(findPlaces: { query in
            switch query {
            case "Alter Treffer":
                oldSearchStarted.fulfill()
                try? await Task.sleep(for: .seconds(2))
                return [start]
            case "Mailand": return [destination]
            case "Innsbruck": return [middle]
            default: return [replacement]
            }
        })
        model.setStart(start)
        model.updateSearch("Alter Treffer", in: .start)
        await fulfillment(of: [oldSearchStarted], timeout: 2)
        model.updateSearch("Mailand", in: .destination)
        try await waitForSearch(model)
        XCTAssertEqual(model.searchResults, [destination])
        XCTAssertTrue(model.chooseSearchResult(destination, in: .destination))
        XCTAssertEqual(model.start, start)
        XCTAssertEqual(model.destination, destination)

        model.updateSearch("Innsbruck", in: .newStop)
        try await waitForSearch(model)
        XCTAssertTrue(model.chooseSearchResult(middle, in: .newStop))
        model.updateSearch("Bozen", in: .stop(middle.id))
        try await waitForSearch(model)
        XCTAssertTrue(model.chooseSearchResult(replacement, in: .stop(middle.id)))
        XCTAssertEqual(model.orderedWaypoints, [start, replacement, destination])
    }

    @MainActor
    private func waitForSearch(_ model: TripPlannerViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isSearching && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testLiveWalkingRoundTripInBerlin() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROADTRIP_LIVE_MAPKIT"] == "1",
                          "Opt in to live MapKit requests with public city-center coordinates.")
        let start = stop("Brandenburger Tor", 52.51627, 13.37770)
        let destination = start.newOccurrence()
        let reichstag = stop("Reichstag", 52.51862, 13.37619)
        let museum = stop("Museumsinsel", 52.52080, 13.39890)
        let square = stop("Gendarmenmarkt", 52.51371, 13.39286)
        let model = TripPlannerViewModel()
        model.loadWaypoints(TripWaypoints(start: start, stops: [reichstag, museum, square], destination: destination,
                                           manualOrder: true, isRoundTrip: true))
        model.setMode(.walking, for: model.stages[0])
        model.enableAutomaticRouting()
        defer { model.pauseRouting() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while model.isOptimizing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isOptimizing, "Live walking route timed out.")
        XCTAssertNil(model.routingError, model.routingDiagnostic ?? "")
        let route = try XCTUnwrap(model.roadPreview, model.routingDiagnostic ?? "No walking route returned.")
        XCTAssertEqual(route.legs.count, 4)
        XCTAssertTrue(route.legs.allSatisfy { $0.duration > 0 && $0.coordinates.count >= 2 })

        model.setDepartureDate(Date().addingTimeInterval(86_400))
        let datedDeadline = ContinuousClock.now.advanced(by: .seconds(40))
        while model.isOptimizing && ContinuousClock.now < datedDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isOptimizing, "Dated live walking route timed out.")
        XCTAssertNil(model.routingError, model.routingDiagnostic ?? "")
        let datedRoute = try XCTUnwrap(model.roadPreview, model.routingDiagnostic ?? "No dated walking route returned.")
        XCTAssertEqual(datedRoute.legs.count, 4)
        XCTAssertTrue(datedRoute.legs.allSatisfy { $0.duration > 0 && $0.coordinates.count >= 2 })
    }

    @MainActor
    func testLiveBayreuthOsloProgress() async throws {
        try await measureLiveRoute(destination: stop("Oslo", 59.9164997, 10.7384202), stops: [
            stop("Berlin", 52.5187416, 13.4080224),
            stop("Hamburg", 53.5506117, 9.9927152),
            stop("Odense", 55.3980796, 10.3817523),
            stop("Göteborg", 57.7037215, 11.9700202),
            stop("Malmö", 55.6051632, 12.9974452)
        ])
    }

    @MainActor
    func testLiveBayreuthMilanProgress() async throws {
        try await measureLiveRoute(destination: stop("Mailand", 45.46420, 9.19000), stops: [
            stop("Prag", 50.07554, 14.43780),
            stop("Innsbruck", 47.26921, 11.40410),
            stop("Salzburg", 47.80949, 13.05501),
            stop("Passau", 48.56674, 13.43195),
            stop("Garmisch-Partenkirchen", 47.49213, 11.09550),
            stop("Bozen", 46.49830, 11.35476)
        ])
    }

    @MainActor
    private func measureLiveRoute(destination: RoadStop, stops: [RoadStop]) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROADTRIP_LIVE_MAPKIT"] == "1",
                          "Opt in to live MapKit requests with public city-center coordinates.")
        let start = stop("Bayreuth", 49.9460399, 11.5805231)
        func routeName(_ intermediateStops: [RoadStop]) -> String {
            ([start] + intermediateStops + [destination]).map(\.name).joined(separator: " → ")
        }

        let model = TripPlannerViewModel()
        model.setStart(start)
        model.setDestination(destination)
        let clock = ContinuousClock()
        let draftStart = clock.now
        for stop in stops { model.addStop(stop) }
        print("DRAFT: \(routeName(model.stops)) after \(draftStart.duration(to: clock.now))")

        let requestStart = clock.now
        var previewRequests: Int?
        let previewObservation = model.$roadPreview.sink { preview in
            guard previewRequests == nil, let preview else { return }
            previewRequests = model.completedRequests
            print("ROAD PREVIEW: \(preview.duration / 60) min after \(requestStart.duration(to: clock.now)), \(model.completedRequests) requests")
        }
        model.enableAutomaticRouting()
        defer {
            previewObservation.cancel()
            model.pauseRouting()
        }
        let deadline = requestStart.advanced(by: .seconds(100))
        while model.isOptimizing && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isOptimizing, "Benchmark timed out.")
        XCTAssertNil(model.routingError)
        XCTAssertEqual(previewRequests, stops.count + 1)
        XCTAssertEqual(model.completedRequests, stops.count + 1)
        model.optimizeRoute()
        while model.isOptimizing && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isOptimizing, "Optimization benchmark timed out.")
        XCTAssertNil(model.routingError)
        XCTAssertEqual(model.completedRequests, stops.count * (stops.count + 1) - (stops.count + 1))
        let preview = try XCTUnwrap(model.roadPreview)
        let result = model.suggestion ?? preview
        XCTAssertEqual(result.orderedStops.count, stops.count)
        XCTAssertEqual(Set(result.orderedStops.map(\.id)), Set(stops.map(\.id)))
        XCTAssertLessThanOrEqual(result.duration, preview.duration)
        XCTAssertGreaterThan(preview.distance, 0)
        XCTAssertGreaterThan(result.distance, 0)
        XCTAssertFalse(result.coordinates.isEmpty)
        print("OPTIMIZED: \(routeName(result.orderedStops)), " +
              "\(result.duration / 60) min after \(requestStart.duration(to: clock.now)), " +
              "\(model.completedRequests + (previewRequests ?? 0)) total requests")
    }

    private func stop(_ name: String, _ latitude: Double, _ longitude: Double) -> RoadStop {
        RoadStop(name: name, subtitle: "",
                 coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
}
