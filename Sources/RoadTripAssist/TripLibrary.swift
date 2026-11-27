import Combine
import CoreLocation
import Foundation

private func performPhotoIO<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let result = await Task.detached(priority: priority) {
        Result { try operation() }
    }.value
    return try result.get()
}

enum VisitStatus: String, Codable, CaseIterable {
    case pending, visited, skipped

    var title: String {
        switch self {
        case .pending: "Offen"
        case .visited: "Besucht"
        case .skipped: "Übersprungen"
        }
    }
}

enum TravelMode: String, Codable, CaseIterable {
    case driving, walking

    var title: String {
        switch self {
        case .driving: "Fahren"
        case .walking: "Zu Fuß"
        }
    }
}

struct TransitLeg: Codable, Hashable {
    let from: RoadStop.ID
    let to: RoadStop.ID
}

enum WaypointCategory: String, Codable, CaseIterable {
    case sightseeing, viewpoint, pause, hiking, navigation, photo

    var title: String {
        switch self {
        case .sightseeing: "Sight Seeing"
        case .viewpoint: "View Point"
        case .pause: "Pause"
        case .hiking: "Wanderung"
        case .navigation: "Nav-Hilfspunkt"
        case .photo: "Foto"
        }
    }

    var systemImage: String {
        switch self {
        case .sightseeing: "binoculars.fill"
        case .viewpoint: "mountain.2.fill"
        case .pause: "cup.and.saucer.fill"
        case .hiking: "figure.hiking"
        case .navigation: "location.fill"
        case .photo: "photo.fill"
        }
    }
}

struct WaypointDetails: Codable, Equatable {
    var stayMinutes = 0
    var notes = ""
    var rating = 0
    var status = VisitStatus.pending
    var overnight = false
    var stageBudgetMinutes: Int?
    var acceptedBudgetOverrun: StageBudgetOverrun?
    var category: WaypointCategory?

    var systemImage: String {
        overnight ? "bed.double.fill" : category?.systemImage ?? "mappin"
    }
}

struct StageBudgetOverrun: Codable, Equatable {
    let waypointIDs: [RoadStop.ID]
    let budgetMinutes: Int
    let arrivalMinutes: Int

    func covers(_ current: Self) -> Bool {
        waypointIDs == current.waypointIDs && budgetMinutes == current.budgetMinutes &&
            arrivalMinutes >= current.arrivalMinutes
    }
}

struct TripStage: Identifiable {
    struct BudgetPlaceholder {
        let coordinate: CLLocationCoordinate2D
        let afterWaypointID: RoadStop.ID
    }

    let waypoints: [RoadStop]
    let legs: [RouteLeg]?
    let waypointStayMinutes: [Int]
    let budgetMinutes: Int?
    let endsWithOvernight: Bool
    var acceptedBudgetOverrun: StageBudgetOverrun? = nil

    var id: RoadStop.ID { end.id }
    var end: RoadStop { waypoints[waypoints.count - 1] }
    var stayMinutes: Double { waypointStayMinutes.reduce(0) { $0 + Double($1) } }
    var driveDuration: TimeInterval? { legs.map { $0.reduce(0) { $0 + $1.duration } } }
    var totalDuration: TimeInterval? { driveDuration.map { $0 + stayMinutes * 60 } }
    var coordinates: [CLLocationCoordinate2D] { legs?.flatMap(\.coordinates) ?? [] }

    var budgetOverrun: StageBudgetOverrun? {
        guard endsWithOvernight, let budgetMinutes, budgetMinutes > 0, let driveDuration else { return nil }
        let staysBeforeArrival = waypointStayMinutes.dropLast().reduce(0.0) { $0 + Double($1) }
        guard let arrivalMinutes = Int(exactly: ceil(driveDuration / 60 + staysBeforeArrival)),
              arrivalMinutes > budgetMinutes else { return nil }
        return StageBudgetOverrun(waypointIDs: waypoints.map(\.id), budgetMinutes: budgetMinutes,
                                  arrivalMinutes: arrivalMinutes)
    }

    var isBudgetOverrunAccepted: Bool {
        guard let budgetOverrun else { return false }
        return acceptedBudgetOverrun?.covers(budgetOverrun) == true
    }

    var budgetPlaceholder: BudgetPlaceholder? {
        guard let budgetMinutes, budgetMinutes > 0, let legs,
              let totalDuration, totalDuration > Double(budgetMinutes) * 60,
              !isBudgetOverrunAccepted else { return nil }
        var remaining = Double(budgetMinutes) * 60
        for (index, waypoint) in waypoints.enumerated() {
            let stay = Double(waypointStayMinutes[index]) * 60
            if remaining <= stay {
                guard waypoint != end || !endsWithOvernight else { return nil }
                return BudgetPlaceholder(coordinate: waypoint.coordinate, afterWaypointID: waypoint.id)
            }
            remaining -= stay
            guard index < legs.count else { break }
            let leg = legs[index]
            if remaining < leg.duration {
                // MapKit reports a duration for the whole leg, not for individual polyline segments.
                return leg.coordinate(atFraction: remaining / leg.duration).map {
                    BudgetPlaceholder(coordinate: $0, afterWaypointID: waypoint.id)
                }
            }
            remaining -= leg.duration
        }
        return nil
    }

    static func ranges(in waypoints: [RoadStop], anchors: Set<RoadStop.ID>) -> [ClosedRange<Int>] {
        guard waypoints.count >= 2 else { return [] }
        var start = 0
        var ranges: [ClosedRange<Int>] = []
        for end in waypoints.indices.dropFirst() where end == waypoints.count - 1 ||
            anchors.contains(waypoints[end].id) {
            ranges.append(start...end)
            start = end
        }
        return ranges
    }
}

