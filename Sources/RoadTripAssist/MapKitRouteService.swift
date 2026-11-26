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
    var isTransit = false

    func coordinate(atFraction fraction: Double) -> CLLocationCoordinate2D? {
        guard !isTransit else { return nil }
        let worldWidth = MKMapRect.world.width
        let points = coordinates.map(MKMapPoint.init)
        let segments = zip(points, points.dropFirst()).map { from, to -> (MKMapPoint, MKMapPoint, Double) in
            var to = to
            if to.x - from.x > worldWidth / 2 { to.x -= worldWidth }
            if to.x - from.x < -worldWidth / 2 { to.x += worldWidth }
            let latitude = (from.coordinate.latitude + to.coordinate.latitude) / 2
            let length = hypot(to.x - from.x, to.y - from.y) * MKMetersPerMapPointAtLatitude(latitude)
            return (from, to, length)
        }
        guard let last = coordinates.last else { return nil }
        var remaining = segments.reduce(0) { $0 + $1.2 } * fraction
        for (from, to, length) in segments where length > 0 {
            if remaining <= length {
                let progress = remaining / length
                let x = from.x + (to.x - from.x) * progress
                return MKMapPoint(x: x < 0 ? x + worldWidth : (x >= worldWidth ? x - worldWidth : x),
                                  y: from.y + (to.y - from.y) * progress).coordinate
            }
            remaining -= length
        }
        return last
    }
}

struct PlannedRoute {
    let orderedStops: [RoadStop]
    let legs: [RouteLeg]

    var duration: TimeInterval { legs.reduce(0) { $0 + $1.duration } }
    var distance: CLLocationDistance { legs.reduce(0) { $0 + $1.distance } }
    var coordinates: [CLLocationCoordinate2D] { legs.flatMap(\.coordinates) }
}

struct RouteConnection: Identifiable {
    struct ID: Hashable {
        let from: RoadStop.ID
        let to: RoadStop.ID
    }

    let from: RoadStop
    let to: RoadStop
    let leg: RouteLeg

    var id: ID { ID(from: from.id, to: to.id) }
}

struct UnavailableRouteConnection: Identifiable {
    let from: RoadStop
    let to: RoadStop
    let underlyingError: Error?
    var id: RouteConnection.ID { .init(from: from.id, to: to.id) }
}

struct RouteRequestFailure {
    let from: RoadStop
    let to: RoadStop
    let error: Error
}

struct RouteRequestActivity {
    let from: RoadStop
    let to: RoadStop
    let mode: MapKitRouteService.Transport
    let startedAt: Date
}

enum RouteCalculationStep: Equatable {
    case streetRoute(done: Int, total: Int)
    case alternativeLegs(done: Int, total: Int)
    case comparingOrders
}

@MainActor
final class MapKitRouteService {
    enum Transport: Hashable {
        case driving, walking, transit
    }

    private struct Pair: Hashable {
        let from: UUID
        let to: UUID
        let mode: Transport
    }

    private enum CachedLeg {
        case available(RouteLeg)
        case unavailable(Error?)

        var route: RouteLeg? {
            if case let .available(leg) = self { return leg }
            return nil
        }
    }

    private var legs: [Pair: CachedLeg] = [:]
    private var cachedDepartureDate: Date?
    private let fetchLeg: @MainActor (RoadStop, RoadStop, Date?, Transport) async throws -> RouteLeg?
    private let findParking: @MainActor (RoadStop) async throws -> [RoadStop]

    init(fetchLeg: (@MainActor (RoadStop, RoadStop, Date?, Transport) async throws -> RouteLeg?)? = nil,
         findParking: (@MainActor (RoadStop) async throws -> [RoadStop])? = nil) {
        self.fetchLeg = fetchLeg ?? Self.calculateLeg
        self.findParking = findParking ?? Self.searchParking
    }

    convenience init(fetchLeg: @escaping @MainActor (RoadStop, RoadStop) async throws -> RouteLeg?,
                     findParking: (@MainActor (RoadStop) async throws -> [RoadStop])? = nil) {
        self.init(fetchLeg: { from, to, _, _ in try await fetchLeg(from, to) }, findParking: findParking)
    }

    convenience init(fetchLeg: @escaping @MainActor (RoadStop, RoadStop, Date?) async throws -> RouteLeg?,
                     findParking: (@MainActor (RoadStop) async throws -> [RoadStop])? = nil) {
        self.init(fetchLeg: { from, to, date, _ in try await fetchLeg(from, to, date) }, findParking: findParking)
    }

