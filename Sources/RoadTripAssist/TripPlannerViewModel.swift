import Combine
import CoreLocation
import Foundation

@MainActor
final class TripPlannerViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var searchResults: [RoadStop] = []
    @Published private(set) var start: RoadStop?
    @Published private(set) var stops: [RoadStop] = []
    @Published private(set) var destination: RoadStop?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var routeDuration: TimeInterval?
    @Published private(set) var isSearching = false
    @Published private(set) var isOptimizing = false
    @Published private(set) var errorMessage: String?

    private let routeService = MapKitRouteService()

    var orderedWaypoints: [RoadStop] {
        ([start].compactMap { $0 }) + stops + [destination].compactMap { $0 }
    }

    var routingRequestCount: Int {
        guard start != nil, destination != nil else { return 0 }
        let stopCount = stops.count
        return stopCount == 0 ? 1 : stopCount * stopCount + stopCount
    }

    func search() {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return }

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
        start = stop
        clearRoute()
    }

    func addStop(_ stop: RoadStop) {
        stops.append(stop)
        clearRoute()
    }

    func setDestination(_ stop: RoadStop) {
        destination = stop
        clearRoute()
    }

    func removeStop(_ stop: RoadStop) {
        stops.removeAll { $0.id == stop.id }
        clearRoute()
    }

    func optimizeRoute() {
        guard let start, let destination else { return }
        isOptimizing = true
        errorMessage = nil
        Task {
            defer { isOptimizing = false }
            do {
                let route = try await routeService.optimizedRoute(
                    start: start,
                    stops: stops,
                    destination: destination
                )
                stops = route.orderedStops
                routeDuration = route.duration
                routeCoordinates = route.coordinates
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearRoute() {
        routeDuration = nil
        routeCoordinates = []
    }
}