struct TripWaypoints: Codable {
    var start: RoadStop?
    var stops: [RoadStop] = []
    var destination: RoadStop?
    var manualOrder = false
    var details: [RoadStop.ID: WaypointDetails] = [:]
    var defaultStageBudgetMinutes: Int?
    var stageModes: [RoadStop.ID: TravelMode]
    var transitLegs: Set<TransitLeg>
    var isRoundTrip: Bool
    var roundTripAnchors: [RoadStop.ID: RoadStop.ID]
    var lodgingTours: [LodgingTour]

    init(start: RoadStop? = nil, stops: [RoadStop] = [], destination: RoadStop? = nil,
         manualOrder: Bool = false, details: [RoadStop.ID: WaypointDetails] = [:],
         defaultStageBudgetMinutes: Int? = nil, stageModes: [RoadStop.ID: TravelMode] = [:],
         transitLegs: Set<TransitLeg> = [], isRoundTrip: Bool = false,
         roundTripAnchors: [RoadStop.ID: RoadStop.ID] = [:], lodgingTours: [LodgingTour] = []) {
        self.start = start
        self.stops = stops
        self.destination = destination
        self.manualOrder = manualOrder
        self.details = details
        self.defaultStageBudgetMinutes = defaultStageBudgetMinutes
        self.stageModes = stageModes
        self.transitLegs = transitLegs
        self.isRoundTrip = isRoundTrip
        self.roundTripAnchors = roundTripAnchors
        self.lodgingTours = lodgingTours
    }

    private enum CodingKeys: String, CodingKey {
        case start, stops, destination, manualOrder, details, defaultStageBudgetMinutes, stageModes, transitLegs
        case isRoundTrip, roundTripAnchors, lodgingTours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(RoadStop.self, forKey: .start)
        stops = try container.decode([RoadStop].self, forKey: .stops)
        destination = try container.decodeIfPresent(RoadStop.self, forKey: .destination)
        manualOrder = try container.decodeIfPresent(Bool.self, forKey: .manualOrder) ?? false
        details = try container.decodeIfPresent([RoadStop.ID: WaypointDetails].self, forKey: .details) ?? [:]
        defaultStageBudgetMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultStageBudgetMinutes)
        stageModes = try container.decodeIfPresent([RoadStop.ID: TravelMode].self, forKey: .stageModes) ?? [:]
        transitLegs = try container.decodeIfPresent(Set<TransitLeg>.self, forKey: .transitLegs) ?? []
        isRoundTrip = try container.decodeIfPresent(Bool.self, forKey: .isRoundTrip) ?? false
        roundTripAnchors = try container.decodeIfPresent([RoadStop.ID: RoadStop.ID].self, forKey: .roundTripAnchors) ?? [:]
        lodgingTours = try container.decodeIfPresent([LodgingTour].self, forKey: .lodgingTours) ?? []
    }
}

struct LodgingTour: Identifiable, Codable {
    let id: UUID
    let anchorID: RoadStop.ID
    var waypoints: TripWaypoints

    init(id: UUID = UUID(), anchorID: RoadStop.ID, waypoints: TripWaypoints) {
        self.id = id
        self.anchorID = anchorID
        self.waypoints = waypoints
    }
}

struct RoadTrip: Identifiable, Codable {
    var id = UUID()
    var name: String
    var notes: String
    var waypoints = TripWaypoints()
    var photos: [TripPhoto] = []
    var departureDate: Date?
    var migrationNotices: [String] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, notes, waypoints, photos, departureDate, migrationNotices
    }

    init(id: UUID = UUID(), name: String, notes: String, waypoints: TripWaypoints = TripWaypoints(),
         photos: [TripPhoto] = [], departureDate: Date? = nil, migrationNotices: [String] = []) {
        self.id = id
        self.name = name
        self.notes = notes
        self.waypoints = waypoints
        self.photos = photos
        self.departureDate = departureDate
        self.migrationNotices = migrationNotices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decode(String.self, forKey: .notes)
        waypoints = try container.decode(TripWaypoints.self, forKey: .waypoints)
        photos = try container.decodeIfPresent([TripPhoto].self, forKey: .photos) ?? []
        departureDate = try container.decodeIfPresent(Date.self, forKey: .departureDate)
        migrationNotices = try container.decodeIfPresent([String].self, forKey: .migrationNotices) ?? []
    }
}

enum RoundTripMigrationError: LocalizedError {
    case invalidWaypoints
    case budgetOverflow

    var errorDescription: String? {
        switch self {
        case .invalidWaypoints:
            "Die Rundtour enthält uneindeutige Wegpunkte und kann nicht automatisch zusammengeführt werden."
        case .budgetOverflow:
            "Die Etappenbudgets der Rundtour sind zu groß, um sie zusammenzuführen."
        }
    }
}

private struct TripMigrationFailure: LocalizedError {
    let tripName: String
    let reason: String

    var errorDescription: String? {
        "Die Reise „\(tripName)“ konnte nicht sicher umgestellt werden: \(reason) Die gespeicherten Daten wurden nicht verändert."
    }
}

enum RoundTripMigration {
    private static func unresolvedPhotoCount(in trip: RoadTrip) -> Int {
        let contexts = [trip.waypoints] + trip.waypoints.lodgingTours.map(\.waypoints)
        var waypointIDs: Set<RoadStop.ID> = []
        var stageIDs: Set<RoadStop.ID> = []
        var pairs: Set<TransitLeg> = []
        for context in contexts {
            let points = [context.start].compactMap { $0 } + context.stops + [context.destination].compactMap { $0 }
            waypointIDs.formUnion(points.map(\.id))
            pairs.formUnion(zip(points, points.dropFirst()).map { TransitLeg(from: $0.id, to: $1.id) })
            let anchors = Set(context.stops.filter { context.details[$0.id]?.overnight == true }.map(\.id))
            stageIDs.formUnion(TripStage.ranges(in: points, anchors: anchors).map { points[$0.upperBound].id })
        }
        return trip.photos.filter { photo in
            switch photo.assignment?.target {
            case .waypoint(let id): !waypointIDs.contains(id)
            case .stage(let id): !stageIDs.contains(id)
            case .routeSegment(let from, let to): !pairs.contains(TransitLeg(from: from, to: to))
            case nil: false
            }
        }.count
    }

