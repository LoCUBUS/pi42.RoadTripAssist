import CoreLocation

struct RoadStop: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: RoadStop, rhs: RoadStop) -> Bool {
        lhs.id == rhs.id
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
