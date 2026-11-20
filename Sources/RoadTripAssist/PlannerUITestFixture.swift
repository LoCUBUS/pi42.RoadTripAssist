#if UI_TEST_SUPPORT
import MapKit

@MainActor
struct PlannerUITestFixture {
    let directory: URL

    var mapPOI: MapPointOfInterest {
        MapPointOfInterest(stop: RoadStop(name: "Testcafe", subtitle: "Teststraße 1",
                                         coordinate: .init(latitude: 50, longitude: 12.5)),
                           phoneNumber: nil, website: nil)
    }

    static var requested: Self? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ui-testing") else { return nil }
        guard let path = process.environment["ROADTRIP_UI_TEST_DIRECTORY"], path.hasPrefix("/") else {
            preconditionFailure("UI testing requires an absolute ROADTRIP_UI_TEST_DIRECTORY")
        }
        return Self(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    func makeLibrary() -> TripLibrary {
        let cities = ["Startstadt", "Zwischenstadt A", "Zwischenstadt B", "Zielstadt"]
        var search = zip(cities, [11.0, 12.0, 13.0, 14.0]).map { name, longitude in
            RoadStop(name: name, subtitle: "", coordinate: .init(latitude: 50, longitude: longitude))
        }
        search.append(RoadStop(name: "Brandenburger Tor", subtitle: "",
                               coordinate: .init(latitude: 52.51627, longitude: 13.37770)))
        let places = search
        let service = MapKitRouteService { from, to in
            RouteLeg(duration: 600, distance: 1_000 * abs(from.coordinate.longitude - to.coordinate.longitude),
                     coordinates: [from.coordinate, to.coordinate])
        }
        let planner = TripPlannerViewModel(routeService: service) { query in
            places.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        let library = TripLibrary(store: TripStore(url: directory.appending(path: "trips.json")), planner: planner)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-stages"), library.trips.isEmpty {
            library.updateTrip(id: nil, name: "Etappenreise", notes: "")
            planner.setStart(places[0])
            planner.setDestination(places[3])
            planner.addStop(places[1])
        }
        return library
    }

    func recordMapsHandoff(_ item: MKMapItem, options: [String: Any]) -> Bool {
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        do {
            let record = [
                "name": item.name ?? "",
                "latitude": String(coordinate.latitude),
                "longitude": String(coordinate.longitude),
                "mode": options[MKLaunchOptionsDirectionsModeKey] as? String ?? ""
            ]
            try JSONEncoder().encode(record).write(to: directory.appending(path: "maps-handoff.json"),
                                                   options: .atomic)
            return true
        } catch {
            NSLog("Could not record UI test Maps handoff: %@", error.localizedDescription)
            return false
        }
    }
}
#endif