    func independentService() -> MapKitRouteService {
        MapKitRouteService(fetchLeg: fetchLeg, findParking: findParking)
    }

    func clearUnavailableLegs() {
        legs = legs.filter { $0.value.route != nil }
    }

    func clearLegs() {
        legs.removeAll()
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
        anchors: Set<RoadStop.ID> = [],
        optimize: Bool,
        departureDate: Date? = nil,
        stageModes: [RoadStop.ID: TravelMode] = [:],
        transitLegs: Set<TransitLeg> = [],
        roundTripEndIDs: Set<RoadStop.ID> = [],
        onPreview: (PlannedRoute?) -> Void,
        onCurrentConnections: ([RouteConnection], [UnavailableRouteConnection], [RouteRequestFailure]) -> Void = { _, _, _ in },
        onRequest: (RouteRequestActivity?) -> Void = { _ in },
        onConnections: ([RouteConnection]) -> Void = { _ in },
        onProgress: (Int, Int) -> Void,
        onStep: (RouteCalculationStep) -> Void = { _ in }
    ) async throws -> PlannedRoute {
        try Task.checkCancellation()
        if departureDate != cachedDepartureDate {
            legs.removeAll()
            cachedDepartureDate = departureDate
        }
        let locations = [start] + stops + [destination]
        let activeIDs = Set(locations.map(\.id))
        guard activeIDs.count == locations.count else {
            throw RouteOptimizationError.invalidStopIndices
        }
        legs = legs.filter { activeIDs.contains($0.key.from) && activeIDs.contains($0.key.to) }
        let stages = TripStage.ranges(in: locations, anchors: anchors)
        func pair(_ from: RoadStop, _ to: RoadStop, in stage: ClosedRange<Int>) -> Pair {
            let stageMode = stageModes[locations[stage.upperBound].id] ?? .driving
            let mode: Transport = stageMode == .driving ? .driving
                : (transitLegs.contains(TransitLeg(from: from.id, to: to.id)) ? .transit : .walking)
            return Pair(from: from.id, to: to.id, mode: mode)
        }
        func pairs(_ ordered: [RoadStop]) -> [Pair] {
            TripStage.ranges(in: ordered, anchors: anchors).flatMap { stage in
                zip(ordered[stage].dropLast(), ordered[stage].dropFirst()).map { from, to in
                    let stageMode = stageModes[ordered[stage.upperBound].id] ?? .driving
                    let mode: Transport = stageMode == .driving ? .driving
                        : (transitLegs.contains(TransitLeg(from: from.id, to: to.id)) ? .transit : .walking)
                    return Pair(from: from.id, to: to.id, mode: mode)
                }
            }
        }
        let previewPairs = pairs(locations)
        let largestStage = stages.map { $0.count - 2 }.max() ?? 0
        let supportsExactOptimization = largestStage <= RouteOptimizer.maximumExactStopCount
        var extraPairs: [Pair] = []
        if optimize && supportsExactOptimization {
            let previewSet = Set(previewPairs)
            for stage in stages {
                let start = stage.lowerBound
                let end = stage.upperBound
                for from in start..<end {
                    for to in (start + 1)...end where from != to && (from != start || to != end) {
                        let candidate = pair(locations[from], locations[to], in: stage)
                        if !previewSet.contains(candidate) { extraPairs.append(candidate) }
                    }
                }
            }
        }
        let allPairs = previewPairs + extraPairs
        let stopsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
        let missingCount = allPairs.count { legs[$0] == nil }
        var fetched = 0
        onProgress(fetched, missingCount)

        var previewFailures: [RouteRequestFailure] = []
        func publishConnections() {
            let current = previewPairs.compactMap { pair -> RouteConnection? in
                guard let from = stopsByID[pair.from], let to = stopsByID[pair.to],
                      let leg = legs[pair]?.route else { return nil }
                return RouteConnection(from: from, to: to, leg: leg)
            }
            let unavailable = previewPairs.compactMap { pair -> UnavailableRouteConnection? in
                guard case .unavailable(let error)? = legs[pair],
                      let from = stopsByID[pair.from], let to = stopsByID[pair.to] else { return nil }
                return UnavailableRouteConnection(from: from, to: to, underlyingError: error)
            }
            onCurrentConnections(current, unavailable, previewFailures)
            guard optimize else { return }
            onConnections(allPairs.compactMap { pair in
                guard let from = stopsByID[pair.from], let to = stopsByID[pair.to],
                      let leg = legs[pair]?.route else { return nil }
                return RouteConnection(from: from, to: to, leg: leg)
            })
        }

        publishConnections()
        var firstPreviewError: Error?
        func loadLegs(_ pairs: [Pair], continueAfterError: Bool,
                      step: (Int, Int) -> RouteCalculationStep) async throws {
            let pending = pairs.filter { legs[$0] == nil }
            guard !pending.isEmpty else { return }
            onStep(step(0, pending.count))
            for (index, pair) in pending.enumerated() {
                try Task.checkCancellation()
                guard let from = stopsByID[pair.from], let to = stopsByID[pair.to] else {
                    throw RouteOptimizationError.invalidStopIndices
                }
                onRequest(RouteRequestActivity(from: from, to: to, mode: pair.mode, startedAt: Date()))
                defer { onRequest(nil) }
                let leg: RouteLeg?
                do {
                    if roundTripEndIDs.contains(to.id) && pair.mode != .transit
                        && from.coordinate.latitude == to.coordinate.latitude
                        && from.coordinate.longitude == to.coordinate.longitude {
                        leg = RouteLeg(duration: 0, distance: 0, coordinates: [from.coordinate, to.coordinate])
                    } else if var result = try await fetchLeg(from, to, departureDate, pair.mode) {
                        result.isTransit = pair.mode == .transit
                        leg = result
                    } else {
                        leg = nil
                    }
                } catch {
                    try Task.checkCancellation()
                    if (error as? MKError)?.code == .directionsNotFound {
                        legs[pair] = .unavailable(error)
                        publishConnections()
                        fetched += 1
                        onProgress(fetched, missingCount)
                        onStep(step(index + 1, pending.count))
                        continue
                    }
                    let requestError: Error
                    if case MapKitRouteError.timeout = error {
                        requestError = error
                    } else {
                        requestError = MapKitRouteError.requestFailed(from: from.name, to: to.name, underlying: error)
                    }
                    guard continueAfterError else { throw requestError }
                    if firstPreviewError == nil { firstPreviewError = requestError }
                    previewFailures.append(RouteRequestFailure(from: from, to: to, error: requestError))
                    publishConnections()
                    fetched += 1
                    onProgress(fetched, missingCount)
                    onStep(step(index + 1, pending.count))
                    continue
                }
                try Task.checkCancellation()
                legs[pair] = leg.map(CachedLeg.available) ?? .unavailable(nil)
                publishConnections()
                fetched += 1
                onProgress(fetched, missingCount)
                onStep(step(index + 1, pending.count))
            }
        }

        try await loadLegs(previewPairs, continueAfterError: true, step: RouteCalculationStep.streetRoute(done:total:))
        func route(for ordered: [RoadStop]) -> PlannedRoute? {
            let path = pairs(ordered)
            let available = path.compactMap { legs[$0]?.route }
            guard available.count == path.count else { return nil }
            return PlannedRoute(orderedStops: Array(ordered.dropFirst().dropLast()), legs: available)
        }
        func missingRouteError(for ordered: [RoadStop]) -> MapKitRouteError {
            let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
            let unavailable = pairs(ordered).compactMap { pair -> String? in
                guard case .unavailable? = legs[pair], let from = byID[pair.from], let to = byID[pair.to] else {
                    return nil
                }
                return "„\(from.name)“ → „\(to.name)“"
            }
            return pairs(ordered).contains(where: { $0.mode != .driving })
                ? .missingConnection(unavailable) : .missingRoute(unavailable)
        }
        let preview = route(for: locations)
        onPreview(preview)
        if let firstPreviewError { throw firstPreviewError }

        if !optimize {
            guard let preview else { throw missingRouteError(for: locations) }
            return preview
        }

        guard supportsExactOptimization else {
            throw RouteOptimizationError.tooManyStops(largestStage)
        }
        try await loadLegs(extraPairs, continueAfterError: false, step: RouteCalculationStep.alternativeLegs(done:total:))
        if !stops.isEmpty { onStep(.comparingOrders) }

        let matrices = stages.map { stage in
            locations[stage].map { from in
                locations[stage].map { to in
                    legs[pair(from, to, in: stage)]?.route?.duration ?? .infinity
                }
            }
        }
        let optimization = Task.detached {
            try zip(stages, matrices).flatMap { stage, matrix in
                let end = stage.count - 1
                let order = try RouteOptimizer.optimize(travelTimes: matrix, startIndex: 0,
                                                        stopIndices: Array(1..<end), destinationIndex: end)
                return (order + [end]).map { stage.lowerBound + $0 }
            }
        }
        let order: [Int]
        do {
            order = try await withTaskCancellationHandler {
                try await optimization.value
            } onCancel: {
                optimization.cancel()
            }
        } catch RouteOptimizationError.noCompleteRoute where preview == nil {
            throw missingRouteError(for: locations)
        }
        try Task.checkCancellation()
        guard let route = route(for: [start] + order.map { locations[$0] }) else {
            throw missingRouteError(for: [start] + order.map { locations[$0] })
        }
        return route
    }

