import CoreLocation
import MapKit

struct MapPointOfInterest: Identifiable {
    let stop: RoadStop
    let phoneNumber: String?
    let website: URL?

    var id: RoadStop.ID { stop.id }
}

struct MapPOISearchArea: Equatable {
    let latitude: Double
    let longitude: Double
    let radius: CLLocationDistance

    init?(center: CLLocationCoordinate2D, clickTolerance: CLLocationDistance) {
        guard CLLocationCoordinate2DIsValid(center), clickTolerance.isFinite,
              clickTolerance > 0 else { return nil }
        latitude = center.latitude
        longitude = center.longitude
        radius = min(clickTolerance, 60)
    }

    var center: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    func nearestPOI(in candidates: [MapPointOfInterest]) -> MapPointOfInterest? {
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        return candidates.lazy.map { poi in
            let coordinate = poi.stop.coordinate
            let distance = origin.distance(from: CLLocation(latitude: coordinate.latitude,
                                                            longitude: coordinate.longitude))
            return (poi, distance)
        }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }
}

struct RouteLeg {
    let duration: TimeInterval
    let distance: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]
}

struct PlannedRoute {
    let orderedStops: [RoadStop]
    let duration: TimeInterval
    let distance: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]
}

enum RouteCalculationStep: Equatable {
    case streetRoute(done: Int, total: Int)
    case alternativeLegs(done: Int, total: Int)
    case comparingOrders
}

@MainActor
final class MapKitRouteService {
    private struct Pair: Hashable {
        let from: UUID
        let to: UUID
    }

    private enum CachedLeg {
        case available(RouteLeg)
        case unavailable

        var route: RouteLeg? {
            if case let .available(leg) = self { return leg }
            return nil
        }
    }

    private var legs: [Pair: CachedLeg] = [:]
    private let fetchLeg: @MainActor (RoadStop, RoadStop) async throws -> RouteLeg?

    init(fetchLeg: (@MainActor (RoadStop, RoadStop) async throws -> RouteLeg?)? = nil) {
        self.fetchLeg = fetchLeg ?? Self.calculateLeg
    }

