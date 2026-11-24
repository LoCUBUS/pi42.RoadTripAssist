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
    var photos: [TripPhoto] = []
    var departureDate: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, notes, waypoints, photos, departureDate
    }

    init(id: UUID = UUID(), name: String, notes: String, waypoints: TripWaypoints = TripWaypoints(),
         photos: [TripPhoto] = [], departureDate: Date? = nil) {
        self.id = id
        self.name = name
        self.notes = notes
        self.waypoints = waypoints
        self.photos = photos
        self.departureDate = departureDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decode(String.self, forKey: .notes)
        waypoints = try container.decode(TripWaypoints.self, forKey: .waypoints)
        photos = try container.decodeIfPresent([TripPhoto].self, forKey: .photos) ?? []
        departureDate = try container.decodeIfPresent(Date.self, forKey: .departureDate)
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
        planner.loadWaypoints(trip.waypoints, departureDate: trip.departureDate)
        saveSelectedTripID(id)
    }

    func updateTrip(id: RoadTrip.ID?, name: String, notes: String) {
        updateTrip(id: id, name: name, notes: notes,
                   departureDate: trips.first(where: { $0.id == id })?.departureDate)
    }

    func updateTrip(id: RoadTrip.ID?, name: String, notes: String, departureDate: Date?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !name.isEmpty else { return }
        if let id {
            guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
            trips[index].name = name
            trips[index].notes = notes
            trips[index].departureDate = departureDate
            if id == selectedID { planner.setDepartureDate(departureDate) }
        } else {
            let trip = RoadTrip(name: name, notes: notes, departureDate: departureDate)
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
            suggestion = PhotoAssignmentSuggester.suggest(at: coordinate.coordinate, waypoints: planner.orderedWaypoints,
                                                           stages: planner.stages, routeLegs: currentRouteLegs)
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
    func addPhotoLocationAsWaypoint(photoID: TripPhoto.ID, tripID: RoadTrip.ID) throws -> RoadStop {
        guard selectedID == tripID,
              let photo = trips.first(where: { $0.id == tripID })?.photos.first(where: { $0.id == photoID }) else {
            throw TripPhotoError.photoUnavailable
        }
        guard let coordinate = photo.coordinate else {
            throw TripPhotoError.photoLocationUnavailable
        }
        guard planner.hasEndpoints else {
            throw TripPhotoError.routeEndpointsUnavailable
        }

        let photoStopName = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = photoStopName.isEmpty
            ? URL(fileURLWithPath: photo.originalName).deletingPathExtension().lastPathComponent
            : photoStopName
        let photoStop = RoadStop(name: name.isEmpty ? "Foto" : name,
                                 subtitle: photo.originalName,
                                 coordinate: coordinate.coordinate)
        let waypoint = planner.orderedWaypoints.first { $0.distance(to: photoStop) < 50 } ?? photoStop
        if waypoint.id == photoStop.id {
            planner.addMapPOI(photoStop)
            guard planner.orderedWaypoints.contains(where: { $0.id == photoStop.id }) else {
                throw TripPhotoError.routeEndpointsUnavailable
            }
            planner.updateDetails(WaypointDetails(category: .photo), for: photoStop)
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

    private var currentRouteLegs: [RouteLeg]? {
        guard let route = planner.roadPreview,
              route.orderedStops == planner.stops,
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
            trips = try store.load()
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
