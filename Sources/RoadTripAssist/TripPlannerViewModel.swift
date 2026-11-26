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
    @Published private(set) var stageModes: [RoadStop.ID: TravelMode] = [:]
    @Published private(set) var transitLegs: Set<TransitLeg> = []
    @Published private(set) var transitNotice: String?
    @Published private(set) var isRoundTrip = false
    @Published private(set) var roundTripAnchors: [RoadStop.ID: RoadStop.ID] = [:]
    @Published private(set) var lodgingTours: [LodgingTour] = []
    @Published private(set) var tourPlanners: [UUID: TripPlannerViewModel] = [:]
    private var tourSubscriptions: [UUID: AnyCancellable] = [:]
    private var synchronizingTours = false
    private var newStopStageID: RoadStop.ID?
    @Published private(set) var roadPreview: PlannedRoute?
    @Published private(set) var suggestion: PlannedRoute?
    @Published private(set) var optimizationConnections: [RouteConnection] = []
    @Published private(set) var currentConnections: [RouteConnection] = []
    @Published private(set) var unavailableConnections: [UnavailableRouteConnection] = []
    @Published private(set) var currentRequestErrors: [String] = []
    @Published private(set) var currentRequest: RouteRequestActivity?
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

    var completeJourneyTotals: (duration: TimeInterval, distance: Double)? {
        guard routeStatus == .finished, let route = roadPreview,
              route.orderedStops == stops, route.legs.count == max(0, orderedWaypoints.count - 1) else { return nil }
        var duration = route.duration + stages.reduce(0) { $0 + $1.stayMinutes * 60 }
        var distance = route.distance
        for tour in lodgingTours {
            guard let planner = tourPlanners[tour.id], planner.routeStatus == .finished,
                  let route = planner.roadPreview, route.orderedStops == planner.stops,
                  route.legs.count == max(0, planner.orderedWaypoints.count - 1) else { return nil }
            duration += route.duration + planner.stops.reduce(0) {
                $0 + Double(planner.waypointDetails(for: $1).stayMinutes) * 60
            }
            distance += route.distance
        }
        return (duration, distance)
    }

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
        guard !isOvernightLocked(stop) || updated.overnight == previous.overnight else { return }
        var updated = updated
        if !updated.overnight || updated.stageBudgetMinutes != previous.stageBudgetMinutes {
            updated.acceptedBudgetOverrun = nil
        }
        guard previous != updated else { return }
        if stops.contains(stop), previous.overnight != updated.overnight {
            if updated.overnight, let stage = stages.first(where: { $0.waypoints.contains(stop) }) {
                stageModes[stop.id] = mode(for: stage)
            } else if !updated.overnight {
                stageModes.removeValue(forKey: stop.id)
            }
        }
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
        synchronizingTours = true
        for planner in tourPlanners.values { planner.setDefaultStageBudget(minutes) }
        synchronizingTours = false
        publishWaypoints()
    }

    func mode(for stage: TripStage) -> TravelMode {
        stageModes[stage.id] ?? .driving
    }

    func setMode(_ mode: TravelMode, for stage: TripStage) {
        guard stages.contains(where: { $0.id == stage.id }), self.mode(for: stage) != mode else { return }
        stageModes[stage.id] = mode
        clearRoute()
        publishWaypoints()
        scheduleRouting()
    }

    func isTransit(from: RoadStop, to: RoadStop) -> Bool {
        transitLegs.contains(TransitLeg(from: from.id, to: to.id))
    }

    var hasActiveTransit: Bool {
        zip(orderedWaypoints, orderedWaypoints.dropFirst()).contains {
            mode(from: $0, to: $1) == .walking && isTransit(from: $0, to: $1)
        }
    }

    var suggestionRemovesTransit: Bool {
        guard let suggestion, let start, let destination else { return false }
        let waypoints = [start] + suggestion.orderedStops + [destination]
        let pairs = Set(zip(waypoints, waypoints.dropFirst()).map { TransitLeg(from: $0.id, to: $1.id) })
        return !transitLegs.subtracting(pairs).isEmpty
    }

    func mode(from: RoadStop, to: RoadStop) -> TravelMode {
        let stage = stages.first { stage in
            zip(stage.waypoints, stage.waypoints.dropFirst()).contains { $0 == from && $1 == to }
        }
        return stage.map { mode(for: $0) } ?? .driving
    }

    func setTransit(_ enabled: Bool, from: RoadStop, to: RoadStop) {
        guard mode(from: from, to: to) == .walking,
              zip(orderedWaypoints, orderedWaypoints.dropFirst()).contains(where: { $0 == from && $1 == to }) else {
            return
        }
        let leg = TransitLeg(from: from.id, to: to.id)
        if enabled { transitLegs.insert(leg) } else { transitLegs.remove(leg) }
        clearRoute()
        publishWaypoints()
        scheduleRouting()
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
        newStopStageID = nil
    }

    @discardableResult
    func chooseSearchResult(_ result: RoadStop, in field: WaypointField,
                            distinctOccurrence: Bool = false) -> Bool {
        guard searchField == field, searchResults.contains(result) else { return false }
        let selected = distinctOccurrence ? result.newOccurrence() : result
        switch field {
        case .start:
            setStart(selected)
        case .destination:
            setDestination(selected)
        case .newStop:
            guard hasEndpoints else { return false }
            addStop(selected)
        case .stop(let id):
            guard let index = stops.firstIndex(where: { $0.id == id }) else { return false }
            guard roundTripAnchors[id] == nil else { return false }
            if roundTripAnchors.values.contains(id) {
                changeRoundTripAnchor(id, to: selected)
            } else if lodgingTours.contains(where: { $0.anchorID == id }) {
                stops[index] = stops[index].atSamePlace(as: selected)
                synchronizeLodgingTours(anchorID: id, to: selected)
                invalidateChangedAnchor(id)
            } else {
                stops[index] = selected
            }
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
        for planner in tourPlanners.values {
            planner.onWaypointsChanged = nil
            planner.pauseRouting()
        }
        tourSubscriptions = [:]
        tourPlanners = [:]
        start = waypoints.start
        stops = waypoints.stops
        destination = waypoints.destination
        manualOrder = waypoints.manualOrder
        details = waypoints.details
        defaultStageBudgetMinutes = waypoints.defaultStageBudgetMinutes
        stageModes = waypoints.stageModes
        transitLegs = waypoints.transitLegs
        isRoundTrip = waypoints.isRoundTrip
        roundTripAnchors = waypoints.roundTripAnchors
        lodgingTours = waypoints.lodgingTours
        newStopStageID = nil
        transitNotice = nil
        self.departureDate = departureDate
        for tour in lodgingTours { installTourPlanner(for: tour) }
        clearRoute()
        scheduleRouting()
    }

    func setDepartureDate(_ date: Date?) {
        guard departureDate != date else { return }
        departureDate = date
        for planner in tourPlanners.values { planner.setDepartureDate(date) }
        clearRoute()
        scheduleRouting()
    }

    private func installTourPlanner(for tour: LodgingTour) {
        let planner = TripPlannerViewModel(routeService: routeService.independentService(), findPlaces: findPlaces)
        planner.loadWaypoints(tour.waypoints, departureDate: departureDate)
        planner.onWaypointsChanged = { [weak self] updated in
            guard let self, let index = self.lodgingTours.firstIndex(where: { $0.id == tour.id }) else { return }
            self.lodgingTours[index].waypoints = updated
            if !self.synchronizingTours { self.publishWaypoints() }
        }
        tourSubscriptions[tour.id] = planner.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tourPlanners[tour.id] = planner
    }

    func addLodgingTour(at anchor: RoadStop) {
        guard !isRoundTrip, hasEndpoints, orderedWaypoints.contains(anchor), waypointDetails(for: anchor).overnight else { return }
        let start = anchor.newOccurrence()
        let destination = anchor.newOccurrence()
        let tour = LodgingTour(anchorID: anchor.id, waypoints: TripWaypoints(
            start: start, destination: destination, manualOrder: true,
            details: [destination.id: WaypointDetails(overnight: true)],
            defaultStageBudgetMinutes: defaultStageBudgetMinutes, isRoundTrip: true
        ))
        lodgingTours.append(tour)
        installTourPlanner(for: tour)
        publishWaypoints()
    }

    func removeLodgingTour(_ id: UUID) {
        guard let index = lodgingTours.firstIndex(where: { $0.id == id }) else { return }
        tourPlanners[id]?.onWaypointsChanged = nil
        tourPlanners[id]?.pauseRouting()
        tourPlanners[id] = nil
        tourSubscriptions[id] = nil
        lodgingTours.remove(at: index)
        publishWaypoints()
    }

    private func synchronizeLodgingTours(anchorID: RoadStop.ID, to replacement: RoadStop) {
        synchronizingTours = true
        defer { synchronizingTours = false }
        for tour in lodgingTours where tour.anchorID == anchorID {
            tourPlanners[tour.id]?.synchronizeRoundTripEndpoints(to: replacement)
        }
    }

    private func invalidateChangedAnchor(_ id: RoadStop.ID) {
        let count = transitLegs.count
        transitLegs = transitLegs.filter { $0.from != id && $0.to != id }
        var notices: [String] = []
        if transitLegs.count != count {
            notices.append("ÖPNV-Markierungen am geänderten Übernachtungsort wurden entfernt.")
        }
        for stage in stages where stage.waypoints.contains(where: { $0.id == id }) {
            if details[stage.id]?.acceptedBudgetOverrun != nil {
                details[stage.id]?.acceptedBudgetOverrun = nil
                notices.append("Eine Budgetbestätigung wurde wegen des geänderten Übernachtungsorts zurückgesetzt.")
            }
        }
        if !notices.isEmpty { transitNotice = notices.joined(separator: " ") }
        routeService.clearLegs()
    }

    private func synchronizeRoundTripEndpoints(to stop: RoadStop) {
        guard isRoundTrip, let start, let destination else { return }
        self.start = start.atSamePlace(as: stop)
        self.destination = destination.atSamePlace(as: stop)
        let oldCount = transitLegs.count
        transitLegs = transitLegs.filter {
            $0.from != start.id && $0.to != start.id && $0.from != destination.id && $0.to != destination.id
        }
        if transitLegs.count != oldCount {
            transitNotice = "ÖPNV-Markierungen am geänderten Übernachtungsort wurden entfernt."
        }
        if details[destination.id]?.acceptedBudgetOverrun != nil {
            details[destination.id]?.acceptedBudgetOverrun = nil
            transitNotice = [transitNotice, "Die Budgetbestätigung wurde wegen des geänderten Übernachtungsorts zurückgesetzt."]
                .compactMap { $0 }.joined(separator: " ")
        }
        routeService.clearLegs()
        waypointsChanged()
    }

    func setRoundTrip(_ enabled: Bool) {
        guard isRoundTrip != enabled else { return }
        guard !enabled || lodgingTours.isEmpty || hasEndpoints else {
            errorMessage = "Eine Reise mit Unterkunftstouren benötigt Start und Ziel für die Umwandlung."
            return
        }
        if enabled, hasEndpoints {
            var trip = RoadTrip(name: "", notes: "", waypoints: waypointSnapshot)
            do {
                _ = try RoundTripMigration.convertToStandalone(&trip)
                let wasAutomatic = automaticRouting
                loadWaypoints(trip.waypoints, departureDate: departureDate)
                publishWaypoints()
                if wasAutomatic { enableAutomaticRouting() }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        if enabled {
            let oldDestination = destination
            let newDestination = start?.newOccurrence()
            if let oldDestination {
                stops.append(oldDestination)
                if let newDestination {
                    if let mode = stageModes[oldDestination.id] {
                        stageModes[newDestination.id] = mode
                        if !waypointDetails(for: oldDestination).overnight {
                            stageModes.removeValue(forKey: oldDestination.id)
                        }
                    }
                    if !waypointDetails(for: oldDestination).overnight,
                       let budget = details[oldDestination.id]?.stageBudgetMinutes {
                        var oldDetails = waypointDetails(for: oldDestination)
                        oldDetails.stageBudgetMinutes = nil
                        oldDetails.acceptedBudgetOverrun = nil
                        details[oldDestination.id] = oldDetails
                        details[newDestination.id] = WaypointDetails(stageBudgetMinutes: budget)
                    }
                }
            }
            destination = newDestination
        } else {
            let oldDestination = destination
            destination = stops.popLast()
            if let oldDestination, let destination {
                if let mode = stageModes.removeValue(forKey: oldDestination.id),
                   stageModes[destination.id] == nil {
                    stageModes[destination.id] = mode
                }
                if !waypointDetails(for: destination).overnight,
                   let budget = details[oldDestination.id]?.stageBudgetMinutes {
                    var endDetails = details[destination.id] ?? WaypointDetails()
                    if endDetails.stageBudgetMinutes == nil { endDetails.stageBudgetMinutes = budget }
                    details[destination.id] = endDetails
                }
            }
        }
        isRoundTrip = enabled
        manualOrder = true
        waypointsChanged()
    }

    func setStart(_ stop: RoadStop) {
        guard canUseAsStart(stop) else { return }
        if let old = start, lodgingTours.contains(where: { $0.anchorID == old.id }) {
            start = old.atSamePlace(as: stop)
            synchronizeLodgingTours(anchorID: old.id, to: stop)
            invalidateChangedAnchor(old.id)
        } else {
            start = stop
        }
        if isRoundTrip {
            let oldDestination = destination
            let newDestination = oldDestination?.atSamePlace(as: stop) ?? stop.newOccurrence()
            if let oldDestination {
                let oldCount = transitLegs.count
                transitLegs = transitLegs.filter { $0.from != oldDestination.id && $0.to != oldDestination.id }
                if transitLegs.count != oldCount {
                    transitNotice = "ÖPNV-Markierungen am geänderten Startpunkt wurden entfernt."
                }
                routeService.clearLegs()
            } else if let last = stops.last {
                if let mode = stageModes[last.id] {
                    stageModes[newDestination.id] = mode
                    if !waypointDetails(for: last).overnight { stageModes.removeValue(forKey: last.id) }
                }
                if !waypointDetails(for: last).overnight,
                   let budget = details[last.id]?.stageBudgetMinutes {
                    var lastDetails = waypointDetails(for: last)
                    lastDetails.stageBudgetMinutes = nil
                    lastDetails.acceptedBudgetOverrun = nil
                    details[last.id] = lastDetails
                    details[newDestination.id] = WaypointDetails(stageBudgetMinutes: budget)
                }
            }
            destination = newDestination
        }
        waypointsChanged()
    }

    func addStop(_ stop: RoadStop) {
        guard hasEndpoints, !orderedWaypoints.contains(stop) else { return }
        if let stageID = newStopStageID, let index = stops.firstIndex(where: { $0.id == stageID }) {
            stops.insert(stop, at: index)
        } else {
            stops.append(stop)
        }
        newStopStageID = nil
        waypointsChanged()
    }

    func beginAddingStop(to stage: TripStage) {
        beginSearch(in: .newStop)
        newStopStageID = stage.id
    }

    func isRoundTripStage(_ stage: TripStage) -> Bool {
        roundTripAnchors[stage.id] != nil || (isRoundTrip && stages.count == 1 && stage.end == destination)
    }

    func isProtectedRoundTripAnchor(_ stop: RoadStop) -> Bool {
        roundTripAnchors[stop.id] != nil || roundTripAnchors.values.contains(stop.id)
            || lodgingTours.contains { $0.anchorID == stop.id }
    }

    private func changeRoundTripAnchor(_ id: RoadStop.ID, to replacement: RoadStop) {
        let changedIDs = Set(roundTripAnchors.filter { $0.value == id }.map(\.key)).union([id])
        stops = stops.map { changedIDs.contains($0.id) ? $0.atSamePlace(as: replacement) : $0 }
        if let destination, changedIDs.contains(destination.id) {
            self.destination = destination.atSamePlace(as: replacement)
        }
        let oldCount = transitLegs.count
        transitLegs = transitLegs.filter { !changedIDs.contains($0.from) && !changedIDs.contains($0.to) }
        if oldCount != transitLegs.count {
            transitNotice = "ÖPNV-Markierungen am geänderten Übernachtungsort wurden entfernt."
        }
        routeService.clearLegs()
    }

    func isOvernightLocked(_ stop: RoadStop) -> Bool {
        isProtectedRoundTripAnchor(stop) || (isRoundTrip && stop != start && stop != destination)
            || stages.contains { stage in
                isRoundTripStage(stage) && stage.waypoints.dropFirst().dropLast().contains(stop)
            }
    }

    func hasMapPlace(_ stop: RoadStop) -> Bool {
        orderedWaypoints.contains { $0.matchesMapPlace(stop) }
    }

    func addMapPOI(_ stop: RoadStop, asOvernight: Bool = false, stageID: RoadStop.ID? = nil) {
        guard hasEndpoints, !hasMapPlace(stop) else { return }
        if asOvernight && isRoundTrip { return }
        if asOvernight, let stageID, let stage = stages.first(where: { $0.id == stageID }),
           isRoundTripStage(stage) { return }
        let waypoints = orderedWaypoints
        let insertionIndex: Int
        if let stageID, let stage = stages.first(where: { $0.id == stageID }),
           let stageStart = waypoints.firstIndex(of: stage.waypoints[0]) {
            let gap = RoadStop.bestInsertionIndex(for: stop, along: stage.waypoints)
            insertionIndex = stageStart + gap
        } else if asOvernight || manualOrder || !anchors.isEmpty {
            let allowed = stages.filter { !asOvernight || !isRoundTripStage($0) }.flatMap { stage -> [Int] in
                guard let start = waypoints.firstIndex(of: stage.waypoints[0]) else { return [] }
                return Array(start..<(start + stage.waypoints.count - 1))
            }
            guard let gap = allowed.min(by: { a, b in
                func cost(_ i: Int) -> Double {
                    waypoints[i].distance(to: stop) + stop.distance(to: waypoints[i + 1])
                        - waypoints[i].distance(to: waypoints[i + 1])
                }
                return cost(a) < cost(b)
            }) else { return }
            insertionIndex = gap
        } else {
            insertionIndex = stops.count
        }
        if asOvernight {
            let from = waypoints[insertionIndex]
            let to = waypoints[insertionIndex + 1]
            stageModes[stop.id] = mode(from: from, to: to)
        }
        stops.insert(stop, at: insertionIndex)
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
        let previous = index > 0 && mode(from: waypoints[index - 1], to: waypoint) == .driving
            ? waypoints[index - 1] : nil
        let next = index + 1 < waypoints.count && mode(from: waypoint, to: waypoints[index + 1]) == .driving
            ? waypoints[index + 1] : nil
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
        guard !isRoundTrip, destination.map({ roundTripAnchors[$0.id] == nil
            && !roundTripAnchors.values.contains($0.id) }) ?? true else { return }
        guard canUseAsDestination(stop) else { return }
        if let old = destination, lodgingTours.contains(where: { $0.anchorID == old.id }) {
            destination = old.atSamePlace(as: stop)
            synchronizeLodgingTours(anchorID: old.id, to: stop)
            invalidateChangedAnchor(old.id)
        } else {
            destination = stop
        }
        waypointsChanged()
    }

    func removeStop(_ stop: RoadStop) {
        guard !isProtectedRoundTripAnchor(stop) else { return }
        if searchField == .stop(stop.id) { cancelSearch() }
        stops.removeAll { $0.id == stop.id }
        waypointsChanged()
    }

    func moveStop(_ stop: RoadStop, by offset: Int) {
        guard let index = stops.firstIndex(where: { $0.id == stop.id }),
              offset == -1 || offset == 1,
              stops.indices.contains(index + offset),
              !isProtectedRoundTripAnchor(stop),
              !isProtectedRoundTripAnchor(stops[index + offset]) else { return }
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
        currentRequest = nil
        if isOptimizing || routeStatus == .failed { routeStatus = .paused }
    }

    func acceptSuggestion() {
        guard let suggestion else { return }
        stops = suggestion.orderedStops
        discardDisconnectedTransitLegs()
        roadPreview = suggestion
        manualOrder = true
        isProvisional = false
        self.suggestion = nil
        publishWaypoints()
    }

    private func waypointsChanged() {
        let activeIDs = Set(orderedWaypoints.map(\.id))
        details = details.filter { activeIDs.contains($0.key) }
        stageModes = stageModes.filter { activeIDs.contains($0.key) }
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
        discardDisconnectedTransitLegs()
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

    private var waypointSnapshot: TripWaypoints {
        TripWaypoints(start: start, stops: stops, destination: destination,
                      manualOrder: manualOrder, details: details,
                      defaultStageBudgetMinutes: defaultStageBudgetMinutes,
                      stageModes: stageModes, transitLegs: transitLegs,
                      isRoundTrip: isRoundTrip, roundTripAnchors: roundTripAnchors,
                      lodgingTours: lodgingTours)
    }

    private func publishWaypoints() {
        onWaypointsChanged?(waypointSnapshot)
    }

    private func discardDisconnectedTransitLegs() {
        let pairs = Set(zip(orderedWaypoints, orderedWaypoints.dropFirst()).map {
            TransitLeg(from: $0.id, to: $1.id)
        })
        let removed = transitLegs.subtracting(pairs)
        guard !removed.isEmpty else { return }
        transitLegs.subtract(removed)
        transitNotice = "\(removed.count) ÖPNV-Markierung(en) wurden entfernt, da die Punkte nicht mehr benachbart sind."
    }

    private func scheduleRouting(optimize: Bool = false) {
        let previous = routingTask
        previous?.cancel()
        cancelParkingSearch()
        completedRequests = 0
        totalRequests = 0
        routingError = nil
        routingDiagnostic = nil
        currentRequest = nil
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
        let stageModes = self.stageModes
        let transitLegs = self.transitLegs
        var roundTripEndIDs = Set(roundTripAnchors.keys)
        if isRoundTrip { roundTripEndIDs.insert(destination.id) }
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
                    departureDate: departureDate, stageModes: stageModes, transitLegs: transitLegs,
                    roundTripEndIDs: roundTripEndIDs,
                    onPreview: { [weak self] route in self?.roadPreview = route },
                    onCurrentConnections: { [weak self] current, unavailable, failures in
                        self?.currentConnections = current
                        self?.unavailableConnections = unavailable
                        self?.currentRequestErrors = failures.map { Self.serviceErrorMessage($0.error) }
                        self?.currentRequestFailures = failures
                    },
                    onRequest: { [weak self] request in
                        guard !Task.isCancelled else { return }
                        self?.currentRequest = request
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

    func liveRoutingDiagnostic(at now: Date = Date()) -> String {
        makeRoutingDiagnostic(nil, at: now)
    }

    private func makeRoutingDiagnostic(_ error: Error?, at now: Date = Date()) -> String {
        var sections = [
            "Berechnung: \(lastRoutingWasOptimization ? "Optimierung" : "aktuelle Reihenfolge")",
            "Reisestart: \(departureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "nicht festgelegt")",
            "MapKit-Anfragen: \(completedRequests) von \(totalRequests) abgeschlossen.",
            "Erfolgreiche Abschnitte: \(currentConnections.count); ohne Verbindung: \(unavailableConnections.count); Anfragefehler: \(currentRequestFailures.count)."
        ]
        if let error {
            sections.insert("Ergebnis: \(Self.serviceErrorMessage(error))", at: 2)
        } else if routeStatus == .paused {
            sections.insert("Status: Berechnung pausiert.", at: 2)
        } else {
            sections.insert("Status: Berechnung läuft; noch nicht abgeschlossene Anfragen haben möglicherweise noch keine Fehlermeldung geliefert.", at: 2)
        }
        if let currentRequest {
            let mode: String
            switch currentRequest.mode {
            case .driving: mode = "Fahren"
            case .walking: mode = "Zu Fuß"
            case .transit: mode = "ÖPNV"
            }
            let elapsed = max(0, Int(now.timeIntervalSince(currentRequest.startedAt)))
            sections.append("Aktuelle Anfrage: \(Self.locationDescription(currentRequest.from)) → \(Self.locationDescription(currentRequest.to))\nVerkehrsmittel: \(mode); läuft seit \(elapsed) Sekunden.")
        }
        for connection in unavailableConnections {
            var detail = "Keine Verbindung: \(Self.locationDescription(connection.from)) → \(Self.locationDescription(connection.to))"
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
        if currentRequestFailures.isEmpty, let error {
            if case MapKitRouteError.missingRoute = error {
                if unavailableConnections.isEmpty {
                    sections.append("Für die fehlende Route liegen keine weiteren technischen Details vor.")
                }
            } else {
                sections.append(Self.technicalErrorDescription(error))
            }
        }
        sections.append("Ein fehlender Abschnitt belegt nicht, dass einer der Punkte nicht erreichbar ist. MapKit liefert möglicherweise keinen genaueren Grund.")
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