    func accessibleParking(near waypoint: RoadStop, previous: RoadStop?, next: RoadStop?,
                           departureDate: Date? = nil) async throws -> [RoadStop] {
        let candidates = try await findParking(waypoint)
        var result: [RoadStop] = []
        for candidate in candidates.prefix(5) {
            try Task.checkCancellation()
            if let previous, try await !parkingConnectionAvailable(from: previous, to: candidate, departureDate: departureDate) { continue }
            if let next, try await !parkingConnectionAvailable(from: candidate, to: next, departureDate: departureDate) { continue }
            result.append(candidate)
        }
        return result
    }

    private func parkingConnectionAvailable(from: RoadStop, to: RoadStop, departureDate: Date?) async throws -> Bool {
        do {
            return try await fetchLeg(from, to, departureDate, .driving) != nil
        } catch {
            try Task.checkCancellation()
            if (error as? MKError)?.code == .directionsNotFound { return false }
            throw error
        }
    }

    private static func searchParking(near waypoint: RoadStop) async throws -> [RoadStop] {
        let request = MKLocalPointsOfInterestRequest(center: waypoint.coordinate, radius: 2_000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await search.start()
        } onCancel: {
            Task { @MainActor in search.cancel() }
        }
        try Task.checkCancellation()
        let origin = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
        return response.mapItems.compactMap { item -> RoadStop? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let coordinate: CLLocationCoordinate2D
            let subtitle: String
            if #available(macOS 26.0, *) {
                coordinate = item.location.coordinate
                subtitle = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
            } else {
                coordinate = item.placemark.coordinate
                subtitle = item.placemark.title ?? ""
            }
            guard origin.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= 2_000 else {
                return nil
            }
            return RoadStop(name: name, subtitle: subtitle, coordinate: coordinate)
        }.sorted { $0.distance(to: waypoint) < $1.distance(to: waypoint) }
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

