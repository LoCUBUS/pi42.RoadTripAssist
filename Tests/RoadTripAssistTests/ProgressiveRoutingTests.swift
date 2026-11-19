import Combine
import CoreLocation
import XCTest
@testable import RoadTripAssist

final class ProgressiveRoutingTests: XCTestCase {
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
            return RouteLeg(duration: fasterPairs.contains(pair) ? 1 : 10, coordinates: [])
        }
        let optimized = try await service.planRoute(
            start: start, stops: provisional, destination: end,
            onPreview: { preview in
                XCTAssertEqual(requests, ["Start-A", "A-B", "B-Ziel"])
                XCTAssertEqual(preview?.orderedStops, [a, b])
                XCTAssertEqual(preview?.duration, 30)
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
    }

    @MainActor
    func testAddingFifthStopOnlyFetchesTenNewDirectedLegs() async throws {
        let start = stop("Start", 0, 0)
        let end = stop("Ziel", 0, 6)
        let stops = (1...5).map { stop("Stop \($0)", 0, Double($0)) }
        var requests = 0
        let service = MapKitRouteService { _, _ in
            requests += 1
            return RouteLeg(duration: 1, coordinates: [])
        }
        _ = try await service.planRoute(start: start, stops: Array(stops.prefix(4)), destination: end,
                                        onPreview: { _ in }, onProgress: { _, _ in })
        XCTAssertEqual(requests, 20)
        var steps: [RouteCalculationStep] = []
        let result = try await service.planRoute(
            start: start, stops: stops, destination: end,
            onPreview: { preview in
                XCTAssertEqual(preview?.orderedStops, stops)
                XCTAssertEqual(requests, 22)
            },
            onProgress: { _, total in XCTAssertEqual(total, 10) },
            onStep: { steps.append($0) }
        )
        XCTAssertEqual(requests, 30)
        XCTAssertEqual(result.duration, 6)
        XCTAssertEqual(steps.first, .streetRoute(done: 0, total: 2))
        XCTAssertTrue(steps.contains(.alternativeLegs(done: 0, total: 8)))

        steps.removeAll()
        _ = try await service.planRoute(start: start, stops: stops, destination: end,
                                        onPreview: { XCTAssertNotNil($0) },
                                        onProgress: { _, total in XCTAssertEqual(total, 0) },
                                        onStep: { steps.append($0) })
        XCTAssertEqual(steps, [.comparingOrders])
    }

    @MainActor
    func testViewModelDoesNotReorderPreviewUntilSuggestionIsAccepted() async throws {
        let start = stop("Start", 0, 0)
        let a = stop("A", 0, 1)
        let b = stop("B", 0, 2)
        let end = stop("Ziel", 0, 3)
        let fasterPairs = [[start, b], [b, a], [a, end]]
        let model = TripPlannerViewModel(routeService: MapKitRouteService { from, to in
            RouteLeg(duration: fasterPairs.contains([from, to]) ? 1 : 10, coordinates: [])
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
        XCTAssertEqual(model.suggestion?.orderedStops, [b, a])
        XCTAssertEqual(model.routeStatus, .finished)
        XCTAssertEqual(model.stops, [a, b])
        model.acceptSuggestion()
        XCTAssertEqual(model.stops, [b, a])
        XCTAssertEqual(model.roadPreview?.duration, 3)
        XCTAssertNil(model.suggestion)
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
        XCTAssertEqual(model.completedRequests, stops.count * (stops.count + 1))
        let preview = try XCTUnwrap(model.roadPreview)
        let result = model.suggestion ?? preview
        XCTAssertEqual(result.orderedStops.count, stops.count)
        XCTAssertEqual(Set(result.orderedStops.map(\.id)), Set(stops.map(\.id)))
        XCTAssertLessThanOrEqual(result.duration, preview.duration)
        XCTAssertFalse(result.coordinates.isEmpty)
        print("OPTIMIZED: \(routeName(result.orderedStops)), " +
              "\(result.duration / 60) min after \(requestStart.duration(to: clock.now)), \(model.completedRequests) requests")
    }

    private func stop(_ name: String, _ latitude: Double, _ longitude: Double) -> RoadStop {
        RoadStop(name: name, subtitle: "",
                 coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
}
