import CoreLocation

struct RoadStop: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: RoadStop, rhs: RoadStop) -> Bool {
        lhs.id == rhs.id
    }
}