    func search(for query: String) async throws -> [RoadStop] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]

        let items = try await searchItems(MKLocalSearch(request: request))
        return items.compactMap(roadStop(for:))
    }

    func nearbyPOIs(in area: MapPOISearchArea) async throws -> [MapPointOfInterest] {
        let request = MKLocalPointsOfInterestRequest(center: area.center, radius: area.radius)
        let items = try await searchItems(MKLocalSearch(request: request))
        return items.compactMap { item in
            roadStop(for: item).map {
                MapPointOfInterest(stop: $0, phoneNumber: item.phoneNumber, website: item.url)
            }
        }
    }

    private func searchItems(_ search: MKLocalSearch) async throws -> [MKMapItem] {
        let response: MKLocalSearch.Response
        do {
            response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await search.start()
            } onCancel: {
                Task { @MainActor in search.cancel() }
            }
        } catch {
            try Task.checkCancellation()
            if (error as? MKError)?.code == .placemarkNotFound { return [] }
            throw error
        }
        try Task.checkCancellation()
        return response.mapItems
    }

    private func roadStop(for item: MKMapItem) -> RoadStop? {
        guard let name = item.name, !name.isEmpty else { return nil }
        return RoadStop(name: name, subtitle: subtitle(for: item), coordinate: coordinate(for: item))
    }

    func planRoute(
        start: RoadStop,
        stops: [RoadStop],
        destination: RoadStop,
        onPreview: (PlannedRoute?) -> Void,
        onProgress: (Int, Int) -> Void,
        onStep: (RouteCalculationStep) -> Void = { _ in }
    ) async throws -> PlannedRoute {
        try Task.checkCancellation()
        let locations = [start] + stops + [destination]
        let activeIDs = Set(locations.map(\.id))
        guard activeIDs.count == locations.count else {
            throw RouteOptimizationError.invalidStopIndices
        }
        legs = legs.filter { activeIDs.contains($0.key.from) && activeIDs.contains($0.key.to) }
        let end = locations.count - 1
        let indices = Array(1..<end)
        let previewPairs = pathPairs(locations)
        let supportsExactOptimization = stops.count <= RouteOptimizer.maximumExactStopCount
        var extraPairs: [Pair] = []
        if supportsExactOptimization {
            let previewSet = Set(previewPairs)
            for from in 0..<end {
                for to in 1...end where from != to && (from != 0 || to != end) {
                    let pair = Pair(from: locations[from].id, to: locations[to].id)
                    if !previewSet.contains(pair) { extraPairs.append(pair) }
                }
            }
        }
        let allPairs = previewPairs + extraPairs
        let stopsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
        let missingCount = allPairs.count { legs[$0] == nil }
        var fetched = 0
        onProgress(fetched, missingCount)

        func loadLegs(_ pairs: [Pair], step: (Int, Int) -> RouteCalculationStep) async throws {
            let pending = pairs.filter { legs[$0] == nil }
            guard !pending.isEmpty else { return }
            onStep(step(0, pending.count))
            for (index, pair) in pending.enumerated() {
                try Task.checkCancellation()
                guard let from = stopsByID[pair.from], let to = stopsByID[pair.to] else {
                    throw RouteOptimizationError.invalidStopIndices
                }
                let leg = try await fetchLeg(from, to)
                try Task.checkCancellation()
                legs[pair] = leg.map(CachedLeg.available) ?? .unavailable
                fetched += 1
                onProgress(fetched, missingCount)
                onStep(step(index + 1, pending.count))
            }
        }

        try await loadLegs(previewPairs, step: RouteCalculationStep.streetRoute(done:total:))
        onPreview(route(for: locations))

        guard supportsExactOptimization else {
            throw RouteOptimizationError.tooManyStops(stops.count)
        }
        try await loadLegs(extraPairs, step: RouteCalculationStep.alternativeLegs(done:total:))
        if !stops.isEmpty { onStep(.comparingOrders) }

        let matrix = locations.map { from in
            locations.map { to in
                legs[Pair(from: from.id, to: to.id)]?.route?.duration ?? .infinity
            }
        }
        let optimization = Task.detached {
            try RouteOptimizer.optimize(travelTimes: matrix, startIndex: 0,
                                        stopIndices: indices, destinationIndex: end)
        }
        let order = try await withTaskCancellationHandler {
            try await optimization.value
        } onCancel: {
            optimization.cancel()
        }
        try Task.checkCancellation()
        guard let route = route(for: [start] + order.map { locations[$0] } + [destination]) else {
            throw MapKitRouteError.missingRoute
        }
        return route
    }

    private func pathPairs(_ locations: [RoadStop]) -> [Pair] {
        zip(locations, locations.dropFirst()).map { Pair(from: $0.id, to: $1.id) }
    }

    private func route(for locations: [RoadStop]) -> PlannedRoute? {
        let pairs = pathPairs(locations)
        let available = pairs.compactMap { legs[$0]?.route }
        guard available.count == pairs.count else { return nil }
        return PlannedRoute(orderedStops: Array(locations.dropFirst().dropLast()),
                            duration: available.reduce(0) { $0 + $1.duration },
                            distance: available.reduce(0) { $0 + $1.distance },
                            coordinates: available.flatMap(\.coordinates))
    }

    static func mapItem(for stop: RoadStop) -> MKMapItem {
        let item: MKMapItem
        if #available(macOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: stop.coordinate.latitude,
                                                  longitude: stop.coordinate.longitude), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: stop.coordinate))
        }
        item.name = stop.name
        return item
    }

    private static func calculateLeg(from: RoadStop, to: RoadStop) async throws -> RouteLeg? {
        let request = MKDirections.Request()
        request.source = mapItem(for: from)
        request.destination = mapItem(for: to)
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        var timedOut = false
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            timedOut = true
            directions.cancel()
        }
        defer { timeout.cancel() }

        let response: MKDirections.Response
        do {
            response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await directions.calculate()
            } onCancel: {
                Task { @MainActor in directions.cancel() }
            }
        } catch {
            try Task.checkCancellation()
            if timedOut { throw MapKitRouteError.timeout(from.name, to.name) }
            if (error as? MKError)?.code == .directionsNotFound { return nil }
            throw error
        }
        try Task.checkCancellation()
        if timedOut { throw MapKitRouteError.timeout(from.name, to.name) }
        guard let route = response.routes.min(by: {
            $0.expectedTravelTime < $1.expectedTravelTime
        }) else { return nil }

        let points = route.polyline.points()
        let coordinates = (0..<route.polyline.pointCount).map { points[$0].coordinate }
        return RouteLeg(duration: route.expectedTravelTime, distance: route.distance, coordinates: coordinates)
    }

    private func coordinate(for item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(macOS 26.0, *) {
            item.location.coordinate
        } else {
            item.placemark.coordinate
        }
    }

    private func subtitle(for item: MKMapItem) -> String {
        if #available(macOS 26.0, *) {
            item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
        } else {
            item.placemark.title ?? ""
        }
    }
}

enum MapKitRouteError: Error, LocalizedError {
    case missingRoute
    case timeout(String, String)

    var errorDescription: String? {
        switch self {
        case .missingRoute:
            "MapKit hat keine durchgehende Autoroute gefunden."
        case let .timeout(from, to):
            "MapKit hat für \(from) → \(to) nicht rechtzeitig geantwortet."
        }
    }
}
