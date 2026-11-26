import CoreLocation

struct RoadStop: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let subtitle: String
    private let latitude: Double
    private let longitude: Double

    init(id: UUID = UUID(), name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    func newOccurrence() -> RoadStop {
        RoadStop(name: name, subtitle: subtitle, coordinate: coordinate)
    }

    func atSamePlace(as stop: RoadStop) -> RoadStop {
        RoadStop(id: id, name: stop.name, subtitle: stop.subtitle, coordinate: stop.coordinate)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (lhs: RoadStop, rhs: RoadStop) -> Bool {
        lhs.id == rhs.id
    }

    func distance(to other: RoadStop) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    func matchesMapPlace(_ other: RoadStop) -> Bool {
        self == other || (name.compare(other.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                          && distance(to: other) < 50)
    }

    static func bestInsertionIndex(for stop: RoadStop, along waypoints: [RoadStop]) -> Int {
        let costs = zip(waypoints, waypoints.dropFirst()).map { from, to in
            from.distance(to: stop) + stop.distance(to: to) - from.distance(to: to)
        }
        return costs.indices.min { costs[$0] < costs[$1] } ?? 0
    }

    static func provisionalOrder(start: RoadStop, stops: [RoadStop], destination: RoadStop) -> [RoadStop] {
        let points = ([start] + stops + [destination]).map {
            CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        let end = points.count - 1
        let distances = points.map { from in points.map { from.distance(from: $0) } }
        let indices = Array(1..<end)
        if stops.count <= 10,
           let order = try? RouteOptimizer.optimize(travelTimes: distances, startIndex: 0,
                                                    stopIndices: indices, destinationIndex: end) {
            return order.map { stops[$0 - 1] }
        }

        // Keep larger lists responsive by inserting each stop into its shortest gap.
        var path = [0, end]
        for stop in indices {
            let gap = path.indices.dropLast().min { lhs, rhs in
                func cost(_ index: Int) -> Double {
                    let from = path[index]
                    let to = path[index + 1]
                    return distances[from][stop] + distances[stop][to] - distances[from][to]
                }
                return cost(lhs) < cost(rhs)
            }
            if let gap { path.insert(stop, at: gap + 1) }
        }
        return path.dropFirst().dropLast().map { stops[$0 - 1] }
    }
}
