import CoreLocation
import Foundation
import ImageIO

struct PhotoCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init?(latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

enum PhotoAssignmentTarget: Codable, Hashable, Sendable {
    case waypoint(RoadStop.ID)
    case stage(RoadStop.ID)
    case routeSegment(from: RoadStop.ID, to: RoadStop.ID)
}

struct PhotoAssignment: Codable, Equatable, Sendable {
    enum Status: String, Codable {
        case suggested
        case confirmed
    }

    var target: PhotoAssignmentTarget
    var status: Status
}

struct TripPhoto: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileExtension: String
    let originalName: String
    let capturedAt: Date?
    let coordinate: PhotoCoordinate?
    var caption: String
    var assignment: PhotoAssignment?
    var rotationQuarterTurns: Int

    init(id: UUID = UUID(), fileExtension: String, originalName: String, capturedAt: Date?,
         coordinate: PhotoCoordinate?, caption: String = "", assignment: PhotoAssignment? = nil,
         rotationQuarterTurns: Int = 0) {
        self.id = id
        self.fileExtension = fileExtension
        self.originalName = originalName
        self.capturedAt = capturedAt
        self.coordinate = coordinate
        self.caption = caption
        self.assignment = assignment
        self.rotationQuarterTurns = Self.normalizedRotation(rotationQuarterTurns)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileExtension, originalName, capturedAt, coordinate, caption, assignment, rotationQuarterTurns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        originalName = try container.decode(String.self, forKey: .originalName)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        coordinate = try container.decodeIfPresent(PhotoCoordinate.self, forKey: .coordinate)
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        assignment = try container.decodeIfPresent(PhotoAssignment.self, forKey: .assignment)
        rotationQuarterTurns = Self.normalizedRotation(
            try container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        )
    }

    private static func normalizedRotation(_ quarterTurns: Int) -> Int {
        (quarterTurns % 4 + 4) % 4
    }
}

enum TripPhotoError: LocalizedError {
    case invalidImage
    case tripUnavailable
    case photoUnavailable
    case photoLocationUnavailable
    case routeEndpointsUnavailable
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Die Datei enthält kein lesbares Bild."
        case .tripUnavailable:
            "Die ausgewählte Reise ist nicht mehr verfügbar."
        case .photoUnavailable:
            "Das Foto ist nicht mehr verfügbar."
        case .photoLocationUnavailable:
            "Dieses Foto enthält keine GPS-Koordinaten."
        case .routeEndpointsUnavailable:
            "Lege zuerst Start und Ziel fest, bevor du einen Foto-Ort als Wegpunkt hinzufügst."
        case .rollbackFailed(let reason):
            "Die Fotoänderung konnte nicht vollständig zurückgesetzt werden: \(reason)"
        }
    }
}

struct TripPhotoStore: Sendable {
    let mediaDirectory: URL

