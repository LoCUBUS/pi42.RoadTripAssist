import Combine
import Foundation

struct TripWaypoints: Codable {
    var start: RoadStop?
    var stops: [RoadStop] = []
    var destination: RoadStop?
    var manualOrder = false

    init(start: RoadStop? = nil, stops: [RoadStop] = [], destination: RoadStop? = nil,
         manualOrder: Bool = false) {
        self.start = start
        self.stops = stops
        self.destination = destination
        self.manualOrder = manualOrder
    }

    private enum CodingKeys: String, CodingKey {
        case start, stops, destination, manualOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(RoadStop.self, forKey: .start)
        stops = try container.decode([RoadStop].self, forKey: .stops)
        destination = try container.decodeIfPresent(RoadStop.self, forKey: .destination)
        manualOrder = try container.decodeIfPresent(Bool.self, forKey: .manualOrder) ?? false
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
