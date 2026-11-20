import Combine
import CoreLocation
import Foundation

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

struct WaypointDetails: Codable, Equatable {
    var stayMinutes = 0
    var notes = ""
    var rating = 0
    var status = VisitStatus.pending
    var overnight = false
    var stageBudgetMinutes: Int?
    var acceptedBudgetOverrun: StageBudgetOverrun?
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

    init(start: RoadStop? = nil, stops: [RoadStop] = [], destination: RoadStop? = nil,
         manualOrder: Bool = false, details: [RoadStop.ID: WaypointDetails] = [:],
         defaultStageBudgetMinutes: Int? = nil) {
        self.start = start
        self.stops = stops
        self.destination = destination
        self.manualOrder = manualOrder
        self.details = details
        self.defaultStageBudgetMinutes = defaultStageBudgetMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case start, stops, destination, manualOrder, details, defaultStageBudgetMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(RoadStop.self, forKey: .start)
        stops = try container.decode([RoadStop].self, forKey: .stops)
        destination = try container.decodeIfPresent(RoadStop.self, forKey: .destination)
        manualOrder = try container.decodeIfPresent(Bool.self, forKey: .manualOrder) ?? false
        details = try container.decodeIfPresent([RoadStop.ID: WaypointDetails].self, forKey: .details) ?? [:]
        defaultStageBudgetMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultStageBudgetMinutes)
    }
}

struct RoadTrip: Identifiable, Codable {
    var id = UUID()
    var name: String
    var notes: String
    var waypoints = TripWaypoints()
}

struct TripStore {
    var url = URL.applicationSupportDirectory
        .appending(path: "RoadTripAssist", directoryHint: .isDirectory)
        .appending(path: "trips.json")

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
}

@MainActor
final class TripLibrary: ObservableObject {
    @Published private(set) var trips: [RoadTrip] = []
    @Published private(set) var selectedID: RoadTrip.ID?
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?

    let planner: TripPlannerViewModel
    private let store: TripStore

    init(store: TripStore = TripStore(), planner: TripPlannerViewModel? = nil) {
        self.store = store
        self.planner = planner ?? TripPlannerViewModel()
        reload()
        self.planner.onWaypointsChanged = { [weak self] waypoints in
            guard let self, let index = self.trips.firstIndex(where: { $0.id == self.selectedID }) else { return }
            self.trips[index].waypoints = waypoints
            self.save()
        }
    }

    var selectedTrip: RoadTrip? {
        trips.first { $0.id == selectedID }
    }

    func select(_ id: RoadTrip.ID) {
        guard id != selectedID, let trip = trips.first(where: { $0.id == id }) else { return }
        selectedID = id
        planner.loadWaypoints(trip.waypoints)
    }

    func updateTrip(id: RoadTrip.ID?, name: String, notes: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !name.isEmpty else { return }
        if let id {
            guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
            trips[index].name = name
            trips[index].notes = notes
        } else {
            let trip = RoadTrip(name: name, notes: notes)
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
            } else {
                select(trips[min(index, trips.count - 1)].id)
            }
        }
        save()
    }

    func retryLoad() {
        guard loadError != nil else { return }
        reload()
    }

    func save() {
        guard loadError == nil else { return }
        do {
            try store.save(trips)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reload() {
        do {
            trips = try store.load()
            loadError = nil
            if let first = trips.first { select(first.id) }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