    func photoURL(_ photo: TripPhoto, tripID: RoadTrip.ID) -> URL {
        let fileExtension = photo.fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let safeExtension = fileExtension.isEmpty ? "img" : fileExtension
        return mediaDirectory
            .appending(path: tripID.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(photo.id.uuidString).\(safeExtension)")
    }

    func write(_ data: Data, for photo: TripPhoto, tripID: RoadTrip.ID) throws {
        let url = photoURL(photo, tripID: tripID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func read(_ photo: TripPhoto, tripID: RoadTrip.ID) throws -> Data {
        try Data(contentsOf: photoURL(photo, tripID: tripID))
    }

    func remove(_ photo: TripPhoto, tripID: RoadTrip.ID) throws {
        let url = photoURL(photo, tripID: tripID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func removeTripMedia(_ tripID: RoadTrip.ID) throws {
        let directory = mediaDirectory.appending(path: tripID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

struct PhotoMetadata: Sendable {
    let capturedAt: Date?
    let coordinate: PhotoCoordinate?

    static func read(from data: Data) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw TripPhotoError.invalidImage
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String
        let timezoneOffset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        let capturedAt = dateString.flatMap { parseEXIFDate($0, timezoneOffset: timezoneOffset) }
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        let coordinate = gps.flatMap(readCoordinate)
        return PhotoMetadata(capturedAt: capturedAt, coordinate: coordinate)
    }

    private static func readCoordinate(from gps: [String: Any]) -> PhotoCoordinate? {
        guard let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue else {
            return nil
        }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
        let signedLatitude = latitudeRef == "S" ? -abs(latitude) : abs(latitude)
        let signedLongitude = longitudeRef == "W" ? -abs(longitude) : abs(longitude)
        return PhotoCoordinate(latitude: signedLatitude, longitude: signedLongitude)
    }

    private static func parseEXIFDate(_ value: String, timezoneOffset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.timeZone = timezoneOffset.flatMap(timeZone(from:)) ?? .current
        for format in ["yyyy:MM:dd HH:mm:ss.SSS", "yyyy:MM:dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func timeZone(from value: String) -> TimeZone? {
        guard value.count == 6, let sign = value.first, sign == "+" || sign == "-",
              let hours = Int(value.dropFirst().prefix(2)),
              let minutes = Int(value.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
        let offset = (hours * 60 + minutes) * 60 * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: offset)
    }
}

enum PhotoAssignmentSuggester {
    struct Context {
        let waypoints: [RoadStop]
        let stages: [TripStage]
        let routeLegs: [RouteLeg]?
    }

    static let waypointRadius: CLLocationDistance = 2_000
    static let routeRadius: CLLocationDistance = 2_000
    static let stageRadius: CLLocationDistance = 20_000

    static func suggest(at coordinate: CLLocationCoordinate2D, waypoints: [RoadStop], stages: [TripStage],
                        routeLegs: [RouteLeg]?) -> PhotoAssignmentTarget? {
        suggest(at: coordinate, contexts: [Context(waypoints: waypoints, stages: stages, routeLegs: routeLegs)])
    }

    static func suggest(at coordinate: CLLocationCoordinate2D, contexts: [Context]) -> PhotoAssignmentTarget? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearestWaypoint = contexts.flatMap(\.waypoints)
            .map { ($0, location.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                                            longitude: $0.coordinate.longitude))) }
            .min { $0.1 < $1.1 }

        if let nearestWaypoint, nearestWaypoint.1 <= waypointRadius {
            return .waypoint(nearestWaypoint.0.id)
        }

        let segments: [(PhotoAssignmentTarget, CLLocationDistance)] = contexts.flatMap { context -> [(PhotoAssignmentTarget, CLLocationDistance)] in
            guard let legs = context.routeLegs, legs.count == max(0, context.waypoints.count - 1) else { return [] }
            return legs.enumerated().compactMap { index, leg -> (PhotoAssignmentTarget, CLLocationDistance)? in
                guard !leg.isTransit else { return nil }
                let from = context.waypoints[index]
                let to = context.waypoints[index + 1]
                return (.routeSegment(from: from.id, to: to.id),
                        distance(from: coordinate, to: leg.coordinates, start: from.coordinate, end: to.coordinate))
            }
        }
        if let segment = segments.min(by: { $0.1 < $1.1 }), segment.1 <= routeRadius {
            return segment.0
        }

        guard let nearestWaypoint, nearestWaypoint.1 <= stageRadius,
              let stage = contexts.flatMap(\.stages).first(where: { $0.waypoints.contains(nearestWaypoint.0) }) else {
            return nil
        }
        return .stage(stage.id)
    }

    private static func distance(from coordinate: CLLocationCoordinate2D,
                                 to routeCoordinates: [CLLocationCoordinate2D],
                                 start: CLLocationCoordinate2D,
                                 end: CLLocationCoordinate2D) -> CLLocationDistance {
        let points = [start] + routeCoordinates + [end]
        guard points.count > 1 else { return .infinity }
        let latitudeScale = cos(coordinate.latitude * .pi / 180) * 6_371_000
        func project(_ point: CLLocationCoordinate2D) -> (Double, Double) {
            let x = (point.longitude - coordinate.longitude) * .pi / 180 * latitudeScale
            let y = (point.latitude - coordinate.latitude) * .pi / 180 * 6_371_000
            return (x, y)
        }
        let segments = zip(points, points.dropFirst())
        return segments.map { first, second in
            let a = project(first)
            let b = project(second)
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(a.0, a.1) }
            let fraction = min(1, max(0, -(a.0 * dx + a.1 * dy) / lengthSquared))
            return hypot(a.0 + fraction * dx, a.1 + fraction * dy)
        }.min() ?? .infinity
    }
}
