import AppKit
import ImageIO
import MapKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct PhotoAssignmentChoice: Identifiable {
    let target: PhotoAssignmentTarget
    let title: String

    var id: PhotoAssignmentTarget { target }
}

private struct PhotoPopoverSelection: Equatable {
    enum Anchor: Equatable {
        case list
        case map
    }

    let photoID: TripPhoto.ID
    let anchor: Anchor
}

struct TripPhotoLibraryView: View {
    @ObservedObject var library: TripLibrary
    @ObservedObject var model: TripPlannerViewModel
    let tripID: RoadTrip.ID

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var photoToDelete: TripPhoto?
    @State private var photoMapPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoID: TripPhoto.ID?
    @State private var presentedPhoto: PhotoPopoverSelection?
    @State private var pendingTransitChange: (() -> Void)?

    private var trip: RoadTrip? {
        library.trips.first { $0.id == tripID }
    }

    private var assignmentChoices: [PhotoAssignmentChoice] {
        let contexts: [(String, TripPlannerViewModel)] = [("Hauptreise", model)] + model.lodgingTours.enumerated().compactMap { index, tour in
            guard let planner = model.tourPlanners[tour.id],
                  let anchor = model.orderedWaypoints.first(where: { $0.id == tour.anchorID }) else { return nil }
            let number = model.lodgingTours.prefix(index).filter { $0.anchorID == tour.anchorID }.count + 1
            return ("Rundtour \(number) ab \(anchor.name)", planner)
        }
        return contexts.flatMap { label, planner in
            let waypoints = planner.orderedWaypoints.map {
                PhotoAssignmentChoice(target: .waypoint($0.id), title: "\(label) · Ort: \($0.name)")
            }
            let stages = planner.stages.map {
                PhotoAssignmentChoice(target: .stage($0.id), title: "\(label) · Etappe: \($0.waypoints.first?.name ?? $0.end.name) – \($0.end.name)")
            }
            let segments = zip(planner.orderedWaypoints, planner.orderedWaypoints.dropFirst()).map { from, to in
                PhotoAssignmentChoice(target: .routeSegment(from: from.id, to: to.id),
                                      title: "\(label) · Strecke: \(from.name) – \(to.name)")
            }
            return waypoints + stages + segments
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fotos")
                        .font(.title2.bold())
                    Text(trip?.name ?? "Reise nicht verfügbar")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PhotosPicker(selection: $selectedPhotos, matching: .images, photoLibrary: .shared()) {
                    Label("Aus Fotos wählen", systemImage: "photo.on.rectangle")
                }
                .disabled(isImporting || trip == nil)
                .accessibilityIdentifier("photo-library-import")
                Button("Dateien auswählen", systemImage: "folder") {
                    showFileImporter = true
                }
                .disabled(isImporting || trip == nil)
                .accessibilityIdentifier("photo-files-import")
                Button("Fertig") { dismiss() }
                    .disabled(isImporting)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            if isImporting {
                ProgressView("Fotos werden lokal kopiert …")
                    .padding(.bottom)
            }

            if let trip {
                if trip.photos.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Fotos",
                        systemImage: "photo",
                        description: Text("Wähle Bilder aus der Fotos-Mediathek oder Dateien aus.")
                    )
                    .accessibilityIdentifier("empty-photo-library")
                } else {
                    HStack(spacing: 0) {
                        List {
                            ForEach(trip.photos) { photo in
                                photoRow(photo)
                            }
                        }
                        .listStyle(.plain)
                        .accessibilityIdentifier("trip-photo-list")
                        .frame(minWidth: 420, idealWidth: 520)

                        Divider()

                        photoMap(for: trip)
                            .frame(minWidth: 400)
                    }
                }
            } else {
                ContentUnavailableView("Reise nicht verfügbar", systemImage: "exclamationmark.triangle")
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Importierte Bilder werden als lokale Kopien gespeichert; Originaldateien bleiben unverändert.")
                Text("GPS- und Aufnahmezeitdaten werden lokal verarbeitet. Foto-Orte, die als Wegpunkte dienen, werden bei der Routenberechnung an Apple übertragen.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
        .modifier(TransitChangeConfirmation(action: $pendingTransitChange))
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Foto konnte nicht verarbeitet werden", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Foto löschen?", isPresented: Binding(
            get: { photoToDelete != nil },
            set: { if !$0 { photoToDelete = nil } }
        ), presenting: photoToDelete) { photo in
            Button("Löschen", role: .destructive) {
                do {
                    try library.deletePhoto(photo.id, tripID: tripID)
                } catch {
                    errorMessage = error.localizedDescription
                }
                photoToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { photoToDelete = nil }
        } message: { photo in
            Text("„\(photo.originalName)“ wird aus dieser Reise und dem lokalen Medienspeicher entfernt.")
        }
    }

    private func photoRow(_ photo: TripPhoto) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                presentedPhoto = PhotoPopoverSelection(photoID: photo.id, anchor: .list)
            } label: {
                TripPhotoThumbnail(url: library.photoURL(for: photo, tripID: tripID),
                                   rotationQuarterTurns: photo.rotationQuarterTurns)
                    .frame(width: 112, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Foto öffnen: \(photo.caption.isEmpty ? photo.originalName : photo.caption)")
            .accessibilityIdentifier("open-photo-detail-\(photo.id.uuidString)")
            .popover(isPresented: photoPopoverBinding(for: photo.id, anchor: .list), arrowEdge: .trailing) {
                TripPhotoDetailPopover(library: library, model: model,
                                       tripID: tripID, photoID: photo.id) {
                    presentedPhoto = nil
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Bildbeschreibung", text: captionBinding(for: photo))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("photo-caption-\(photo.id.uuidString)")
                Text(photo.originalName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let capturedAt = photo.capturedAt {
                    LabeledContent("Aufgenommen") {
                        Text(capturedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                }
                if let coordinate = photo.coordinate {
                    HStack(spacing: 8) {
                        Text("GPS: \(coordinate.latitude.formatted(.number.precision(.fractionLength(4)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(4))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("photo-location-\(photo.id.uuidString)")
                        Button("Auf Karte zeigen", systemImage: "scope") {
                            focusMap(on: coordinate.coordinate, photoID: photo.id)
                        }
                        .labelStyle(.iconOnly)
                        .help("Foto-Ort auf der Karte anzeigen")
                        .accessibilityIdentifier("show-photo-on-map-\(photo.id.uuidString)")
                        if model.lodgingTours.isEmpty {
                            Button("Als Wegpunkt hinzufügen", systemImage: "mappin.and.ellipse") {
                                addPhotoLocationAsWaypoint(photo)
                            }
                            .labelStyle(.iconOnly)
                            .help(model.hasEndpoints ? "Foto-Ort als Wegpunkt hinzufügen" : "Lege zuerst Start und Ziel der Reise fest")
                            .disabled(!model.hasEndpoints)
                            .accessibilityIdentifier("add-photo-waypoint-\(photo.id.uuidString)")
                        } else {
                            Menu("Als Wegpunkt hinzufügen", systemImage: "mappin.and.ellipse") {
                                Button("Hauptreise") { addPhotoLocationAsWaypoint(photo) }
                                ForEach(Array(model.lodgingTours.enumerated()), id: \.element.id) { index, tour in
                                    if let anchor = model.orderedWaypoints.first(where: { $0.id == tour.anchorID }) {
                                        let number = model.lodgingTours.prefix(index).filter { $0.anchorID == tour.anchorID }.count + 1
                                        Button("Rundtour \(number) ab \(anchor.name)") {
                                            addPhotoLocationAsWaypoint(photo, tourID: tour.id)
                                        }
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityIdentifier("add-photo-waypoint-\(photo.id.uuidString)")
                        }
                    }
                }
                assignmentEditor(for: photo)
            }

            Spacer(minLength: 8)
            Button("Foto löschen", systemImage: "trash", role: .destructive) {
                photoToDelete = photo
            }
            .labelStyle(.iconOnly)
            .help("Foto aus der Reise entfernen")
            .accessibilityIdentifier("delete-photo-\(photo.id.uuidString)")
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("photo-row-\(photo.id.uuidString)")
    }

    private func photoMap(for trip: RoadTrip) -> some View {
        Map(position: $photoMapPosition) {
            ForEach(model.orderedWaypoints) { waypoint in
                Marker(waypoint.name, coordinate: waypoint.coordinate)
                    .tint(.blue)
            }
            ForEach(model.lodgingTours) { tour in
                if let planner = model.tourPlanners[tour.id] {
                    ForEach(planner.stops) { waypoint in
                        Marker("Rundtour: \(waypoint.name)", coordinate: waypoint.coordinate)
                            .tint(.orange)
                    }
                }
            }
            ForEach(trip.photos) { photo in
                if let coordinate = photo.coordinate {
                    Annotation(photo.caption.isEmpty ? photo.originalName : photo.caption,
                               coordinate: coordinate.coordinate, anchor: .bottom) {
                        Button {
                            focusMap(on: coordinate.coordinate, photoID: photo.id)
                            presentedPhoto = PhotoPopoverSelection(photoID: photo.id, anchor: .map)
                        } label: {
                            TripPhotoThumbnail(url: library.photoURL(for: photo, tripID: tripID),
                                               rotationQuarterTurns: photo.rotationQuarterTurns)
                                .frame(width: 46, height: 46)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().stroke(selectedPhotoID == photo.id ? .blue : .white, lineWidth: 3)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Foto auf der Karte: \(photo.caption.isEmpty ? photo.originalName : photo.caption)")
                        .accessibilityIdentifier("photo-map-marker-\(photo.id.uuidString)")
                        .popover(isPresented: photoPopoverBinding(for: photo.id, anchor: .map), arrowEdge: .trailing) {
                            TripPhotoDetailPopover(library: library, model: model,
                                                   tripID: tripID, photoID: photo.id) {
                                presentedPhoto = nil
                                if selectedPhotoID == photo.id { selectedPhotoID = nil }
                            }
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .accessibilityIdentifier("photo-map")
        .overlay(alignment: .topLeading) {
            if !trip.photos.contains(where: { $0.coordinate != nil }) {
                Label("Keine Fotos mit GPS-Daten", systemImage: "location.slash")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
        }
    }

    private func focusMap(on coordinate: CLLocationCoordinate2D, photoID: TripPhoto.ID) {
        selectedPhotoID = photoID
        photoMapPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        )
    }

    private func photoPopoverBinding(for photoID: TripPhoto.ID,
                                     anchor: PhotoPopoverSelection.Anchor) -> Binding<Bool> {
        let selection = PhotoPopoverSelection(photoID: photoID, anchor: anchor)
        return Binding {
            presentedPhoto == selection
        } set: { isPresented in
            if isPresented {
                presentedPhoto = selection
            } else if presentedPhoto == selection {
                presentedPhoto = nil
            }
        }
    }

    private func addPhotoLocationAsWaypoint(_ photo: TripPhoto, tourID: UUID? = nil, confirmed: Bool = false) {
        let target = tourID.flatMap { model.tourPlanners[$0] } ?? model
        if !confirmed && !target.transitLegs.isEmpty {
            pendingTransitChange = { addPhotoLocationAsWaypoint(photo, tourID: tourID, confirmed: true) }
            return
        }
        do {
            try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID, tourID: tourID)
            if let coordinate = photo.coordinate { focusMap(on: coordinate.coordinate, photoID: photo.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func assignmentEditor(for photo: TripPhoto) -> some View {
        if let assignment = photo.assignment,
           !assignmentChoices.contains(where: { $0.target == assignment.target }) {
            Text("Zuordnung nicht mehr verfügbar – bitte überprüfen.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let assignment = photo.assignment, assignment.status == .suggested {
            HStack {
                Text("Vorschlag: \(assignmentTitle(assignment.target))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Übernehmen") {
                    do {
                        try library.confirmPhotoSuggestion(photoID: photo.id, tripID: tripID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("confirm-photo-assignment-\(photo.id.uuidString)")
            }
        }

        Picker("Zuordnung", selection: assignmentBinding(for: photo)) {
            Text("Nicht zugeordnet").tag(nil as PhotoAssignmentTarget?)
            if let assignment = photo.assignment,
               !assignmentChoices.contains(where: { $0.target == assignment.target }) {
                Text("Nicht mehr verfügbar: \(assignmentTitle(assignment.target))").tag(Optional(assignment.target))
            }
            ForEach(assignmentChoices) { choice in
                Text(choice.title).tag(Optional(choice.target))
            }
        }
        .accessibilityIdentifier("photo-assignment-\(photo.id.uuidString)")
    }

    private func captionBinding(for photo: TripPhoto) -> Binding<String> {
        Binding {
            trip?.photos.first { $0.id == photo.id }?.caption ?? photo.caption
        } set: { caption in
            do {
                try library.updatePhotoCaption(caption, photoID: photo.id, tripID: tripID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func assignmentBinding(for photo: TripPhoto) -> Binding<PhotoAssignmentTarget?> {
        Binding {
            trip?.photos.first { $0.id == photo.id }?.assignment?.target
        } set: { target in
            do {
                try library.updatePhotoAssignment(target, photoID: photo.id, tripID: tripID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func assignmentTitle(_ target: PhotoAssignmentTarget) -> String {
        if let choice = assignmentChoices.first(where: { $0.target == target }) { return choice.title }
        switch target {
        case .waypoint(let id):
            return model.orderedWaypoints.first { $0.id == id }.map { "Ort: \($0.name)" } ?? "Entfernter Wegpunkt"
        case .stage(let id):
            guard let stage = model.stages.first(where: { $0.id == id }) else { return "Entfernte Etappe" }
            return "Etappe: \(stage.waypoints.first?.name ?? stage.end.name) – \(stage.end.name)"
        case .routeSegment(let fromID, let toID):
            let from = model.orderedWaypoints.first { $0.id == fromID }?.name ?? "Entfernter Ort"
            let to = model.orderedWaypoints.first { $0.id == toID }?.name ?? "Entfernter Ort"
            return "Strecke: \(from) – \(to)"
        }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer {
            isImporting = false
            selectedPhotos = []
        }
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw TripPhotoError.invalidImage
                }
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "img"
                try await library.addPhoto(data: data, originalName: "Foto \(index + 1).\(fileExtension)",
                                           tripID: tripID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    @MainActor
    private func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    return try Data(contentsOf: url)
                }.value
                try await library.addPhoto(data: data, originalName: url.lastPathComponent, tripID: tripID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}

struct TripPhotoThumbnail: View {
    let url: URL
    let rotationQuarterTurns: Int

    init(url: URL, rotationQuarterTurns: Int = 0) {
        self.url = url
        self.rotationQuarterTurns = rotationQuarterTurns
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = thumbnail {
                let isQuarterTurn = rotationQuarterTurns % 2 != 0
                let imageWidth = isQuarterTurn ? geometry.size.height : geometry.size.width
                let imageHeight = isQuarterTurn ? geometry.size.width : geometry.size.height
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageWidth, height: imageHeight)
                    .rotationEffect(.degrees(Double(rotationQuarterTurns * 90)))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ContentUnavailableView("Bild nicht verfügbar", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
            }
        }
        .background(.quaternary)
    }

    private var thumbnail: NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct TripPhotoDetailPopover: View {
    @ObservedObject var library: TripLibrary
    @ObservedObject var model: TripPlannerViewModel
    let tripID: RoadTrip.ID
    let photoID: TripPhoto.ID
    let onDeleted: () -> Void

    @State private var errorMessage: String?
    @State private var waypointMessage: String?
    @State private var isPreviewHovered = false
    @State private var showDeleteConfirmation = false
    @State private var isDeletingPhoto = false
    @State private var pendingTransitChange: (() -> Void)?

    private var photo: TripPhoto? {
        library.trips.first { $0.id == tripID }?.photos.first { $0.id == photoID }
    }

    var body: some View {
        Group {
            if let photo {
                photoContent(photo)
            } else {
                ContentUnavailableView("Foto nicht verfügbar", systemImage: "photo.badge.exclamationmark")
                    .frame(width: 620, height: 560)
            }
        }
        .modifier(TransitChangeConfirmation(action: $pendingTransitChange))
        .alert("Foto konnte nicht aktualisiert werden", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func photoContent(_ photo: TripPhoto) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(photo.caption.isEmpty ? photo.originalName : photo.caption)
                .font(.headline)
                .lineLimit(1)

            TripPhotoPreview(url: library.photoURL(for: photo, tripID: tripID),
                             rotationQuarterTurns: photo.rotationQuarterTurns)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if isPreviewHovered {
                        rotateButton(photo, clockwise: false)
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isPreviewHovered {
                        rotateButton(photo, clockwise: true)
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .onHover { isHovered in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isPreviewHovered = isHovered
                    }
                }
                .accessibilityIdentifier("photo-detail-preview-\(photo.id.uuidString)")

            TextField("Bildbeschreibung", text: captionBinding(for: photo))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("photo-detail-caption-\(photo.id.uuidString)")

            if let coordinate = photo.coordinate {
                HStack {
                    Text("GPS: \(coordinate.latitude.formatted(.number.precision(.fractionLength(4)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(4))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model === library.planner && !model.lodgingTours.isEmpty {
                        Menu("Als Wegpunkt hinzufügen", systemImage: "mappin.and.ellipse") {
                            Button("Hauptreise") { addPhotoLocationAsWaypoint(photo) }
                            ForEach(Array(model.lodgingTours.enumerated()), id: \.element.id) { index, tour in
                                if let anchor = model.orderedWaypoints.first(where: { $0.id == tour.anchorID }) {
                                    let number = model.lodgingTours.prefix(index).filter { $0.anchorID == tour.anchorID }.count + 1
                                    Button("Rundtour \(number) ab \(anchor.name)") {
                                        addPhotoLocationAsWaypoint(photo, tourID: tour.id)
                                    }
                                }
                            }
                        }
                    } else {
                        Button("Als Wegpunkt hinzufügen", systemImage: "mappin.and.ellipse") {
                            let tourID = library.planner.tourPlanners.first { $0.value === model }?.key
                            addPhotoLocationAsWaypoint(photo, tourID: tourID)
                        }
                        .disabled(!model.hasEndpoints)
                        .help(model.hasEndpoints ? "Foto-Ort als Wegpunkt hinzufügen" : "Lege zuerst Start und Ziel der Reise fest")
                        .accessibilityIdentifier("photo-detail-add-waypoint-\(photo.id.uuidString)")
                    }
                }
            }

            if let waypointMessage {
                Text(waypointMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Foto löschen", systemImage: "trash", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .accessibilityIdentifier("photo-detail-delete-\(photo.id.uuidString)")
            }
        }
        .padding()
        .frame(width: 620, height: 680)
        .confirmationDialog("Foto löschen?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                delete(photo)
            }
            .accessibilityIdentifier("confirm-delete-photo-\(photo.id.uuidString)")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("„\(photo.originalName)“ wird aus dieser Reise und dem lokalen Medienspeicher entfernt.")
        }
    }

    private func rotateButton(_ photo: TripPhoto, clockwise: Bool) -> some View {
        Button {
            rotate(photo, clockwise: clockwise)
        } label: {
            Image(systemName: clockwise ? "rotate.right" : "rotate.left")
                .font(.title3.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clockwise ? "Im Uhrzeigersinn drehen" : "Gegen den Uhrzeigersinn drehen")
        .accessibilityIdentifier(clockwise
                                 ? "rotate-photo-clockwise-\(photo.id.uuidString)"
                                 : "rotate-photo-counterclockwise-\(photo.id.uuidString)")
    }

    private func captionBinding(for photo: TripPhoto) -> Binding<String> {
        Binding {
            self.photo?.caption ?? photo.caption
        } set: { caption in
            guard !isDeletingPhoto, self.photo != nil else { return }
            do {
                try library.updatePhotoCaption(caption, photoID: photo.id, tripID: tripID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rotate(_ photo: TripPhoto, clockwise: Bool) {
        do {
            try library.rotatePhoto(photoID: photo.id, tripID: tripID, clockwise: clockwise)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addPhotoLocationAsWaypoint(_ photo: TripPhoto, tourID: UUID? = nil, confirmed: Bool = false) {
        let target = tourID.flatMap { library.planner.tourPlanners[$0] } ?? library.planner
        if !confirmed && !target.transitLegs.isEmpty {
            pendingTransitChange = { addPhotoLocationAsWaypoint(photo, tourID: tourID, confirmed: true) }
            return
        }
        do {
            let waypoint = try library.addPhotoLocationAsWaypoint(photoID: photo.id, tripID: tripID, tourID: tourID)
            waypointMessage = "Dem Wegpunkt „\(waypoint.name)“ zugeordnet."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ photo: TripPhoto) {
        isDeletingPhoto = true
        do {
            try library.deletePhoto(photo.id, tripID: tripID)
            onDeleted()
        } catch {
            isDeletingPhoto = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct TripPhotoPreview: View {
    let url: URL
    let rotationQuarterTurns: Int

    var body: some View {
        GeometryReader { geometry in
            if let image {
                let isQuarterTurn = rotationQuarterTurns % 2 != 0
                let imageWidth = isQuarterTurn ? geometry.size.height : geometry.size.width
                let imageHeight = isQuarterTurn ? geometry.size.width : geometry.size.height
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageWidth, height: imageHeight)
                    .rotationEffect(.degrees(Double(rotationQuarterTurns * 90)))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ContentUnavailableView("Bild nicht verfügbar", systemImage: "photo.badge.exclamationmark")
            }
        }
        .background(.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var image: NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