    private static func appendPhotoWarning(to notice: inout String, trip: RoadTrip) {
        let count = unresolvedPhotoCount(in: trip)
        if count > 0 {
            notice += " \(count) Fotozuordnung(en) konnten nicht eindeutig zugeordnet werden und sollten überprüft werden; die bisherigen Angaben bleiben erhalten."
        }
    }

    static func convertToStandalone(_ trip: inout RoadTrip) throws -> String {
        var merged = trip.waypoints
        guard !merged.isRoundTrip, let start = merged.start, let destination = merged.destination else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        try validate(merged)
        let main = [start] + merged.stops + [destination]
        var combined: [RoadStop] = []
        var pairMappings: [TransitLeg: TransitLeg] = [:]
        var waypointMappings: [RoadStop.ID: RoadStop.ID] = [:]
        for index in main.indices {
            let point = main[index]
            if index > 0 {
                let previous = main[index - 1]
                let previousOccurrence = combined[combined.count - 1]
                if previous.id != previousOccurrence.id {
                    pairMappings[TransitLeg(from: previous.id, to: point.id)] =
                        TransitLeg(from: previousOccurrence.id, to: point.id)
                }
            }
            combined.append(point)
            for tour in merged.lodgingTours where tour.anchorID == point.id {
                guard let tourStart = tour.waypoints.start, let tourEnd = tour.waypoints.destination else {
                    throw RoundTripMigrationError.invalidWaypoints
                }
                guard tour.waypoints.details[tourStart.id] == nil
                        || tour.waypoints.details[tourStart.id] == WaypointDetails() else {
                    throw RoundTripMigrationError.invalidWaypoints
                }
                waypointMappings[tourStart.id] = combined[combined.count - 1].id
                let first = tour.waypoints.stops.first ?? tourEnd
                pairMappings[TransitLeg(from: tourStart.id, to: first.id)] =
                    TransitLeg(from: combined[combined.count - 1].id, to: first.id)
                combined.append(contentsOf: tour.waypoints.stops)
                combined.append(tourEnd)
                for (id, details) in tour.waypoints.details where id != tourStart.id { merged.details[id] = details }
                for (id, mode) in tour.waypoints.stageModes { merged.stageModes[id] = mode }
                merged.transitLegs.formUnion(tour.waypoints.transitLegs)
                var endDetails = merged.details[tourEnd.id] ?? WaypointDetails()
                endDetails.overnight = true
                merged.details[tourEnd.id] = endDetails
            }
        }
        var destinationDetails = merged.details[destination.id] ?? WaypointDetails()
        destinationDetails.overnight = true
        merged.details[destination.id] = destinationDetails
        merged.transitLegs = Set(merged.transitLegs.map { pairMappings[$0] ?? $0 })
        let newEnd = start.newOccurrence()
        merged.stops = Array(combined.dropFirst())
        merged.destination = newEnd
        merged.isRoundTrip = true
        merged.manualOrder = true
        merged.lodgingTours = []
        var photos = trip.photos
        for index in photos.indices {
            switch photos[index].assignment?.target {
            case .waypoint(let id):
                if let mapped = waypointMappings[id] { photos[index].assignment?.target = .waypoint(mapped) }
            case .routeSegment(let from, let to):
                if let mapped = pairMappings[TransitLeg(from: from, to: to)] {
                    photos[index].assignment?.target = .routeSegment(from: mapped.from, to: mapped.to)
                }
            default:
                break
            }
        }
        var converted = trip
        converted.waypoints = merged
        converted.photos = photos
        let notice = try mergeStandalone(&converted)
        try validate(converted.waypoints)
        trip = converted
        return notice ?? "Die Reise wurde zu einer Rundtour zusammengeführt."
    }

    static func validate(_ waypoints: TripWaypoints) throws {
        guard !waypoints.isRoundTrip || (waypoints.lodgingTours.isEmpty && waypoints.roundTripAnchors.isEmpty
            && waypoints.stops.allSatisfy({ waypoints.details[$0.id]?.overnight != true })) else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        guard waypoints.lodgingTours.isEmpty || (waypoints.start != nil && waypoints.destination != nil) else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        let main = [waypoints.start].compactMap { $0 } + waypoints.stops
            + [waypoints.destination].compactMap { $0 }
        var ids = Set(main.map(\.id))
        guard ids.count == main.count,
              Set(waypoints.lodgingTours.map(\.id)).count == waypoints.lodgingTours.count else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        for tour in waypoints.lodgingTours {
            guard let anchor = main.first(where: { $0.id == tour.anchorID }),
                  waypoints.details[anchor.id]?.overnight == true,
                  tour.waypoints.isRoundTrip, tour.waypoints.lodgingTours.isEmpty,
                  tour.waypoints.roundTripAnchors.isEmpty,
                  let start = tour.waypoints.start, let end = tour.waypoints.destination,
                  start.distance(to: anchor) < 1, end.distance(to: anchor) < 1,
                  start.name == anchor.name, end.name == anchor.name,
                  start.subtitle == anchor.subtitle, end.subtitle == anchor.subtitle,
                  tour.waypoints.stops.allSatisfy({ tour.waypoints.details[$0.id]?.overnight != true }) else {
                throw RoundTripMigrationError.invalidWaypoints
            }
            for point in [start] + tour.waypoints.stops + [end] {
                guard ids.insert(point.id).inserted else { throw RoundTripMigrationError.invalidWaypoints }
            }
        }
    }

