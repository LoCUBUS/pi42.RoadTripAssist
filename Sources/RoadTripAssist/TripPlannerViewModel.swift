import Combine
import Foundation

@MainActor
final class TripPlannerViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var searchResults: [RoadStop] = []
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
    @Published private(set) var isOptimizing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var routingError: String?

    private let routeService: MapKitRouteService
    private var routingTask: Task<Void, Never>?

    init(routeService: MapKitRouteService? = nil) {
        self.routeService = routeService ?? MapKitRouteService()
    }

    deinit { routingTask?.cancel() }

    var orderedWaypoints: [RoadStop] {
        ([start].compactMap { $0 }) + stops + [destination].compactMap { $0 }
    }

    var hasEndpoints: Bool { start != nil && destination != nil }

    func search() {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty, !isSearching else { return }

        searchResults = []
        isSearching = true
        errorMessage = nil
        Task {
            defer { isSearching = false }
            do {
                searchResults = try await routeService.search(for: searchText)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        isOptimizing = false
    }

    func acceptSuggestion() {
        guard let suggestion else { return }
        stops = suggestion.orderedStops
        roadPreview = suggestion
        isProvisional = false
        self.suggestion = nil
    }

    private func waypointsChanged() {
        if let start, let destination {
            stops = RoadStop.provisionalOrder(start: start, stops: stops, destination: destination)
        }
        roadPreview = nil
        suggestion = nil
        isProvisional = true
        scheduleRouting()
    }

    private func scheduleRouting() {
        let previous = routingTask
        previous?.cancel()
        completedRequests = 0
        totalRequests = 0
        routingError = nil
        guard automaticRouting, let start, let destination else { return }
        let stops = self.stops
        let service = routeService
        isOptimizing = true
        routingTask = Task { [weak self] in
            defer {
                if !Task.isCancelled {
                    self?.isOptimizing = false
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
                    })
                try Task.checkCancellation()
                if let preview = self?.roadPreview, preview.duration <= route.duration {
                    self?.isProvisional = false
                } else {
                    self?.suggestion = route
                }
            } catch {
                if !Task.isCancelled { self?.routingError = error.localizedDescription }
            }
        }
    }
}
