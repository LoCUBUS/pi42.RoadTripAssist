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
    @Published private(set) var manualOrder = false
    @Published private(set) var destination: RoadStop?
    @Published private(set) var departureDate: Date?
    @Published private(set) var details: [RoadStop.ID: WaypointDetails] = [:]
    @Published private(set) var defaultStageBudgetMinutes: Int?
    @Published private(set) var roadPreview: PlannedRoute?
    @Published private(set) var suggestion: PlannedRoute?
    @Published private(set) var optimizationConnections: [RouteConnection] = []
    @Published private(set) var currentConnections: [RouteConnection] = []
    @Published private(set) var unavailableConnections: [UnavailableRouteConnection] = []
    @Published private(set) var currentRequestErrors: [String] = []
    @Published private(set) var parkingSearchWaypoint: RoadStop?
    @Published private(set) var parkingSuggestions: [RoadStop] = []
    @Published private(set) var isSearchingParking = false
    @Published private(set) var parkingSearchError: String?
    @Published private(set) var isProvisional = true
    @Published private(set) var automaticRouting = false
    @Published private(set) var completedRequests = 0
    @Published private(set) var totalRequests = 0
    @Published private(set) var isSearching = false
    @Published private(set) var routeStatus: RouteCalculationStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var routingError: String?
    @Published private(set) var routingDiagnostic: String?

    private let routeService: MapKitRouteService
    private let findPlaces: @MainActor (String) async throws -> [RoadStop]
    private var routingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var parkingSearchTask: Task<Void, Never>?
    private var lastRoutingWasOptimization = false
    private var currentRequestFailures: [RouteRequestFailure] = []
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
        parkingSearchTask?.cancel()
    }

    var orderedWaypoints: [RoadStop] {
        ([start].compactMap { $0 }) + stops + [destination].compactMap { $0 }
    }

    var hasEndpoints: Bool { start != nil && destination != nil }

    var alternativeConnections: [RouteConnection] {
        let currentPairs = Set(zip(orderedWaypoints, orderedWaypoints.dropFirst()).map {
            RouteConnection.ID(from: $0.id, to: $1.id)
        })
        return optimizationConnections.filter { !currentPairs.contains($0.id) }
    }

    private var anchors: Set<RoadStop.ID> {
        Set(stops.filter { details[$0.id]?.overnight == true }.map(\.id))
    }

    var stages: [TripStage] {
        guard hasEndpoints else { return [] }
        let waypoints = orderedWaypoints
        let legs = roadPreview.flatMap { route in
            route.orderedStops == stops && route.legs.count == waypoints.count - 1 ? route.legs : nil
        }
        return TripStage.ranges(in: waypoints, anchors: anchors).map { range in
            let stageLegs = legs.map { Array($0[range.lowerBound..<range.upperBound]) }
            let endDetails = details[waypoints[range.upperBound].id]
            return TripStage(waypoints: Array(waypoints[range]), legs: stageLegs,
                             waypointStayMinutes: range.map { index in
                                 index != 0 && index == range.lowerBound ? 0 : details[waypoints[index].id]?.stayMinutes ?? 0
                             },
                             budgetMinutes: endDetails?.stageBudgetMinutes ?? defaultStageBudgetMinutes,
                             endsWithOvernight: endDetails?.overnight == true,
                             acceptedBudgetOverrun: endDetails?.acceptedBudgetOverrun)
        }
    }

    var nextWaypoint: RoadStop? {
        guard hasEndpoints else { return nil }
        return orderedWaypoints.dropFirst().first { waypointDetails(for: $0).status == .pending }
    }

    func waypointDetails(for stop: RoadStop) -> WaypointDetails {
        details[stop.id] ?? WaypointDetails()
    }

    func updateDetails(_ updated: WaypointDetails, for stop: RoadStop) {
        guard orderedWaypoints.contains(stop) else { return }
        let previous = waypointDetails(for: stop)
        var updated = updated
        if !updated.overnight || updated.stageBudgetMinutes != previous.stageBudgetMinutes {
            updated.acceptedBudgetOverrun = nil
        }
        guard previous != updated else { return }
        details[stop.id] = updated
        publishWaypoints()
        if stops.contains(stop), previous.overnight != updated.overnight {
            suggestion = nil
            optimizationConnections = []
            isProvisional = true
            scheduleRouting()
        }
    }

    func acceptBudgetOverrun(_ overrun: StageBudgetOverrun, endingAt stop: RoadStop) {
        guard stages.first(where: { $0.id == stop.id })?.budgetOverrun == overrun else { return }
        var updated = waypointDetails(for: stop)
        updated.acceptedBudgetOverrun = overrun
        updateDetails(updated, for: stop)
    }

    func clearBudgetOverrunAcceptance(endingAt stop: RoadStop) {
        var updated = waypointDetails(for: stop)
        updated.acceptedBudgetOverrun = nil
        updateDetails(updated, for: stop)
    }

    func setVisitStatus(_ status: VisitStatus, for stop: RoadStop) {
        guard stop != start else { return }
        var updated = waypointDetails(for: stop)
        updated.status = status
        updateDetails(updated, for: stop)
    }

    func setDefaultStageBudget(_ minutes: Int?) {
        guard defaultStageBudgetMinutes != minutes else { return }
        defaultStageBudgetMinutes = minutes
        publishWaypoints()
    }

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
                if !Task.isCancelled { self?.errorMessage = Self.serviceErrorMessage(error) }
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

    func waypoint(in field: WaypointField) -> RoadStop? {
        switch field {
        case .start: start
        case .destination: destination
        case .newStop: nil
        case .stop(let id): stops.first { $0.id == id }
        }
    }

    func loadWaypoints(_ waypoints: TripWaypoints, departureDate: Date? = nil) {
        pauseRouting()
        cancelSearch()
        start = waypoints.start
        stops = waypoints.stops
        destination = waypoints.destination
        manualOrder = waypoints.manualOrder
        details = waypoints.details
        defaultStageBudgetMinutes = waypoints.defaultStageBudgetMinutes
        self.departureDate = departureDate
        clearRoute()
        scheduleRouting()
    }

    func setDepartureDate(_ date: Date?) {
        guard departureDate != date else { return }
        departureDate = date
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

    func hasMapPlace(_ stop: RoadStop) -> Bool {
        orderedWaypoints.contains { $0.matchesMapPlace(stop) }
    }

    func addMapPOI(_ stop: RoadStop, asOvernight: Bool = false) {
        guard hasEndpoints, !hasMapPlace(stop) else { return }
        if asOvernight || manualOrder || !anchors.isEmpty {
            stops.insert(stop, at: RoadStop.bestInsertionIndex(for: stop, along: orderedWaypoints))
        } else {
            stops.append(stop)
        }
        if asOvernight { details[stop.id] = WaypointDetails(overnight: true) }
        waypointsChanged()
    }

    func nearbyPOIs(in area: MapPOISearchArea) async throws -> [MapPointOfInterest] {
        try await routeService.nearbyPOIs(in: area)
    }

    func searchParking(near waypoint: RoadStop) {
        let waypoints = orderedWaypoints
        guard unavailableConnections.contains(where: { $0.from == waypoint || $0.to == waypoint }),
              let index = waypoints.firstIndex(of: waypoint) else { return }
        cancelParkingSearch()
        parkingSearchWaypoint = waypoint
        isSearchingParking = true
        let previous = index > 0 ? waypoints[index - 1] : nil
        let next = index + 1 < waypoints.count ? waypoints[index + 1] : nil
        let service = routeService
        let departureDate = self.departureDate
        parkingSearchTask = Task { [weak self] in
            do {
                let suggestions = try await service.accessibleParking(near: waypoint, previous: previous, next: next,
                                                                       departureDate: departureDate)
                try Task.checkCancellation()
                self?.parkingSuggestions = suggestions
            } catch {
                if !Task.isCancelled {
                    self?.parkingSearchError = Self.serviceErrorMessage(error)
                }
            }
            if !Task.isCancelled {
                self?.isSearchingParking = false
                self?.parkingSearchTask = nil
            }
        }
    }

    private func cancelParkingSearch() {
        parkingSearchTask?.cancel()
        parkingSearchTask = nil
        parkingSearchWaypoint = nil
        parkingSuggestions = []
        isSearchingParking = false
        parkingSearchError = nil
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

    func moveStop(_ stop: RoadStop, by offset: Int) {
        guard let index = stops.firstIndex(where: { $0.id == stop.id }),
              offset == -1 || offset == 1,
              stops.indices.contains(index + offset) else { return }
        stops.swapAt(index, index + offset)
        manualOrder = true
        waypointsChanged()
    }

    func useProvisionalOrder() {
        guard manualOrder else { return }
        manualOrder = false
        waypointsChanged()
    }

    func fixCurrentOrder() {
        guard hasEndpoints, !isOptimizing else { return }
        manualOrder = true
        suggestion = nil
        publishWaypoints()
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

    func optimizeRoute() {
        guard automaticRouting, hasEndpoints, !stops.isEmpty, !isOptimizing else { return }
        suggestion = nil
        optimizationConnections = []
        scheduleRouting(optimize: true)
    }

    func retryRouting() {
        guard automaticRouting else { return }
        routeService.clearUnavailableLegs()
        scheduleRouting(optimize: lastRoutingWasOptimization)
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
        manualOrder = true
        isProvisional = false
        self.suggestion = nil
        publishWaypoints()
    }

    private func waypointsChanged() {
        let activeIDs = Set(orderedWaypoints.map(\.id))
        details = details.filter { activeIDs.contains($0.key) }
        if !manualOrder, let start, let destination {
            let waypoints = [start] + stops + [destination]
            stops = TripStage.ranges(in: waypoints, anchors: anchors).flatMap { range in
                let end = waypoints[range.upperBound]
                let intermediate = Array(waypoints[(range.lowerBound + 1)..<range.upperBound])
                let ordered = RoadStop.provisionalOrder(start: waypoints[range.lowerBound],
                                                        stops: intermediate, destination: end)
                return end == destination ? ordered : ordered + [end]
            }
        }
        clearRoute()
        publishWaypoints()
        scheduleRouting()
    }

    private func clearRoute() {
        roadPreview = nil
        suggestion = nil
        optimizationConnections = []
        currentConnections = []
        unavailableConnections = []
        currentRequestErrors = []
        currentRequestFailures = []
        cancelParkingSearch()
        isProvisional = true
    }

    private func publishWaypoints() {
        onWaypointsChanged?(TripWaypoints(start: start, stops: stops, destination: destination,
                                          manualOrder: manualOrder, details: details,
                                          defaultStageBudgetMinutes: defaultStageBudgetMinutes))
    }

    private func scheduleRouting(optimize: Bool = false) {
        let previous = routingTask
        previous?.cancel()
        cancelParkingSearch()
        completedRequests = 0
        totalRequests = 0
        routingError = nil
        routingDiagnostic = nil
        currentRequestErrors = []
        currentRequestFailures = []
        guard automaticRouting, let start, let destination else {
            routeStatus = .idle
            return
        }
        lastRoutingWasOptimization = optimize
        let stops = self.stops
        let anchors = self.anchors
        let departureDate = self.departureDate
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
                    start: start, stops: stops, destination: destination, anchors: anchors, optimize: optimize,
                    departureDate: departureDate,
                    onPreview: { [weak self] route in self?.roadPreview = route },
                    onCurrentConnections: { [weak self] current, unavailable, failures in
                        self?.currentConnections = current
                        self?.unavailableConnections = unavailable
                        self?.currentRequestErrors = failures.map { Self.serviceErrorMessage($0.error) }
                        self?.currentRequestFailures = failures
                    },
                    onConnections: { [weak self] connections in self?.optimizationConnections = connections },
                    onProgress: { [weak self] done, total in
                        self?.completedRequests = done
                        self?.totalRequests = total
                    },
                    onStep: { [weak self] step in self?.routeStatus = .running(step) }
                )
                try Task.checkCancellation()
                if optimize {
                    if let preview = self?.roadPreview, preview.duration <= route.duration {
                        self?.isProvisional = false
                    } else {
                        self?.suggestion = route
                    }
                }
                self?.routeStatus = .finished
            } catch {
                if !Task.isCancelled {
                    self?.routingError = Self.serviceErrorMessage(error)
                    if let self {
                        self.routingDiagnostic = self.makeRoutingDiagnostic(error)
                    }
                    self?.routeStatus = .failed
                }
            }
        }
    }

    private func makeRoutingDiagnostic(_ error: Error) -> String {
        var sections = [
            "Berechnung: \(lastRoutingWasOptimization ? "Optimierung" : "aktuelle Reihenfolge")",
            "Reisestart: \(departureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "nicht festgelegt")",
            "Ergebnis: \(Self.serviceErrorMessage(error))",
            "MapKit-Anfragen: \(completedRequests) von \(totalRequests) abgeschlossen.",
            "Erfolgreiche Abschnitte: \(currentConnections.count); ohne Autoroute: \(unavailableConnections.count); Anfragefehler: \(currentRequestFailures.count)."
        ]
        for connection in unavailableConnections {
            var detail = "Keine Autoroute: \(Self.locationDescription(connection.from)) → \(Self.locationDescription(connection.to))"
            if let error = connection.underlyingError {
                detail += "\n\(Self.technicalErrorDescription(error))"
            } else {
                detail += "\nMapKit lieferte keine Route und keine weitere Fehlerursache."
            }
            sections.append(detail)
        }
        for failure in currentRequestFailures {
            sections.append(
                "Anfragefehler: \(Self.locationDescription(failure.from)) → \(Self.locationDescription(failure.to))\n"
                + Self.technicalErrorDescription(failure.error)
            )
        }
        if currentRequestFailures.isEmpty {
            if case MapKitRouteError.missingRoute = error {
                if unavailableConnections.isEmpty {
                    sections.append("Für die fehlende Route liegen keine weiteren technischen Details vor.")
                }
            } else {
                sections.append(Self.technicalErrorDescription(error))
            }
        }
        sections.append("Ein fehlender Abschnitt belegt nicht, dass einer der Punkte nicht anfahrbar ist. MapKit liefert möglicherweise keinen genaueren Grund.")
        return sections.joined(separator: "\n\n")
    }

    private static func locationDescription(_ stop: RoadStop) -> String {
        let latitude = stop.coordinate.latitude.formatted(.number.precision(.fractionLength(6)))
        let longitude = stop.coordinate.longitude.formatted(.number.precision(.fractionLength(6)))
        return "„\(stop.name)“ (\(latitude), \(longitude))"
    }

    private static func technicalErrorDescription(_ error: Error) -> String {
        if case let MapKitRouteError.requestFailed(_, _, underlying) = error {
            return technicalErrorDescription(underlying)
        }
        if case MapKitRouteError.timeout = error {
            return "App-seitiges Zeitlimit von 12 Sekunden: \(error.localizedDescription)"
        }
        var details: [String] = []
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        while let item = current, details.count < 8, visited.insert(ObjectIdentifier(item)).inserted {
            var description = "Domain: \(item.domain), Code: \(item.code)\nBeschreibung: \(item.localizedDescription)"
            if let reason = item.localizedFailureReason, !reason.isEmpty {
                description += "\nGrund: \(reason)"
            }
            if let suggestion = item.localizedRecoverySuggestion, !suggestion.isEmpty {
                description += "\nHinweis: \(suggestion)"
            }
            details.append(description)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return details.joined(separator: "\nVerursacht durch:\n")
    }

    private static func serviceErrorMessage(_ error: Error) -> String {
        if case let MapKitRouteError.requestFailed(from, to, underlying) = error {
            return "Fehler bei der Verbindung „\(from)“ → „\(to)“: \(serviceErrorMessage(underlying))"
        }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if nsError.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain {
            return "Netzwerkfehler: \(error.localizedDescription) Bitte Internetverbindung prüfen und erneut versuchen."
        }
        return error.localizedDescription
    }
}