    static func extractLodgingTours(_ trip: inout RoadTrip) throws -> String? {
        var waypoints = trip.waypoints
        guard !waypoints.isRoundTrip, !waypoints.roundTripAnchors.isEmpty else { return nil }
        guard waypoints.lodgingTours.isEmpty, let start = waypoints.start,
              let destination = waypoints.destination else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        let points = [start] + waypoints.stops + [destination]
        guard Set(points.map(\.id)).count == points.count else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        let anchors = Set(waypoints.stops.filter { waypoints.details[$0.id]?.overnight == true }.map(\.id))
        let ranges = TripStage.ranges(in: points, anchors: anchors)
        let tourRanges = ranges.filter { waypoints.roundTripAnchors[points[$0.upperBound].id] != nil }
        guard tourRanges.count == waypoints.roundTripAnchors.count else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        var tours: [LodgingTour] = []
        var removedIndices: Set<Int> = []
        var pairMappings: [TransitLeg: TransitLeg] = [:]
        var resetOverruns = false
        for range in tourRanges {
            let oldStart = points[range.lowerBound]
            let end = points[range.upperBound]
            guard let rootID = waypoints.roundTripAnchors[end.id],
                  let rootIndex = points.firstIndex(where: { $0.id == rootID }),
                  rootIndex <= range.lowerBound,
                  (oldStart.id == rootID || waypoints.roundTripAnchors[oldStart.id] == rootID),
                  waypoints.details[rootID]?.overnight == true,
                  points[rootIndex].distance(to: end) < 1,
                  points[rootIndex].distance(to: oldStart) < 1,
                  points[rootIndex].name == end.name, points[rootIndex].name == oldStart.name,
                  points[rootIndex].subtitle == end.subtitle, points[rootIndex].subtitle == oldStart.subtitle else {
                throw RoundTripMigrationError.invalidWaypoints
            }
            let newStart = oldStart.newOccurrence()
            let tourStops = Array(points[(range.lowerBound + 1)..<range.upperBound])
            let tourIDs = Set((tourStops + [end]).map(\.id))
            var tourDetails = waypoints.details.filter { tourIDs.contains($0.key) }
            if tourDetails[end.id]?.acceptedBudgetOverrun != nil {
                resetOverruns = true
                tourDetails[end.id]?.acceptedBudgetOverrun = nil
            }
            let oldFirstPair = TransitLeg(from: oldStart.id, to: points[range.lowerBound + 1].id)
            let newFirstPair = TransitLeg(from: newStart.id, to: oldFirstPair.to)
            pairMappings[oldFirstPair] = newFirstPair
            let localPairs = Set(zip(Array(points[range]), Array(points[range].dropFirst())).map {
                TransitLeg(from: $0.id, to: $1.id)
            })
            var tourTransit = waypoints.transitLegs.intersection(localPairs)
            if tourTransit.remove(oldFirstPair) != nil { tourTransit.insert(newFirstPair) }
            let tour = TripWaypoints(start: newStart, stops: tourStops, destination: end,
                                     manualOrder: true, details: tourDetails,
                                     defaultStageBudgetMinutes: waypoints.defaultStageBudgetMinutes,
                                     stageModes: waypoints.stageModes.filter { tourIDs.contains($0.key) },
                                     transitLegs: tourTransit, isRoundTrip: true)
            tours.append(LodgingTour(anchorID: rootID, waypoints: tour))
            removedIndices.formUnion((range.lowerBound + 1)...range.upperBound)
        }
        let mainIndices = points.indices.filter { !removedIndices.contains($0) }
        guard mainIndices.count >= 2, let lastIndex = mainIndices.last, mainIndices.first == 0 else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        for (previous, next) in zip(mainIndices, mainIndices.dropFirst()) where next > previous + 1 {
            let oldPair = TransitLeg(from: points[next - 1].id, to: points[next].id)
            pairMappings[oldPair] = TransitLeg(from: points[previous].id, to: points[next].id)
        }
        let mainPoints = mainIndices.map { points[$0] }
        guard lastIndex == points.count - 1 || waypoints.roundTripAnchors[destination.id] == mainPoints.last?.id else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        waypoints.destination = mainPoints.last
        waypoints.stops = Array(mainPoints.dropFirst().dropLast())
        let removedIDs = Set(removedIndices.map { points[$0].id })
        waypoints.details = waypoints.details.filter { !removedIDs.contains($0.key) }
        waypoints.stageModes = waypoints.stageModes.filter { !removedIDs.contains($0.key) }
        let mainAnchors = Set(waypoints.stops.filter { waypoints.details[$0.id]?.overnight == true }.map(\.id))
        for range in TripStage.ranges(in: mainPoints, anchors: mainAnchors) {
            let endID = mainPoints[range.upperBound].id
            guard let oldRange = ranges.first(where: { points[$0.upperBound].id == endID }),
                  points[oldRange.lowerBound].id != mainPoints[range.lowerBound].id,
                  waypoints.details[endID]?.acceptedBudgetOverrun != nil else { continue }
            waypoints.details[endID]?.acceptedBudgetOverrun = nil
            resetOverruns = true
        }
        let mainPairs = Set(zip(mainPoints, mainPoints.dropFirst()).map { TransitLeg(from: $0.id, to: $1.id) })
        let previousTransit = waypoints.transitLegs
        waypoints.transitLegs = Set(previousTransit.compactMap { old in
            let mapped = pairMappings[old] ?? old
            return mainPairs.contains(mapped) ? mapped : nil
        })
        waypoints.roundTripAnchors = [:]
        waypoints.lodgingTours = tours

        var photos = trip.photos
        for index in photos.indices {
            guard case .routeSegment(let from, let to)? = photos[index].assignment?.target,
                  let mapped = pairMappings[TransitLeg(from: from, to: to)] else { continue }
            photos[index].assignment?.target = .routeSegment(from: mapped.from, to: mapped.to)
        }
        trip.waypoints = waypoints
        trip.photos = photos
        var notice = "\(tours.count) Unterkunftstour(en) wurden von der Hauptreise getrennt."
        let migratedTransitCount = waypoints.transitLegs.count + tours.reduce(0) { $0 + $1.waypoints.transitLegs.count }
        if migratedTransitCount < previousTransit.count {
            notice += " \(previousTransit.count - migratedTransitCount) nicht mehr benachbarte ÖPNV-Markierung(en) wurden entfernt."
        }
        if resetOverruns {
            notice += " Frühere Bestätigungen von Budgetüberschreitungen wurden zurückgesetzt."
        }
        appendPhotoWarning(to: &notice, trip: trip)
        return notice
    }

