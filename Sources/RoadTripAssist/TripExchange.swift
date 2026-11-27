import CoreLocation
import Darwin
import Foundation
import ZIPFoundation

enum TemporaryExportDirectory {
    static func create(in parent: URL, prefix: String) throws -> URL {
        let url = parent.appendingPathComponent(".\(prefix)-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return url
    }
}

enum TripExchangeError: LocalizedError {
    case invalid(String)
    case unsupportedVersion(Int)
    case rollback(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Die Reisedatei ist ungültig: \(reason)"
        case .unsupportedVersion(let version): "Die Reisedatei verwendet die nicht unterstützte Formatversion \(version)."
        case .rollback(let reason): "Die Verarbeitung konnte nicht vollständig zurückgesetzt werden: \(reason)"
        }
    }
}

enum TripExchange {
    private struct Manifest: Codable {
        let format: String
        let version: Int
        let trip: RoadTrip
    }

    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    private static let maxManifestSize: UInt64 = 10 * 1024 * 1024
    private static let maxPhotoSize: UInt64 = 100 * 1024 * 1024
    private static let maxTotalSize: UInt64 = 1024 * 1024 * 1024
    private static let maxPhotos = 10_000

    private static func photoPath(_ photo: TripPhoto) throws -> String {
        let ext = photo.fileExtension
        guard !ext.isEmpty, ext.count <= 16,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw TripExchangeError.invalid("Ungültige Fotodateiendung.")
        }
        return "media/\(photo.id.uuidString).\(ext.lowercased())"
    }

    static func export(_ trip: RoadTrip, photoStore: TripPhotoStore, to destination: URL) throws {
        try validate(trip)
        let manager = FileManager.default
        let manifest = try JSONEncoder().encode(Manifest(format: "RoadTripAssist", version: 1, trip: trip))
        guard manifest.count <= maxManifestSize else { throw TripExchangeError.invalid("Reisedaten sind zu groß.") }
        let temporaryDirectory = try TemporaryExportDirectory.create(in: destination.deletingLastPathComponent(),
                                                                      prefix: "roadtrip")
        let temporary = temporaryDirectory.appendingPathComponent("archive")
        do {
            do {
                let archive = try Archive(url: temporary, accessMode: .create)
                try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifest.count),
                                     compressionMethod: .deflate) { position, size in
                    manifest.subdata(in: Int(position)..<Int(position) + size)
                }
                var total = UInt64(manifest.count)
                for photo in trip.photos {
                    let url = photoStore.photoURL(photo, tripID: trip.id)
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = (attributes[.size] as? NSNumber)?.uint64Value,
                          size <= maxPhotoSize, size <= maxTotalSize - total else {
                        throw TripExchangeError.invalid("Foto fehlt, ist zu groß oder keine reguläre Datei: \(photo.originalName)")
                    }
                    total += size
                    try archive.addEntry(with: photoPath(photo), fileURL: url, compressionMethod: .none)
                }
            }
            if manager.fileExists(atPath: destination.path) {
                let attributes = try manager.attributesOfItem(atPath: destination.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw TripExchangeError.invalid("Das Exportziel ist keine reguläre Datei.")
                }
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            try manager.removeItem(at: temporaryDirectory)
        } catch {
            do {
                if manager.fileExists(atPath: temporaryDirectory.path) { try manager.removeItem(at: temporaryDirectory) }
            } catch let cleanup { throw TripExchangeError.rollback(cleanup.localizedDescription) }
            throw error
        }
    }

    static func read(from url: URL, into stagingDirectory: URL) throws -> RoadTrip {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        var total: UInt64 = 0
        for entry in archive {
            guard entry.type == .file, entries[entry.path] == nil,
                  entry.uncompressedSize <= maxTotalSize - total,
                  entry.compressedSize <= maxTotalSize else {
                throw TripExchangeError.invalid("Unsicherer, doppelter oder zu großer Archiveintrag.")
            }
            total += entry.uncompressedSize
            entries[entry.path] = entry
            guard entries.count <= maxPhotos + 1 else { throw TripExchangeError.invalid("Zu viele Dateien.") }
        }
        guard let manifestEntry = entries["manifest.json"], manifestEntry.uncompressedSize <= maxManifestSize else {
            throw TripExchangeError.invalid("Manifest fehlt oder ist zu groß.")
        }
        let manifestData = try extract(manifestEntry, archive: archive, limit: maxManifestSize)
        let header = try JSONDecoder().decode(Header.self, from: manifestData)
        guard header.format == "RoadTripAssist" else { throw TripExchangeError.invalid("Unbekanntes Format.") }
        guard header.version == 1 else { throw TripExchangeError.unsupportedVersion(header.version) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        var trip = manifest.trip
        if let notice = try RoundTripMigration.extractLodgingTours(&trip)
            ?? RoundTripMigration.mergeStandalone(&trip) {
            trip.migrationNotices.append(notice)
        }
        try validate(trip)
        var expected = Set(["manifest.json"])
        for photo in trip.photos {
            let path = try photoPath(photo)
            guard expected.insert(path).inserted, let entry = entries[path], entry.uncompressedSize <= maxPhotoSize else {
                throw TripExchangeError.invalid("Foto fehlt, ist doppelt oder zu groß: \(photo.originalName)")
            }
        }
        guard Set(entries.keys) == expected else { throw TripExchangeError.invalid("Unerwartete Archiveinträge.") }
        for photo in trip.photos {
            let path = try photoPath(photo)
            guard let entry = entries[path] else { throw TripExchangeError.invalid("Foto fehlt.") }
            let file = stagingDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw TripExchangeError.invalid("Foto konnte nicht angelegt werden.")
            }
            let handle = try FileHandle(forWritingTo: file)
            var count: UInt64 = 0
            let checksum: CRC32
            do {
                checksum = try archive.extract(entry) { data in
                    guard UInt64(data.count) <= maxPhotoSize - count else {
                        throw TripExchangeError.invalid("Ein Foto ist zu groß.")
                    }
                    count += UInt64(data.count)
                    try handle.write(contentsOf: data)
                }
            } catch {
                do { try handle.close() }
                catch let closeError { throw TripExchangeError.rollback(closeError.localizedDescription) }
                throw error
            }
            try handle.close()
            guard count == entry.uncompressedSize, checksum == entry.checksum else {
                throw TripExchangeError.invalid("Prüfsumme oder Größe stimmt nicht.")
            }
            _ = try PhotoMetadata.read(from: Data(contentsOf: file, options: .mappedIfSafe))
        }
        return trip
    }

    private static func extract(_ entry: Entry, archive: Archive, limit: UInt64) throws -> Data {
        var result = Data()
        let checksum = try archive.extract(entry) { data in
            guard UInt64(result.count) <= limit, UInt64(data.count) <= limit - UInt64(result.count) else {
                throw TripExchangeError.invalid("Ein Archiveintrag ist zu groß.")
            }
            result.append(data)
        }
        guard UInt64(result.count) == entry.uncompressedSize, checksum == entry.checksum else {
            throw TripExchangeError.invalid("Prüfsumme oder Größe stimmt nicht.")
        }
        return result
    }

    private static func validate(_ trip: RoadTrip) throws {
        try RoundTripMigration.validate(trip.waypoints)
        guard trip.photos.count <= maxPhotos, Set(trip.photos.map(\.id)).count == trip.photos.count else {
            throw TripExchangeError.invalid("Zu viele oder doppelte Fotos.")
        }
        let contexts = [trip.waypoints] + trip.waypoints.lodgingTours.map(\.waypoints)
        for context in contexts {
            let points = [context.start].compactMap { $0 } + context.stops + [context.destination].compactMap { $0 }
            guard points.allSatisfy({ CLLocationCoordinate2DIsValid($0.coordinate) }) else {
                throw TripExchangeError.invalid("Ungültige Koordinaten.")
            }
            let contextPairs = Set(zip(points, points.dropFirst()).map { TransitLeg(from: $0.id, to: $1.id) })
            guard context.transitLegs.isSubset(of: contextPairs) else {
                throw TripExchangeError.invalid("Ungültige ÖPNV-Zuordnung.")
            }
        }
        for photo in trip.photos {
            _ = try photoPath(photo)
            if let coordinate = photo.coordinate,
               !CLLocationCoordinate2DIsValid(coordinate.coordinate) {
                throw TripExchangeError.invalid("Ungültige Fotokoordinaten.")
            }
        }
    }
}
