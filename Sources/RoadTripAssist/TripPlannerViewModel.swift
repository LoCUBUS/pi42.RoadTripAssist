import Combine
import Foundation

enum WaypointField: Hashable {
    case start, destination, stop(RoadStop.ID), newStop
}

enum RouteCalculationStatus: Equatable {
    case idle, preparing, running(RouteCalculationStep), finished, paused, failed
}

@MainActor
final class TripPlannerViewModel: ObservableObject {
    @Published private(set) var searchField: WaypointField?
    @Published private(set) var query = ""
    @Published private(set) var searchResults: [RoadStop] = []
    @Published private(set) var searchFinished = false
    @Published private(set) var start: RoadStop?
    @Published private(set) var stops: [RoadStop] = []
    @Published private(set) var destination: RoadStop?
    @Published private(set) var roadPreview: PlannedRoute?
    @Published private(set) var suggestion: PlannedRoute?
    @Published private(set) var isProvisional = true
    @Published private(set) var automaticRouting = false
    @Published private(set) var completedRequests = 0
    @Published private(set) var totalRequests = 0
    @Published private(set) var isSearching = false
    @Published private(set) var routeStatus: RouteCalculationStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var routingError: String?

    private let routeService: MapKitRouteService
    private let findPlaces: @MainActor (String) async throws -> [RoadStop]
    private var routingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    var onWaypointsChanged: ((TripWaypoints) -> Void)?

    init(routeService: MapKitRouteService? = nil,
         findPlaces: (@MainActor (String) async throws -> [RoadStop])? = nil) {
        let service = routeService ?? MapKitRouteService()
        self.routeService = service
        self.findPlaces = findPlaces ?? service.search(for:)
    }

    deinit {
        routingTask?.cancel()
        searchTask?.cancel()
    }

    var orderedWaypoints: [RoadStop] {
        ([start].compactMap { $0 }) + stops + [destination].compactMap { $0 }
    }

    var hasEndpoints: Bool { start != nil && destination != nil }

    var isOptimizing: Bool {
        switch routeStatus {
        case .preparing, .running: true
        default: false
        }
    }

    func fieldText(_ field: WaypointField) -> String {
        searchField == field ? query : waypoint(in: field)?.name ?? ""
    }

    func beginSearch(in field: WaypointField) {
        guard searchField != field else { return }
        cancelSearch()
        query = waypoint(in: field)?.name ?? ""
        searchField = field
    }

    func updateSearch(_ text: String, in field: WaypointField) {
        beginSearch(in: field)
        searchTask?.cancel()
        searchTask = nil
        query = text
        searchResults = []
        searchFinished = false
        errorMessage = nil
        let searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = searchText.count >= 2
        guard isSearching else { return }

        let findPlaces = self.findPlaces
        searchTask = Task { [weak self] in
            defer {
                if !Task.isCancelled {
                    self?.isSearching = false
                    self?.searchTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let results = try await findPlaces(searchText)
                try Task.checkCancellation()
                self?.searchResults = results
                self?.searchFinished = true
            } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        searchField = nil
        query = ""
        searchResults = []
        searchFinished = false
        errorMessage = nil
    }

    @discardableResult
    func chooseSearchResult(_ result: RoadStop, in field: WaypointField) -> Bool {
        guard searchField == field, searchResults.contains(result) else { return false }
        switch field {
        case .start:
            setStart(result)
        case .destination:
            setDestination(result)
        case .newStop:
            guard hasEndpoints else { return false }
            addStop(result)
        case .stop(let id):
            guard let index = stops.firstIndex(where: { $0.id == id }) else { return false }
            stops[index] = result
            waypointsChanged()
        }
        cancelSearch()
        return true
    }

    private func waypoint(in field: WaypointField) -> RoadStop? {
        switch field {
        case .start: start
        case .destination: destination
        case .newStop: nil
        case .stop(let id): stops.first { $0.id == id }
        }
    }

    func loadWaypoints(_ waypoints: TripWaypoints) {
        pauseRouting()
        cancelSearch()
        start = waypoints.start
        stops = waypoints.stops
        destination = waypoints.destination
        clearRoute()
        scheduleRouting()
    }

    func setStart(_ stop: RoadStop) {
        guard canUseAsStart(stop) else { return }
        start = stop
        waypointsChanged()
    }

    func addStop(_ stop: RoadStop) {
        guard hasEndpoints, !orderedWaypoints.contains(stop) else { return }
        stops.append(stop)
        waypointsChanged()
    }

    func setDestination(_ stop: RoadStop) {
        guard canUseAsDestination(stop) else { return }
        destination = stop
        waypointsChanged()
    }

    func removeStop(_ stop: RoadStop) {
        if searchField == .stop(stop.id) { cancelSearch() }
        stops.removeAll { $0.id == stop.id }
        waypointsChanged()
    }

    func canUseAsStart(_ stop: RoadStop) -> Bool {
        stop != start && stop != destination && !stops.contains(stop)
    }

    func canUseAsDestination(_ stop: RoadStop) -> Bool {
        canUseAsStart(stop)
    }

    func enableAutomaticRouting() {
        automaticRouting = true
        scheduleRouting()
    }

    func pauseRouting() {
        automaticRouting = false
        routingTask?.cancel()
        if isOptimizing || routeStatus == .failed { routeStatus = .paused }
    }

    func acceptSuggestion() {
        guard let suggestion else { return }
        stops = suggestion.orderedStops
        roadPreview = suggestion
        isProvisional = false
        self.suggestion = nil
        publishWaypoints()
    }

    private func waypointsChanged() {
        if let start, let destination {
            stops = RoadStop.provisionalOrder(start: start, stops: stops, destination: destination)
        }
        clearRoute()
        publishWaypoints()
        scheduleRouting()
    }

    private func clearRoute() {
        roadPreview = nil
        suggestion = nil
        isProvisional = true
    }

    private func publishWaypoints() {
        onWaypointsChanged?(TripWaypoints(start: start, stops: stops, destination: destination))
    }

    private func scheduleRouting() {
        let previous = routingTask
        previous?.cancel()
        completedRequests = 0
        totalRequests = 0
        routingError = nil
        guard automaticRouting, let start, let destination else {
            routeStatus = .idle
            return
        }
        let stops = self.stops
        let service = routeService
        routeStatus = .preparing
        routingTask = Task { [weak self] in
            defer {
                if !Task.isCancelled {
                    self?.routingTask = nil
                }
            }
            do {
                await previous?.value
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                let route = try await service.planRoute(
                    start: start, stops: stops, destination: destination,
                    onPreview: { [weak self] route in self?.roadPreview = route },
                    onProgress: { [weak self] done, total in
                        self?.completedRequests = done
                        self?.totalRequests = total
                    },
                    onStep: { [weak self] step in self?.routeStatus = .running(step) }
                )
                try Task.checkCancellation()
                if let preview = self?.roadPreview, preview.duration <= route.duration {
                    self?.isProvisional = false
                } else {
                    self?.suggestion = route
                }
                self?.routeStatus = .finished
            } catch {
                if !Task.isCancelled {
                    self?.routingError = error.localizedDescription
                    self?.routeStatus = .failed
                }
            }
        }
    }
}