    /// Returns the migration notice, or nil if no merge was necessary.
    static func mergeStandalone(_ trip: inout RoadTrip) throws -> String? {
        var waypoints = trip.waypoints
        guard waypoints.isRoundTrip else { return nil }
        guard let start = waypoints.start, let destination = waypoints.destination else {
            if waypoints.roundTripAnchors.isEmpty { return nil }
            throw RoundTripMigrationError.invalidWaypoints
        }
        let points = [start] + waypoints.stops + [destination]
        guard Set(points.map(\.id)).count == points.count,
              start.distance(to: destination) < 1,
              waypoints.lodgingTours.isEmpty else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        let anchors = Set(waypoints.stops.filter { waypoints.details[$0.id]?.overnight == true }.map(\.id))
        let ranges = TripStage.ranges(in: points, anchors: anchors)
        guard ranges.count > 1 || !waypoints.roundTripAnchors.isEmpty else { return nil }
        let ends = ranges.map { points[$0.upperBound].id }
        let stageIDs = Set(ends)
        guard waypoints.stageModes.keys.allSatisfy(stageIDs.contains),
              waypoints.roundTripAnchors.allSatisfy({ endID, rootID in
                  guard stageIDs.contains(endID),
                        let endIndex = points.firstIndex(where: { $0.id == endID }),
                        let rootIndex = points.firstIndex(where: { $0.id == rootID }),
                        rootIndex < endIndex else { return false }
                  return points[rootIndex].distance(to: points[endIndex]) < 1
              }) else {
            throw RoundTripMigrationError.invalidWaypoints
        }
        let budgets = ends.compactMap { waypoints.details[$0]?.stageBudgetMinutes }
        var totalBudget = 0
        for budget in budgets {
            let (sum, overflow) = totalBudget.addingReportingOverflow(budget)
            guard !overflow else { throw RoundTripMigrationError.budgetOverflow }
            totalBudget = sum
        }
        let firstMode = waypoints.stageModes[ends[0]] ?? .driving
        let hadAcceptedOverruns = ends.contains { waypoints.details[$0]?.acceptedBudgetOverrun != nil }
        for stop in waypoints.stops {
            guard var details = waypoints.details[stop.id] else { continue }
            details.overnight = false
            if ends.contains(stop.id) {
                details.stageBudgetMinutes = nil
                details.acceptedBudgetOverrun = nil
            }
            waypoints.details[stop.id] = details
        }
        var endDetails = waypoints.details[destination.id] ?? WaypointDetails()
        endDetails.stageBudgetMinutes = budgets.isEmpty ? nil : totalBudget
        endDetails.acceptedBudgetOverrun = nil
        waypoints.details[destination.id] = endDetails
        waypoints.stageModes = [destination.id: firstMode]
        waypoints.roundTripAnchors = [:]
        let pairs = Set(zip(points, points.dropFirst()).map { TransitLeg(from: $0.id, to: $1.id) })
        let removedTransit = waypoints.transitLegs.subtracting(pairs).count
        waypoints.transitLegs.formIntersection(pairs)

        var photos = trip.photos
        for index in photos.indices {
            if case .stage(let id)? = photos[index].assignment?.target, stageIDs.contains(id) {
                photos[index].assignment?.target = .stage(destination.id)
            }
        }
        var notice = "Die Rundtour wurde zu einer Etappe zusammengeführt. Der Modus der ersten Etappe wurde übernommen."
        if budgets.count < ends.count {
            notice += " Nicht alle Etappen hatten ein eigenes Budget; nur vorhandene Budgets wurden addiert."
        }
        if hadAcceptedOverruns {
            notice += " Frühere Bestätigungen von Budgetüberschreitungen wurden zurückgesetzt."
        }
        if removedTransit > 0 {
            notice += " \(removedTransit) nicht mehr benachbarte ÖPNV-Markierung(en) wurden entfernt."
        }
        trip.waypoints = waypoints
        trip.photos = photos
        appendPhotoWarning(to: &notice, trip: trip)
        return notice
    }
}

struct TripStore {
    var url = URL.applicationSupportDirectory
        .appending(path: "RoadTripAssist", directoryHint: .isDirectory)
        .appending(path: "trips.json")
    var selectedTripURL: URL {
        url.deletingLastPathComponent().appending(path: "selected-trip.json")
    }

    var mediaDirectory: URL {
        url.deletingLastPathComponent().appending(path: "media", directoryHint: .isDirectory)
    }

