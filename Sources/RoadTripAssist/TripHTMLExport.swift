import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TripHTMLExport {
    private struct Page {
        let title: String
        let filename: String
        let stage: TripStage
        let details: [UUID: WaypointDetails]
        let mode: TravelMode
    }

    @MainActor
    static func export(trip: RoadTrip, planner: TripPlannerViewModel, photoStore: TripPhotoStore,
                       to destination: URL) async throws {
        var pages: [Page] = planner.stages.enumerated().map { index, stage in
            Page(title: "Etappe \(index + 1): \(stage.end.name)", filename: "etappe-\(index + 1).html",
                 stage: stage, details: planner.details, mode: planner.mode(for: stage))
        }
        for (index, tour) in planner.lodgingTours.enumerated() {
            guard let tourPlanner = planner.tourPlanners[tour.id], let stage = tourPlanner.stages.first else {
                continue
            }
            pages.append(Page(title: "Unterkunftstour \(index + 1): \(stage.end.name)",
                              filename: "rundtour-\(index + 1).html", stage: stage,
                              details: tourPlanner.details, mode: tourPlanner.mode(for: stage)))
        }
        let snapshot = pages
        try await Task.detached {
            try write(trip: trip, pages: snapshot, photoStore: photoStore, to: destination)
        }.value
    }

    private static func write(trip: RoadTrip, pages: [Page], photoStore: TripPhotoStore,
                              to destination: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw TripExchangeError.invalid("Der Ausgabeordner existiert bereits.")
        }
        let temp = try TemporaryExportDirectory.create(in: destination.deletingLastPathComponent(), prefix: "html")
        do {
            let media = temp.appendingPathComponent("media", isDirectory: true)
            try manager.createDirectory(at: media, withIntermediateDirectories: false)
            var availablePhotos: Set<UUID> = []
            for photo in trip.photos {
                let source = photoStore.photoURL(photo, tripID: trip.id)
                guard manager.fileExists(atPath: source.path) else { continue }
                try writeSanitizedImage(from: source, to: media.appendingPathComponent("\(photo.id.uuidString).png"))
                availablePhotos.insert(photo.id)
            }
            let links = pages.map { "<li><a href=\"\($0.filename)\">\(escape($0.title))</a></li>" }.joined()
            let summary = "<h1>\(escape(trip.name))</h1><p>\(escape(trip.notes))</p>"
                + "<h2>Etappen und Unterkunftstouren</h2><ul>\(links)</ul>"
                + (pages.isEmpty ? "<p>Für diese Reise sind noch keine vollständigen Etappen vorhanden.</p>" : "")
                + "<h2>Fotos</h2>" + photosHTML(trip.photos, available: availablePhotos)
            try document(title: trip.name, content: summary).write(
                to: temp.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            for page in pages {
                let ids = Set(page.stage.waypoints.map(\.id))
                let photos = trip.photos.filter { photo in
                    switch photo.assignment?.target {
                    case .waypoint(let id), .stage(let id): ids.contains(id)
                    case .routeSegment(let from, let to): ids.contains(from) && ids.contains(to)
                    case nil: false
                    }
                }
                let stops = page.stage.waypoints.map { stop in
                    let details = page.details[stop.id] ?? WaypointDetails()
                    return "<li><strong>\(escape(stop.name))</strong> \(escape(stop.subtitle))"
                        + "<p>\(escape(details.notes))</p><p>Status: \(escape(details.status.title))"
                        + " · Aufenthalt: \(details.stayMinutes) min · Bewertung: \(details.rating)/5</p></li>"
                }.joined()
                let body = "<p><a href=\"index.html\">Zur Reiseübersicht</a></p><h1>\(escape(page.title))</h1>"
                    + "<p>Modus: \(escape(page.mode.title))"
                    + (page.stage.budgetMinutes.map { " · Budget: \(DurationInputFormat.string($0))" } ?? "")
                    + "</p>"
                    + mapHTML(page.stage) + "<ol>\(stops)</ol><h2>Fotos</h2>"
                    + photosHTML(photos, available: availablePhotos)
                try document(title: page.title, content: body).write(
                    to: temp.appendingPathComponent(page.filename), atomically: true, encoding: .utf8)
            }
            try stylesheet.write(to: temp.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
            try manager.moveItem(at: temp, to: destination)
        } catch {
            do { try manager.removeItem(at: temp) }
            catch let cleanup { throw TripExchangeError.rollback(cleanup.localizedDescription) }
            throw error
        }
    }

    private static func writeSanitizedImage(from sourceURL: URL, to destinationURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            throw TripPhotoError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TripPhotoError.invalidImage }
    }

    private static func photosHTML(_ photos: [TripPhoto], available: Set<UUID>) -> String {
        photos.map { photo in
            let caption = escape(photo.caption.isEmpty ? photo.originalName : photo.caption)
            guard available.contains(photo.id) else { return "<p>Foto fehlt: \(caption)</p>" }
            return "<figure><img src=\"media/\(photo.id.uuidString).png\" alt=\"\(caption)\""
                + " style=\"transform:rotate(\(photo.rotationQuarterTurns * 90)deg)\"><figcaption>\(caption)</figcaption></figure>"
        }.joined()
    }

    private static func mapHTML(_ stage: TripStage) -> String {
        let route = stage.legs?.flatMap(\.coordinates) ?? []
        let points = stage.waypoints.map(\.coordinate) + route
        guard points.allSatisfy({ CLLocationCoordinate2DIsValid($0) }), !points.isEmpty else {
            return "<p>Keine Routendarstellung verfügbar.</p>"
        }
        let minLat = points.map(\.latitude).min()!, maxLat = points.map(\.latitude).max()!
        let minLon = points.map(\.longitude).min()!, maxLon = points.map(\.longitude).max()!
        func xy(_ p: CLLocationCoordinate2D) -> String {
            let x = 25 + 750 * (p.longitude - minLon) / max(maxLon - minLon, 0.00001)
            let y = 375 - 350 * (p.latitude - minLat) / max(maxLat - minLat, 0.00001)
            return String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), x, y)
        }
        var lines = ""
        for index in 0..<(stage.waypoints.count - 1) {
            let start = stage.waypoints[index].coordinate, end = stage.waypoints[index + 1].coordinate
            let leg = stage.legs.map { $0[index] }
            let coordinates = [start] + (leg?.coordinates ?? []) + [end]
            let dashed = leg == nil || leg?.isTransit == true
            lines += "<polyline points=\"\(coordinates.map(xy).joined(separator: " "))\""
                + " fill=\"none\" stroke=\"#2364b4\" stroke-width=\"3\"\(dashed ? " stroke-dasharray=\"6 5\"" : "")/>"
        }
        let circles = stage.waypoints.map { point -> String in
            let coords = xy(point.coordinate).split(separator: ",")
            return "<circle cx=\"\(coords[0])\" cy=\"\(coords[1])\" r=\"5\" fill=\"#d35400\"/>"
        }.joined()
        return "<svg viewBox=\"0 0 800 400\" role=\"img\" aria-label=\"Schematische Routendarstellung\">"
            + "<rect width=\"800\" height=\"400\" fill=\"#eef2f5\"/>\(lines)\(circles)</svg>"
            + "<p>Routenskizze ohne Kartenhintergrund. Gestrichelte Abschnitte zeigen Luftlinien oder ÖPNV.</p>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func document(title: String, content: String) -> String {
        "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
            + "<title>\(escape(title))</title><link rel=\"stylesheet\" href=\"style.css\"></head><body>"
            + "<main>\(content)</main></body></html>"
    }

    private static let stylesheet = """
    body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f4f6f8;color:#20242a;margin:0}
    main{max-width:900px;margin:auto;padding:2rem}p{white-space:pre-wrap}svg{width:100%;height:auto}
    figure{display:inline-block;vertical-align:top;margin:1rem}img{max-width:240px;max-height:180px}
    a{color:#145aa0}li{margin:.5rem 0}
    """
}