    static func directionsRequest(from: RoadStop, to: RoadStop, departureDate: Date?,
                                  mode: Transport = .driving) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = mapItem(for: from)
        request.destination = mapItem(for: to)
        switch mode {
        case .driving: request.transportType = .automobile
        case .walking: request.transportType = .walking
        case .transit: request.transportType = .transit
        }
        request.departureDate = departureDate
        return request
    }

    private static func calculateLeg(from: RoadStop, to: RoadStop, departureDate: Date?,
                                     mode: Transport) async throws -> RouteLeg? {
        let request = directionsRequest(from: from, to: to, departureDate: departureDate, mode: mode)
        let directions = MKDirections(request: request)
        var timedOut = false
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            timedOut = true
            directions.cancel()
        }
        defer { timeout.cancel() }

        if mode == .transit {
            do {
                let eta = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await directions.calculateETA()
                } onCancel: {
                    Task { @MainActor in directions.cancel() }
                }
                try Task.checkCancellation()
                if timedOut { throw MapKitRouteError.timeout(from.name, to.name) }
                return RouteLeg(duration: eta.expectedTravelTime, distance: eta.distance,
                                coordinates: [], isTransit: true)
            } catch {
                try Task.checkCancellation()
                if timedOut { throw MapKitRouteError.timeout(from.name, to.name) }
                throw error
            }
        }
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
    case missingRoute([String])
    case missingConnection([String])
    case timeout(String, String)
    case requestFailed(from: String, to: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingConnection(let connections):
            return "MapKit konnte diese Verbindungen nicht berechnen: \(connections.joined(separator: ", ")). Prüfe beide Punkte und das gewählte Verkehrsmittel."
        case .missingRoute(let connections):
            if connections.isEmpty {
                return "MapKit hat keine durchgehende Autoroute gefunden."
            }
            return "Für diese Verbindungen wurde keine Autoroute gefunden: \(connections.joined(separator: ", ")). MapKit nennt weder den betroffenen Wegpunkt noch den Grund. Prüfe beide Punkte und ihre Zufahrt; falls nötig, suche einen Parkplatz in der Nähe und gehe den Rest zu Fuß."
        case let .timeout(from, to):
            return "MapKit hat für \(from) → \(to) nicht rechtzeitig geantwortet."
        case let .requestFailed(from, to, underlying):
            return "Fehler bei der Verbindung „\(from)“ → „\(to)“: \(underlying.localizedDescription)"
        }
    }
}
