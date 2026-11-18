import CoreLocation
import MapKit

struct RouteLeg {
    let duration: TimeInterval
    let coordinates: [CLLocationCoordinate2D]
}

struct OptimizedRoute {
    let orderedStops: [RoadStop]
    let duration: TimeInterval
    let coordinates: [CLLocationCoordinate2D]
    let requestedLegCount: Int
}

@MainActor
final class MapKitRouteService {
    func search(for query: String) async throws -> [RoadStop] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            return RoadStop(
                name: name,
                subtitle: item.placemark.title ?? "",
                coordinate: item.placemark.coordinate
            )
        }
    }

    func optimizedRoute(
        start: RoadStop,
        stops: [RoadStop],
        destination: RoadStop
    ) async throws -> OptimizedRoute {
        guard stops.count <= RouteOptimizer.maximumExactStopCount else {
            throw RouteOptimizationError.tooManyStops(stops.count)
        }

        let locations = [start] + stops + [destination]
        let destinationIndex = locations.count - 1
        let stopIndices = Array(1..<destinationIndex)
        var legs = Array(
            repeating: Array<RouteLeg?>(repeating: nil, count: locations.count),
            count: locations.count
        )
        var durations = Array(
            repeating: Array(repeating: TimeInterval.infinity, count: locations.count),
            count: locations.count
        )
        for index in locations.indices {
            durations[index][index] = 0
        }

        var requiredPairs: [(Int, Int)] = []
        if stopIndices.isEmpty {
            requiredPairs.append((0, destinationIndex))
        } else {
            requiredPairs.append(contentsOf: stopIndices.map { (0, $0) })
            for from in stopIndices {
                for to in stopIndices where from != to {
                    requiredPairs.append((from, to))
                }
            }
            requiredPairs.append(contentsOf: stopIndices.map { ($0, destinationIndex) })
        }

        for (from, to) in requiredPairs {
            if let leg = try await calculateLeg(from: locations[from], to: locations[to]) {
                legs[from][to] = leg
                durations[from][to] = leg.duration
            }
        }

        let order = try RouteOptimizer.optimize(
            travelTimes: durations,
            startIndex: 0,
            stopIndices: stopIndices,
            destinationIndex: locations.count - 1
        )
        let orderedStops = order.map { locations[$0] }
        let routeIndices = [0] + order + [locations.count - 1]

        var routeCoordinates: [CLLocationCoordinate2D] = []
        var routeDuration: TimeInterval = 0
        for (from, to) in zip(routeIndices, routeIndices.dropFirst()) {
            guard let leg = legs[from][to] else {
                throw MapKitRouteError.missingRoute
            }
            routeDuration += leg.duration
            routeCoordinates.append(contentsOf: leg.coordinates)
        }

        return OptimizedRoute(
            orderedStops: orderedStops,
            duration: routeDuration,
            coordinates: routeCoordinates,
            requestedLegCount: requiredPairs.count
        )
    }

    private func calculateLeg(from: RoadStop, to: RoadStop) async throws -> RouteLeg? {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.min(by: {
            $0.expectedTravelTime < $1.expectedTravelTime
        }) else { return nil }

        let points = route.polyline.points()
        let coordinates = (0..<route.polyline.pointCount).map { points[$0].coordinate }
        return RouteLeg(duration: route.expectedTravelTime, coordinates: coordinates)
    }
}

enum MapKitRouteError: Error, LocalizedError {
    case missingRoute

    var errorDescription: String? {
        switch self {
        case .missingRoute:
            "MapKit did not return a drivable route for one or more stops."
        }
    }
}