    func load() throws -> [RoadTrip] {
        do {
            return try JSONDecoder().decode([RoadTrip].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    func save(_ trips: [RoadTrip]) throws {
        let data = try JSONEncoder().encode(trips)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func loadSelectedTripID() throws -> RoadTrip.ID? {
        do {
            return try JSONDecoder().decode(RoadTrip.ID.self, from: Data(contentsOf: selectedTripURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func saveSelectedTripID(_ id: RoadTrip.ID?) throws {
        guard let id else {
            guard FileManager.default.fileExists(atPath: selectedTripURL.path) else { return }
            try FileManager.default.removeItem(at: selectedTripURL)
            return
        }
        let data = try JSONEncoder().encode(id)
        try FileManager.default.createDirectory(at: selectedTripURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: selectedTripURL, options: .atomic)
    }
}

@MainActor
final class TripLibrary: ObservableObject {
    @Published private(set) var trips: [RoadTrip] = []
    @Published private(set) var selectedID: RoadTrip.ID?
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var selectedTripSaveError: String?
    @Published private(set) var mediaCleanupError: String?

    let planner: TripPlannerViewModel
    private let store: TripStore
    private let photoStore: TripPhotoStore

    init(store: TripStore = TripStore(), planner: TripPlannerViewModel? = nil) {
        self.store = store
        photoStore = TripPhotoStore(mediaDirectory: store.mediaDirectory)
        self.planner = planner ?? TripPlannerViewModel()
        reload()
        self.planner.onWaypointsChanged = { [weak self] waypoints in
            guard let self, let index = self.trips.firstIndex(where: { $0.id == self.selectedID }) else { return }
            Self.preserveSegmentAssignments(in: &self.trips[index], after: waypoints)
            self.trips[index].waypoints = waypoints
            self.save()
        }
    }

    private static func preserveSegmentAssignments(in trip: inout RoadTrip, after updated: TripWaypoints) {
        func firstPairs(_ waypoints: TripWaypoints) -> [RoadStop.ID: TransitLeg] {
            guard let start = waypoints.start, let destination = waypoints.destination else { return [:] }
            let points = [start] + waypoints.stops + [destination]
            let anchors = Set(waypoints.stops.filter { waypoints.details[$0.id]?.overnight == true }.map(\.id))
            return Dictionary(uniqueKeysWithValues: TripStage.ranges(in: points, anchors: anchors).map { range in
                (points[range.upperBound].id,
                 TransitLeg(from: points[range.lowerBound].id, to: points[range.lowerBound + 1].id))
            })
        }
        let previous = trip.waypoints
        let oldPairs = firstPairs(previous)
        let newPairs = firstPairs(updated)
        if previous.isRoundTrip != updated.isRoundTrip,
           let oldEnd = previous.destination?.id, let newEnd = updated.destination?.id,
           oldPairs[oldEnd] != nil, newPairs[newEnd] != nil,
           newPairs[oldEnd] == nil, oldPairs[newEnd] == nil {
            for index in trip.photos.indices {
                if trip.photos[index].assignment?.target == .stage(oldEnd) {
                    trip.photos[index].assignment?.target = .stage(newEnd)
                }
            }
        }
        for (stageID, old) in oldPairs {
            guard let new = newPairs[stageID], old.from != new.from, old.to == new.to,
                  (previous.roundTripAnchors[old.from] ?? old.from)
                    == (updated.roundTripAnchors[new.from] ?? new.from) else { continue }
            for index in trip.photos.indices {
                guard case .routeSegment(let from, let to)? = trip.photos[index].assignment?.target,
                      from == old.from, to == old.to else { continue }
                trip.photos[index].assignment?.target = .routeSegment(from: new.from, to: new.to)
            }
        }
    }

    var selectedTrip: RoadTrip? {
        trips.first { $0.id == selectedID }
    }

    func exportTrip(_ trip: RoadTrip, to url: URL) async throws {
        guard loadError == nil else { throw TripPhotoError.tripUnavailable }
        let photoStore = self.photoStore
        try await Task.detached { try TripExchange.export(trip, photoStore: photoStore, to: url) }.value
    }

    func exportHTML(_ trip: RoadTrip, to url: URL) async throws {
        guard loadError == nil, selectedID == trip.id else { throw TripPhotoError.tripUnavailable }
        try await TripHTMLExport.export(trip: trip, planner: planner, photoStore: photoStore, to: url)
    }

    func importTrip(from url: URL) async throws {
        guard loadError == nil else { throw TripPhotoError.tripUnavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: photoStore.mediaDirectory, withIntermediateDirectories: true)
        let staging = try TemporaryExportDirectory.create(in: photoStore.mediaDirectory, prefix: "import")
        var movedDirectory: URL?
        do {
            var trip = try await Task.detached { try TripExchange.read(from: url, into: staging) }.value
            guard loadError == nil else { throw TripPhotoError.tripUnavailable }
            repeat { trip.id = UUID() } while trips.contains(where: { $0.id == trip.id })
            let directory = photoStore.mediaDirectory.appendingPathComponent(trip.id.uuidString, isDirectory: true)
            guard !manager.fileExists(atPath: directory.path) else {
                throw TripExchangeError.invalid("Der Medienordner der importierten Reise existiert bereits.")
            }
            try manager.moveItem(at: staging, to: directory)
            movedDirectory = directory
            try store.save(trips + [trip])
            trips.append(trip)
            saveError = nil
            select(trip.id)
        } catch {
            do {
                for directory in [staging, movedDirectory].compactMap({ $0 }) where manager.fileExists(atPath: directory.path) {
                    try manager.removeItem(at: directory)
                }
            } catch let cleanupError {
                throw TripExchangeError.rollback(cleanupError.localizedDescription)
            }
            throw error
        }
    }

    func select(_ id: RoadTrip.ID) {
        guard id != selectedID, let trip = trips.first(where: { $0.id == id }) else { return }
        selectedID = id
        planner.loadWaypoints(trip.waypoints, departureDate: trip.departureDate)
        saveSelectedTripID(id)
    }

    func updateTrip(id: RoadTrip.ID?, name: String, notes: String) {
        updateTrip(id: id, name: name, notes: notes,
                   departureDate: trips.first(where: { $0.id == id })?.departureDate,
                   isRoundTrip: trips.first(where: { $0.id == id })?.waypoints.isRoundTrip ?? false)
    }

    func updateTrip(id: RoadTrip.ID?, name: String, notes: String, departureDate: Date?,
                    isRoundTrip: Bool? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !name.isEmpty else { return }
        if let id {
            guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
            let roundTrip = isRoundTrip ?? trips[index].waypoints.isRoundTrip
            if roundTrip && !trips[index].waypoints.isRoundTrip,
               trips[index].waypoints.start != nil, trips[index].waypoints.destination != nil {
                var converted = trips[index]
                do {
                    let notice = try RoundTripMigration.convertToStandalone(&converted)
                    converted.name = name
                    converted.notes = notes
                    converted.departureDate = departureDate
                    converted.migrationNotices.append(notice)
                    trips[index] = converted
                    if id == selectedID {
                        planner.loadWaypoints(converted.waypoints, departureDate: departureDate)
                    }
                    save()
                } catch {
                    saveError = error.localizedDescription
                }
                return
            }
            trips[index].name = name
            trips[index].notes = notes
            trips[index].departureDate = departureDate
            if id == selectedID {
                planner.setRoundTrip(roundTrip)
                planner.setDepartureDate(departureDate)
            } else if trips[index].waypoints.isRoundTrip != roundTrip {
                let temporaryPlanner = TripPlannerViewModel()
                temporaryPlanner.loadWaypoints(trips[index].waypoints, departureDate: departureDate)
                temporaryPlanner.onWaypointsChanged = { [weak self] waypoints in
                    guard let self, let index = self.trips.firstIndex(where: { $0.id == id }) else { return }
                    Self.preserveSegmentAssignments(in: &self.trips[index], after: waypoints)
                    self.trips[index].waypoints = waypoints
                }
                temporaryPlanner.setRoundTrip(roundTrip)
            }
        } else {
            let trip = RoadTrip(name: name, notes: notes, waypoints: TripWaypoints(isRoundTrip: isRoundTrip ?? false),
                                departureDate: departureDate)
            trips.append(trip)
            select(trip.id)
        }
        save()
    }

    func delete(_ id: RoadTrip.ID) {
        guard loadError == nil, let index = trips.firstIndex(where: { $0.id == id }) else { return }
        trips.remove(at: index)
        if selectedID == id {
            if trips.isEmpty {
                selectedID = nil
                planner.loadWaypoints(TripWaypoints())
                saveSelectedTripID(nil)
            } else {
                select(trips[min(index, trips.count - 1)].id)
            }
        }
        save()
        guard saveError == nil else { return }
        do {
            try photoStore.removeTripMedia(id)
            mediaCleanupError = nil
        } catch {
            mediaCleanupError = error.localizedDescription
        }
    }

    func addPhoto(data: Data, originalName: String, tripID: RoadTrip.ID) async throws {
        guard trips.contains(where: { $0.id == tripID }) else {
            throw TripPhotoError.tripUnavailable
        }
        let metadata = try await performPhotoIO {
            try PhotoMetadata.read(from: data)
        }
        let fileExtension = Self.safeImageExtension(from: originalName)
        let suggestion: PhotoAssignmentTarget?
        if let coordinate = metadata.coordinate, selectedID == tripID {
            let contexts = [planner] + planner.lodgingTours.compactMap { planner.tourPlanners[$0.id] }
            suggestion = PhotoAssignmentSuggester.suggest(at: coordinate.coordinate, contexts: contexts.map {
                PhotoAssignmentSuggester.Context(waypoints: $0.orderedWaypoints, stages: $0.stages,
                                                 routeLegs: currentRouteLegs(for: $0))
            })
        } else {
            suggestion = nil
        }
        let photo = TripPhoto(fileExtension: fileExtension, originalName: URL(fileURLWithPath: originalName).lastPathComponent,
                              capturedAt: metadata.capturedAt, coordinate: metadata.coordinate,
                              assignment: suggestion.map { PhotoAssignment(target: $0, status: .suggested) })
        let photoStore = self.photoStore
        try await performPhotoIO {
            try photoStore.write(data, for: photo, tripID: tripID)
        }
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else {
            try await performPhotoIO(priority: .utility) {
                try photoStore.remove(photo, tripID: tripID)
            }
            throw TripPhotoError.tripUnavailable
        }
        trips[index].photos.append(photo)
        do {
            try persist()
        } catch {
            trips[index].photos.removeAll { $0.id == photo.id }
            do {
                try await performPhotoIO(priority: .utility) {
                    try photoStore.remove(photo, tripID: tripID)
                }
            } catch {
                throw TripPhotoError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    func photoURL(for photo: TripPhoto, tripID: RoadTrip.ID) -> URL {
        photoStore.photoURL(photo, tripID: tripID)
    }

    func updatePhotoCaption(_ caption: String, photoID: TripPhoto.ID, tripID: RoadTrip.ID) throws {
        try updatePhoto(photoID, tripID: tripID) { $0.caption = caption }
    }

    func rotatePhoto(photoID: TripPhoto.ID, tripID: RoadTrip.ID, clockwise: Bool) throws {
        try updatePhoto(photoID, tripID: tripID) { photo in
            photo.rotationQuarterTurns = (photo.rotationQuarterTurns + (clockwise ? 1 : 3)) % 4
        }
    }

    func updatePhotoAssignment(_ target: PhotoAssignmentTarget?, photoID: TripPhoto.ID,
                               tripID: RoadTrip.ID) throws {
        try updatePhoto(photoID, tripID: tripID) { photo in
            photo.assignment = target.map { PhotoAssignment(target: $0, status: .confirmed) }
        }
    }

    func confirmPhotoSuggestion(photoID: TripPhoto.ID, tripID: RoadTrip.ID) throws {
        try updatePhoto(photoID, tripID: tripID) { photo in
            guard var assignment = photo.assignment, assignment.status == .suggested else { return }
            assignment.status = .confirmed
            photo.assignment = assignment
        }
    }

    @discardableResult
    func addPhotoLocationAsWaypoint(photoID: TripPhoto.ID, tripID: RoadTrip.ID, tourID: UUID? = nil) throws -> RoadStop {
        guard selectedID == tripID,
              let photo = trips.first(where: { $0.id == tripID })?.photos.first(where: { $0.id == photoID }) else {
            throw TripPhotoError.photoUnavailable
        }
        guard let coordinate = photo.coordinate else {
            throw TripPhotoError.photoLocationUnavailable
        }
        let targetPlanner: TripPlannerViewModel
        if let tourID {
            guard let tourPlanner = planner.tourPlanners[tourID] else { throw TripPhotoError.tripUnavailable }
            targetPlanner = tourPlanner
        } else {
            targetPlanner = planner
        }
        guard targetPlanner.hasEndpoints else {
            throw TripPhotoError.routeEndpointsUnavailable
        }

        let photoStopName = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = photoStopName.isEmpty
            ? URL(fileURLWithPath: photo.originalName).deletingPathExtension().lastPathComponent
            : photoStopName
        let photoStop = RoadStop(name: name.isEmpty ? "Foto" : name,
                                 subtitle: photo.originalName,
                                 coordinate: coordinate.coordinate)
        let waypoint = targetPlanner.orderedWaypoints.first { $0.distance(to: photoStop) < 50 } ?? photoStop
        if waypoint.id == photoStop.id {
            targetPlanner.addMapPOI(photoStop)
            guard targetPlanner.orderedWaypoints.contains(where: { $0.id == photoStop.id }) else {
                throw TripPhotoError.routeEndpointsUnavailable
            }
            targetPlanner.updateDetails(WaypointDetails(category: .photo), for: photoStop)
        }
        try updatePhotoAssignment(.waypoint(waypoint.id), photoID: photoID, tripID: tripID)
        return waypoint
    }

    func deletePhoto(_ photoID: TripPhoto.ID, tripID: RoadTrip.ID) throws {
        guard let tripIndex = trips.firstIndex(where: { $0.id == tripID }),
              let photoIndex = trips[tripIndex].photos.firstIndex(where: { $0.id == photoID }) else {
            throw TripPhotoError.photoUnavailable
        }
        let photo = trips[tripIndex].photos[photoIndex]
        let data = try photoStore.read(photo, tripID: tripID)
        try photoStore.remove(photo, tripID: tripID)
        trips[tripIndex].photos.remove(at: photoIndex)
        do {
            try persist()
        } catch {
            trips[tripIndex].photos.insert(photo, at: photoIndex)
            do {
                try photoStore.write(data, for: photo, tripID: tripID)
            } catch {
                throw TripPhotoError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    func retryLoad() {
        guard loadError != nil else { return }
        reload()
    }

    func dismissMigrationNotices(for id: RoadTrip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == id }),
              !trips[index].migrationNotices.isEmpty else { return }
        trips[index].migrationNotices = []
        save()
    }

    func retrySelectedTripSave() {
        saveSelectedTripID(selectedID)
    }

    func save() {
        guard loadError == nil else { return }
        do {
            try persist()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func currentRouteLegs(for planner: TripPlannerViewModel) -> [RouteLeg]? {
        guard let route = planner.roadPreview, route.orderedStops == planner.stops,
              route.legs.count == max(0, planner.orderedWaypoints.count - 1) else { return nil }
        return route.legs
    }

    private func updatePhoto(_ photoID: TripPhoto.ID, tripID: RoadTrip.ID,
                             update: (inout TripPhoto) -> Void) throws {
        guard let tripIndex = trips.firstIndex(where: { $0.id == tripID }),
              let photoIndex = trips[tripIndex].photos.firstIndex(where: { $0.id == photoID }) else {
            throw TripPhotoError.photoUnavailable
        }
        let original = trips[tripIndex].photos[photoIndex]
        update(&trips[tripIndex].photos[photoIndex])
        guard trips[tripIndex].photos[photoIndex] != original else { return }
        do {
            try persist()
        } catch {
            trips[tripIndex].photos[photoIndex] = original
            throw error
        }
    }

    private func persist() throws {
        guard loadError == nil else { throw TripPhotoError.tripUnavailable }
        do {
            try store.save(trips)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }

    private static func safeImageExtension(from filename: String) -> String {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return fileExtension.isEmpty ? "img" : fileExtension
    }

    private func reload() {
        do {
            var loaded = try store.load()
            var migrated = false
            for index in loaded.indices {
                do {
                    if let notice = try RoundTripMigration.extractLodgingTours(&loaded[index])
                        ?? RoundTripMigration.mergeStandalone(&loaded[index]) {
                        loaded[index].migrationNotices.append(notice)
                        migrated = true
                    }
                    try RoundTripMigration.validate(loaded[index].waypoints)
                } catch {
                    throw TripMigrationFailure(tripName: loaded[index].name, reason: error.localizedDescription)
                }
            }
            if migrated { try store.save(loaded) }
            trips = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            return
        }

        selectedID = nil
        planner.loadWaypoints(TripWaypoints())
        let lastSelectedID: RoadTrip.ID?
        do {
            lastSelectedID = try store.loadSelectedTripID()
        } catch {
            selectedTripSaveError = error.localizedDescription
            lastSelectedID = nil
        }
        let restoredID = lastSelectedID.flatMap { id in trips.contains { $0.id == id } ? id : nil }
        if let restoredID { select(restoredID) }
        else if let first = trips.first { select(first.id) }
        else { saveSelectedTripID(nil) }
    }

    private func saveSelectedTripID(_ id: RoadTrip.ID?) {
        do {
            try store.saveSelectedTripID(id)
            selectedTripSaveError = nil
        } catch {
            selectedTripSaveError = error.localizedDescription
        }
    }
}
