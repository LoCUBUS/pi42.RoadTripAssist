import AppKit
import CoreLocation
import MapKit
import SwiftUI

struct TripPlannerView: View {
    @StateObject private var library: TripLibrary
    private let showMap: Bool
    private let launchMaps: (MKMapItem, [String: Any]) -> Bool
    private let fixturePOI: MapPointOfInterest?

    @MainActor
    init() {
        let openInAppleMaps: (MKMapItem, [String: Any]) -> Bool = { $0.openInMaps(launchOptions: $1) }
        #if UI_TEST_SUPPORT
        if let fixture = PlannerUITestFixture.requested {
            _library = StateObject(wrappedValue: fixture.makeLibrary())
            fixturePOI = ProcessInfo.processInfo.arguments.contains("--ui-testing-poi") ? fixture.mapPOI : nil
            showMap = fixturePOI != nil || ProcessInfo.processInfo.arguments.contains("--ui-testing-budget-placeholder")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing-optimization")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing-photo")
            launchMaps = ProcessInfo.processInfo.arguments.contains("--ui-testing-open-maps")
                ? openInAppleMaps : fixture.recordMapsHandoff
            return
        }
        #endif
        _library = StateObject(wrappedValue: TripLibrary())
        showMap = true
        fixturePOI = nil
        launchMaps = openInAppleMaps
    }

    var body: some View {
        TripWorkspaceView(library: library, model: library.planner, showMap: showMap,
                          launchMaps: launchMaps, fixturePOI: fixturePOI)
            #if UI_TEST_SUPPORT
            .onAppear {
                if PlannerUITestFixture.requested != nil
                    && ProcessInfo.processInfo.arguments.contains("--ui-testing-main-display") {
                    DispatchQueue.main.async {
                        guard let window = NSApp.windows.first(where: \.isVisible),
                              let screen = NSScreen.screens.first else {
                            NSLog("Could not position the UI test window on the main display.")
                            return
                        }
                        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 30,
                                                      y: screen.visibleFrame.maxY - window.frame.height - 30))
                    }
                }
            }
            #endif
    }
}

private struct TripWorkspaceView: View {
    private static let overnightSearchRadius: CLLocationDistance = 2_500
    private static let photoWaypointOverlapDistance: CLLocationDistance = 25

    @ObservedObject var library: TripLibrary
    @ObservedObject var model: TripPlannerViewModel
    let showMap: Bool
    let launchMaps: (MKMapItem, [String: Any]) -> Bool
    let fixturePOI: MapPointOfInterest?
    @FocusState private var focusedWaypoint: WaypointField?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapPOILookup: MapPOILookup?
    @State private var selectedPOI: MapPointOfInterest?
    @State private var mapPOIMessage: String?
    @State private var showRoutingConfirmation = false
    @State private var showRoutingDiagnostics = false
    @State private var showMapsError = false
    @State private var editor: TripEditorDraft?
    @State private var tripToDelete: RoadTrip?
    @State private var showStages = false
    @State private var mapStageID: RoadStop.ID?
    @State private var mapTourID: UUID?
    @State private var showSuggestionOnMap = false
    @State private var showAlternativeConnections = false
    @State private var selectedAlternativeConnection: RouteConnection.ID?
    @State private var showAlternativePopover = false
    @State private var showSuggestionPopover = false
    @State private var showTransitSuggestionConfirmation = false
    @State private var pendingTransitChange: (() -> Void)?
    @State private var transitChangeMessage = ""
    @State private var waypointEditor: WaypointEditorDraft?
    @State private var tourEditor: WaypointEditorDraft?
    @State private var pendingWaypointAction: WaypointEditorAction?
    @State private var showDiscardWaypointChanges = false
    @State private var showDefaultBudget = false
    @State private var showPhotoLibrary = false
    @State private var presentedMapPhotoID: TripPhoto.ID?
    @State private var overrunStage: TripStage?
    @State private var stageStopToRemove: RoadStop?
    @State private var showRouteInspector = true
    @State private var showExchangePrivacy = false
    @State private var exportError: String?
    @State private var transferInProgress = false

    private var mapStage: TripStage? {
        guard let mapStageID else { return nil }
        return model.stages.first { $0.id == mapStageID }
    }

    private var activeMapModel: TripPlannerViewModel {
        mapTourID.flatMap { model.tourPlanners[$0] } ?? model
    }

    private var availableAlternativeConnections: [RouteConnection] {
        guard let stage = mapStage else { return model.alternativeConnections }
        let stageIDs = Set(stage.waypoints.map(\.id))
        return model.alternativeConnections.filter {
            stageIDs.contains($0.from.id) && stageIDs.contains($0.to.id)
        }
    }

    var body: some View {
        NavigationSplitView {
            tripSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                if showMap { mapView }
                else { Color.clear }
            }
            .overlay(alignment: .topTrailing) {
                if let selectedPOI { poiDetails(selectedPOI).padding(12) }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $showRouteInspector) {
                Group {
                    if library.selectedID != nil {
                        routeSidebar
                    } else {
                        ContentUnavailableView("Keine Reise ausgewählt", systemImage: "map",
                                               description: Text("Lege links eine Reise an, um eine Route zu planen."))
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 370, max: 440)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Route ein- oder ausblenden", systemImage: "sidebar.right") {
                        showRouteInspector.toggle()
                    }
                    .help("Routenplanung ein- oder ausblenden")
                    .accessibilityIdentifier("toggle-route-inspector")
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .disabled(transferInProgress)
        .overlay {
            if transferInProgress {
                ProgressView("Reise wird verarbeitet …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .modifier(TransitChangeConfirmation(action: $pendingTransitChange, message: transitChangeMessage))
        .onChange(of: library.selectedID) { _, _ in
            focusedWaypoint = nil
            clearMapPOI()
            showStages = false
            mapStageID = nil
            mapTourID = nil
            showSuggestionOnMap = false
            showAlternativeConnections = false
            selectedAlternativeConnection = nil
            presentedMapPhotoID = nil
            showAlternativePopover = false
            showSuggestionPopover = false
            waypointEditor = nil
            tourEditor = nil
            overrunStage = nil
            stageStopToRemove = nil
            if fixturePOI == nil { cameraPosition = .automatic }
        }
        .onChange(of: focusedWaypoint) { _, field in
            if let field { model.beginSearch(in: field) }
        }
        .onChange(of: model.orderedWaypoints.map(\.id)) { _, ids in
            if let waypointEditor, !ids.contains(waypointEditor.id) {
                self.waypointEditor = nil
            }
        }
        .onChange(of: model.suggestion != nil) { _, hasSuggestion in
            if !hasSuggestion {
                showSuggestionOnMap = false
                showSuggestionPopover = false
            }
        }
        .onChange(of: model.routeStatus) { _, status in
            if status == .finished || status == .idle { showRoutingDiagnostics = false }
        }
        .onChange(of: availableAlternativeConnections.map(\.id)) { _, ids in
            if let selectedAlternativeConnection, !ids.contains(selectedAlternativeConnection) {
                self.selectedAlternativeConnection = nil
            }
            if ids.isEmpty {
                showAlternativeConnections = false
                showAlternativePopover = false
            }
        }
        .sheet(item: $editor) { draft in
            TripEditorView(draft: draft) { name, notes, departureDate, isRoundTrip in
                library.updateTrip(id: draft.tripID, name: name, notes: notes, departureDate: departureDate,
                                   isRoundTrip: isRoundTrip)
                editor = nil
            }
        }
        .sheet(isPresented: $showDefaultBudget) {
            StageBudgetEditor(minutes: model.defaultStageBudgetMinutes) { minutes in
                model.setDefaultStageBudget(minutes)
                showDefaultBudget = false
            }
        }
        .sheet(isPresented: $showPhotoLibrary) {
            if let tripID = library.selectedID {
                TripPhotoLibraryView(library: library, model: model, tripID: tripID)
            }
        }
        .alert("Reise löschen?", isPresented: Binding(
            get: { tripToDelete != nil },
            set: { if !$0 { tripToDelete = nil } }
        ), presenting: tripToDelete) { trip in
            Button("Löschen", role: .destructive) { library.delete(trip.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { trip in
            if (waypointEditor?.hasChanges == true || tourEditor?.hasChanges == true) && trip.id == library.selectedID {
                Text("„\(trip.name)“ und ihre Wegpunkte werden gelöscht. Ungespeicherte Änderungen gehen verloren.")
            } else {
                Text("„\(trip.name)“ und ihre Wegpunkte werden von diesem Mac gelöscht.")
            }
        }
        .alert("Ungespeicherte Änderungen verwerfen?", isPresented: $showDiscardWaypointChanges) {
            Button("Verwerfen", role: .destructive) {
                if let action = pendingWaypointAction { performWaypointAction(action) }
                pendingWaypointAction = nil
            }
            Button("Weiter bearbeiten", role: .cancel) { pendingWaypointAction = nil }
        } message: {
            Text((waypointEditor ?? tourEditor)?.isStageBudget == true
                 ? "Das Etappenbudget wurde noch nicht gespeichert."
                 : "Die Änderungen an diesem Wegpunkt wurden noch nicht gespeichert.")
        }
        .alert("Reisezeit mit Apple MapKit berechnen?", isPresented: $showRoutingConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren") {
                model.enableAutomaticRouting()
            }
        } message: {
            Text("Nach Änderungen an den Wegpunkten berechnet MapKit die Route in der aktuellen Reihenfolge. ÖPNV-Abschnitte liefern nur eine Zeit- und Entfernungsschätzung. Die Optimierung startest du separat. Dabei werden Koordinaten und ein gegebenenfalls festgelegter Reisestart an Apple gesendet. Du kannst die Berechnung jederzeit pausieren.")
        }
        .alert("Apple Karten konnte nicht geöffnet werden", isPresented: $showMapsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Das Ziel konnte nicht an Apple Karten übergeben werden.")
        }
        .alert("Reise mit Originalfotos exportieren?", isPresented: $showExchangePrivacy) {
            Button("Abbrechen", role: .cancel) {}
            Button("Fortfahren") { exportExchange() }
        } message: {
            Text("Die unverschlüsselte Datei enthält Reiseorte, Notizen und originale Fotos einschließlich möglicher GPS- und EXIF-Daten.")
        }
        .alert("Import oder Export fehlgeschlagen", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("Zwischenziel entfernen?", isPresented: Binding(
            get: { stageStopToRemove != nil },
            set: { if !$0 { stageStopToRemove = nil } }
        ), presenting: stageStopToRemove) { stop in
            Button("Entfernen", role: .destructive) {
                if mapStageID == stop.id { showStageOnMap(nil) }
                model.removeStop(stop)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { stop in
            if !model.transitLegs.isEmpty {
                Text("„\(stop.name)“ wird entfernt. Nicht mehr benachbarte ÖPNV-Markierungen werden entfernt; bei Übernachtungen werden Etappen zusammengeführt. Ungespeicherte Änderungen gehen verloren.")
            } else if waypointEditor?.id == stop.id && waypointEditor?.hasChanges == true
                && model.waypointDetails(for: stop).overnight {
                Text("„\(stop.name)“ wird entfernt und die angrenzenden Etappen werden zusammengeführt. Ungespeicherte Änderungen gehen verloren.")
            } else if waypointEditor?.id == stop.id && waypointEditor?.hasChanges == true {
                Text("„\(stop.name)“ wird entfernt. Ungespeicherte Änderungen gehen verloren.")
            } else if model.waypointDetails(for: stop).overnight {
                Text("„\(stop.name)“ wird aus der Route entfernt. Die angrenzenden Etappen werden zusammengeführt.")
            } else {
                Text("„\(stop.name)“ wird aus der Route entfernt.")
            }
        }
        .alert("Zeitüberschreitung bestätigen?", isPresented: Binding(
            get: { overrunStage != nil },
            set: { if !$0 { overrunStage = nil } }
        ), presenting: overrunStage) { stage in
            Button("Budgetpunkt ausblenden") {
                if let overrun = stage.budgetOverrun {
                    model.acceptBudgetOverrun(overrun, endingAt: stage.end)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { stage in
            if let overrun = stage.budgetOverrun {
                Text("Du erreichst „\(stage.end.name)“ voraussichtlich \(DurationInputFormat.string(overrun.arrivalMinutes - overrun.budgetMinutes)) (hh:mm) nach dem Zeitbudget. Der Budgetpunkt und der Suchkreis werden ausgeblendet. Die Route bleibt unverändert.")
            }
        }
    }

    private var tripSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reisen")
                .font(.title2.bold())
            Button {
                requestWaypointAction(.newTrip)
            } label: {
                Label("Neue Reise", systemImage: "plus")
            }
            .accessibilityIdentifier("new-trip")
            .disabled(library.loadError != nil)
            Button("Reise importieren …", systemImage: "square.and.arrow.down") {
                requestWaypointAction(.importTrip)
            }
            .accessibilityIdentifier("import-trip")
            .disabled(library.loadError != nil)

            if let error = library.loadError {
                Text("Reisen konnten nicht geladen werden: \(error)")
                    .foregroundStyle(.red)
                Button("Erneut laden", action: library.retryLoad)
            } else if library.trips.isEmpty {
                Text("Noch keine Reisen angelegt.")
                    .foregroundStyle(.secondary)
            } else {
                List(selection: Binding(
                    get: { library.selectedID },
                    set: { if let id = $0, id != library.selectedID { requestWaypointAction(.selectTrip(id)) } }
                )) {
                    ForEach(library.trips) { trip in
                        HStack {
                            Text(trip.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if trip.id == library.selectedID {
                                Menu {
                                    Button("Reisedatei …") { requestWaypointAction(.exportTrip) }
                                    Button("HTML-Reisetagebuch …") { requestWaypointAction(.exportHTML) }
                                } label: {
                                    Label("Reise exportieren", systemImage: "square.and.arrow.up")
                                }
                                .labelStyle(.iconOnly)
                                .menuStyle(.borderlessButton)
                                .help("Ausgewählte Reise exportieren")
                                .accessibilityIdentifier("export-trip")
                            }
                        }
                        .tag(trip.id)
                    }
                }
                .listStyle(.sidebar)
            }

            if let trip = library.selectedTrip {
                if let departureDate = trip.departureDate {
                    Label("Start: \(departureDate.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "calendar")
                        .font(.caption)
                        .accessibilityIdentifier("trip-departure-date")
                }
                if !trip.notes.isEmpty {
                    Text(trip.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                HStack {
                    Button("Bearbeiten") { requestWaypointAction(.editTrip(trip)) }
                    Button("Löschen", role: .destructive) { tripToDelete = trip }
                }
                Button("Fotos verwalten", systemImage: "photo.on.rectangle") {
                    showPhotoLibrary = true
                }
                .accessibilityIdentifier("manage-trip-photos")
            }
            if let error = library.saveError {
                Text("Änderungen sind noch nicht gespeichert: \(error)")
                    .foregroundStyle(.red)
                Button("Erneut speichern", action: library.save)
            }
            if let error = library.selectedTripSaveError {
                Text("Die letzte ausgewählte Route konnte nicht gespeichert werden: \(error)")
                    .foregroundStyle(.red)
                Button("Erneut versuchen", action: library.retrySelectedTripSave)
            }
            if let error = library.mediaCleanupError {
                Text("Lokale Fotos konnten nach dem Löschen der Reise nicht entfernt werden: \(error)")
                    .foregroundStyle(.red)
            }
            if library.trips.isEmpty { Spacer() }
        }
        .padding()
    }

    private var mapView: some View {
        let stage = mapStage
        let mapModel = mapTourID.flatMap { model.tourPlanners[$0] } ?? model
        let waypoints = mapWaypoints(stage?.waypoints ?? mapModel.orderedWaypoints)
        let trip = library.selectedTrip
        let photosByWaypoint = overlappingPhotosByWaypoint(waypoints: waypoints, photos: trip?.photos ?? [])
        let clusteredPhotoIDs = Set(photosByWaypoint.values.flatMap { $0.map(\.id) })
        let visibleStages = (showStages || mapTourID != nil) && !showSuggestionOnMap
            ? (stage.map { [$0] } ?? mapModel.stages) : []
        return MapReader { proxy in
            Map(position: $cameraPosition) {
                let route = showSuggestionOnMap ? mapModel.suggestion : mapModel.roadPreview
                let routeWaypoints = stage?.waypoints
                    ?? ([mapModel.start].compactMap { $0 } + (route?.orderedStops ?? []) + [mapModel.destination].compactMap { $0 })
                let routeLegs = stage?.legs ?? route?.legs ?? []
                ForEach(Array(routeLegs.enumerated()), id: \.offset) { index, leg in
                    if showSuggestionOnMap && leg.isTransit && index + 1 < routeWaypoints.count {
                        MapPolyline(coordinates: [routeWaypoints[index].coordinate, routeWaypoints[index + 1].coordinate])
                            .stroke(.blue, style: StrokeStyle(lineWidth: 4, dash: [2, 6]))
                    } else if !leg.isTransit && leg.coordinates.count >= 2 {
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(.blue, lineWidth: 4)
                    }
                }
                if !showSuggestionOnMap {
                    let ordered = stage?.waypoints ?? mapModel.orderedWaypoints
                    ForEach(Array(zip(ordered, ordered.dropFirst()).enumerated()), id: \.offset) { _, pair in
                        let (from, to) = pair
                        if mapModel.mode(from: from, to: to) == .walking && mapModel.isTransit(from: from, to: to) {
                            MapPolyline(coordinates: [from.coordinate, to.coordinate])
                                .stroke(.blue, style: StrokeStyle(lineWidth: 4, dash: [2, 6]))
                        }
                    }
                }
                if mapModel.roadPreview == nil && !showSuggestionOnMap {
                    let visibleIDs = Set((stage?.waypoints ?? mapModel.orderedWaypoints).map(\.id))
                    ForEach(mapModel.currentConnections.filter {
                        visibleIDs.contains($0.from.id) && visibleIDs.contains($0.to.id)
                    }) { connection in
                        if !connection.leg.isTransit && connection.leg.coordinates.count >= 2 {
                            MapPolyline(coordinates: connection.leg.coordinates)
                                .stroke(.blue, lineWidth: 4)
                        }
                    }
                }
                if mapTourID == nil && stage == nil && !showSuggestionOnMap {
                    ForEach(model.lodgingTours) { tour in
                        if let planner = model.tourPlanners[tour.id] {
                            ForEach(planner.currentConnections) { connection in
                                if !connection.leg.isTransit && connection.leg.coordinates.count >= 2 {
                                    MapPolyline(coordinates: connection.leg.coordinates)
                                        .stroke(.orange, lineWidth: 4)
                                }
                            }
                            ForEach(Array(zip(planner.orderedWaypoints, planner.orderedWaypoints.dropFirst()).enumerated()),
                                    id: \.offset) { _, pair in
                                let (from, to) = pair
                                if planner.mode(from: from, to: to) == .walking && planner.isTransit(from: from, to: to) {
                                    MapPolyline(coordinates: [from.coordinate, to.coordinate])
                                        .stroke(.orange, style: StrokeStyle(lineWidth: 4, dash: [2, 6]))
                                }
                            }
                            ForEach(planner.stops) { stop in
                                Marker("Rundtour: \(stop.name)", systemImage: "arrow.triangle.2.circlepath",
                                       coordinate: stop.coordinate)
                                    .tint(.orange)
                            }
                        }
                    }
                }
                if showAlternativeConnections {
                    ForEach(availableAlternativeConnections.filter {
                        selectedAlternativeConnection == nil || $0.id == selectedAlternativeConnection
                    }) { connection in
                        if connection.leg.isTransit {
                            MapPolyline(coordinates: [connection.from.coordinate, connection.to.coordinate])
                                .stroke(.purple, style: StrokeStyle(lineWidth: 4, dash: [2, 6]))
                        } else if connection.leg.coordinates.count >= 2 {
                            MapPolyline(coordinates: connection.leg.coordinates)
                                .stroke(.purple, style: StrokeStyle(lineWidth: 4, dash: [8, 6]))
                        }
                    }
                }
                ForEach(visibleStages) { stage in
                    if let placeholder = stage.budgetPlaceholder {
                        MapCircle(center: placeholder.coordinate, radius: Self.overnightSearchRadius)
                            .foregroundStyle(.clear)
                            .stroke(.orange, lineWidth: 3)
                        Marker("Übernachtung suchen", systemImage: "bed.double", coordinate: placeholder.coordinate)
                            .tint(.orange)
                    }
                }
                ForEach(waypoints) { stop in
                    let appearance = waypointAppearance(for: stop, in: mapModel)
                    Marker(stop.name, systemImage: appearance.systemImage, coordinate: stop.coordinate)
                        .tint(appearance.color)
                    if let trip, let photos = photosByWaypoint[stop.id], !photos.isEmpty {
                        Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                            WaypointPhotoOverlapAnnotation(
                                waypoint: stop,
                                photos: photos,
                                library: library,
                                model: mapModel,
                                tripID: trip.id,
                                presentedPhotoID: $presentedMapPhotoID
                            )
                        }
                    }
                }
                if let trip {
                    ForEach(trip.photos) { photo in
                        if let coordinate = photo.coordinate, !clusteredPhotoIDs.contains(photo.id) {
                            Annotation(photo.caption.isEmpty ? photo.originalName : photo.caption,
                                       coordinate: coordinate.coordinate, anchor: .bottom) {
                                Button {
                                    presentedMapPhotoID = photo.id
                                } label: {
                                    TripPhotoThumbnail(url: library.photoURL(for: photo, tripID: trip.id),
                                                       rotationQuarterTurns: photo.rotationQuarterTurns)
                                        .frame(width: 42, height: 42)
                                        .clipShape(Circle())
                                        .overlay { Circle().stroke(.white, lineWidth: 2) }
                                        .shadow(radius: 2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Foto auf der Karte: \(photo.caption.isEmpty ? photo.originalName : photo.caption)")
                                .accessibilityIdentifier("planner-photo-marker-\(photo.id.uuidString)")
                                .popover(isPresented: photoPopoverBinding(for: photo.id), arrowEdge: .trailing) {
                                    TripPhotoDetailPopover(library: library, model: mapModel,
                                                           tripID: trip.id, photoID: photo.id) {
                                        presentedMapPhotoID = nil
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(mapModel.searchResults.prefix(5)) { result in
                    Marker(result.name, coordinate: result.coordinate)
                        .tint(.orange)
                }
                ForEach(mapModel.parkingSuggestions) { parking in
                    Marker(parking.name, systemImage: "parkingsign.circle", coordinate: parking.coordinate)
                        .tint(.orange)
                }
                if let selectedPOI, !mapModel.hasMapPlace(selectedPOI.stop) {
                    Marker(selectedPOI.stop.name, systemImage: "mappin", coordinate: selectedPOI.stop.coordinate)
                        .tint(.blue)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .accessibilityIdentifier("planner-map")
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                clearMapPOI()
                guard let center = proxy.convert(tap.location, from: .local),
                      let nearby = proxy.convert(CGPoint(x: tap.location.x + 24, y: tap.location.y),
                                                 from: .local) else {
                    mapPOIMessage = "Dieser Kartenpunkt konnte nicht bestimmt werden."
                    return
                }
                let tolerance = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    .distance(from: CLLocation(latitude: nearby.latitude, longitude: nearby.longitude))
                guard let area = MapPOISearchArea(center: center, clickTolerance: tolerance) else {
                    mapPOIMessage = "Dieser Kartenpunkt konnte nicht bestimmt werden."
                    return
                }
                mapPOILookup = MapPOILookup(area: area)
                mapPOIMessage = "Ort wird gesucht …"
            })
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .onAppear {
            if let fixturePOI {
                cameraPosition = .region(MKCoordinateRegion(center: fixturePOI.stop.coordinate,
                                                             latitudinalMeters: 800, longitudinalMeters: 800))
            }
        }
        .task(id: mapPOILookup?.id) {
            guard let lookup = mapPOILookup else { return }
            do {
                let results: [MapPointOfInterest]
                if let fixturePOI { results = [fixturePOI] }
                else { results = try await model.nearbyPOIs(in: lookup.area) }
                try Task.checkCancellation()
                guard mapPOILookup?.id == lookup.id else { return }
                selectedPOI = lookup.area.nearestPOI(in: results)
                mapPOIMessage = selectedPOI == nil ? "Kein Ort an dieser Stelle gefunden." : nil
            } catch {
                if !Task.isCancelled, mapPOILookup?.id == lookup.id {
                    mapPOIMessage = "Ort konnte nicht geladen werden: \(error.localizedDescription)"
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = mapPOIMessage {
                Text(message)
                    .accessibilityIdentifier("map-poi-message")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if showSuggestionOnMap || showAlternativeConnections || mapTourID != nil || !model.lodgingTours.isEmpty {
                VStack(alignment: .leading) {
                    if mapTourID != nil {
                        Text("Karte: ausgewählte Rundtour")
                        Button("Hauptreise und Rundtouren") { showStageOnMap(nil) }
                    } else if !model.lodgingTours.isEmpty && mapStageID == nil {
                        Text("Karte: Hauptreise (blau) und Rundtouren (orange)")
                    }
                    if showSuggestionOnMap {
                        Text("Vorschlag – noch nicht übernommen")
                            .accessibilityIdentifier("map-suggestion-indicator")
                    }
                    if showAlternativeConnections {
                        Text("Alternative Verbindungen: lila gestrichelt")
                            .accessibilityIdentifier("map-alternatives-indicator")
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
                .allowsHitTesting(mapTourID != nil)
            }
        }
        .onChange(of: model.roadPreview != nil) { _, hasPreview in
            if hasPreview, !cameraPosition.positionedByUser, mapPOILookup == nil {
                cameraPosition = .automatic
            }
        }
    }

    private struct MapPOILookup {
        let id = UUID()
        let area: MapPOISearchArea
    }

    private func clearMapPOI() {
        mapPOILookup = nil
        selectedPOI = nil
        mapPOIMessage = nil
    }

    private func poiDetails(_ poi: MapPointOfInterest) -> some View {
        let alreadyInRoute = model.hasMapPlace(poi.stop)
        let canAdd = library.selectedID != nil && model.hasEndpoints && !alreadyInRoute
        let tours = model.lodgingTours.compactMap { tour -> (tour: LodgingTour, planner: TripPlannerViewModel, title: String)? in
            guard let planner = model.tourPlanners[tour.id],
                  let anchor = model.orderedWaypoints.first(where: { $0.id == tour.anchorID }),
                  let index = model.lodgingTours.filter({ $0.anchorID == tour.anchorID }).firstIndex(where: { $0.id == tour.id }) else {
                return nil
            }
            return (tour, planner, "Rundtour \(index + 1) ab \(anchor.name)")
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Ort in der Nähe des Klicks").foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(poi.stop.name)
                    .font(.headline)
                    .accessibilityIdentifier("map-poi-name")
                Spacer(minLength: 8)
                Button("Ortsdetails schließen", systemImage: "xmark.circle", action: clearMapPOI)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if !poi.stop.subtitle.isEmpty { Text(poi.stop.subtitle).accessibilityIdentifier("map-poi-address") }
            if let phone = poi.phoneNumber { Text(phone) }
            if let website = poi.website, let scheme = website.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                Link("Website", destination: website)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(tours.isEmpty ? "Zur Route hinzufügen" : "Zur Hauptreise hinzufügen", systemImage: "plus.circle") {
                    confirmTransitChange(planner: model) { model.addMapPOI(poi.stop.newOccurrence(), stageID: mapStageID) }
                }
                .accessibilityIdentifier("add-map-poi")
                .disabled(!canAdd)
                if tours.count == 1, let tour = tours.first {
                    Button("Zur Rundtour hinzufügen", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        confirmTransitChange(planner: tour.planner) { tour.planner.addMapPOI(poi.stop.newOccurrence()) }
                    }
                    .accessibilityIdentifier("add-map-poi-tour")
                    .disabled(library.selectedID == nil || !tour.planner.hasEndpoints || tour.planner.hasMapPlace(poi.stop))
                    Text(tour.planner.hasMapPlace(poi.stop) ? "\(tour.title) – bereits enthalten" : tour.title)
                        .font(.caption).foregroundStyle(.secondary)
                } else if !tours.isEmpty {
                    Menu("Zur Rundtour hinzufügen", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        ForEach(tours, id: \.tour.id) { tour in
                            let alreadyInTour = tour.planner.hasMapPlace(poi.stop)
                            Button(alreadyInTour ? "\(tour.title) – bereits enthalten" : tour.title) {
                                confirmTransitChange(planner: tour.planner) { tour.planner.addMapPOI(poi.stop.newOccurrence()) }
                            }
                            .disabled(library.selectedID == nil || !tour.planner.hasEndpoints || alreadyInTour)
                        }
                    }
                    .accessibilityIdentifier("add-map-poi-tour")
                }
                Button(tours.isEmpty ? "Als Übernachtung hinzufügen" : "Als Übernachtung zur Hauptreise hinzufügen", systemImage: "bed.double") {
                    confirmTransitChange(planner: model) { model.addMapPOI(poi.stop.newOccurrence(), asOvernight: true, stageID: mapStageID) }
                }
                .accessibilityIdentifier("add-map-poi-overnight")
                .disabled(!canAdd || model.isRoundTrip || (mapStage.map { model.isRoundTripStage($0) } ?? false))
                .help("In einer Rundtour kann keine zusätzliche Etappengrenze gesetzt werden.")
            }
            if alreadyInRoute {
                Text(tours.isEmpty ? "Bereits in der Route" : "Bereits in der Hauptreise").foregroundStyle(.secondary)
            } else if library.selectedID == nil || !model.hasEndpoints {
                Text("Wähle eine Reise mit Start und Ziel.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 255, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var routeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let trip = library.selectedTrip, !trip.migrationNotices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trip.migrationNotices, id: \.self) { notice in
                        Text(notice)
                    }
                    Button("Hinweis schließen") { library.dismissMigrationNotices(for: trip.id) }
                }
                .font(.caption)
                .padding(.horizontal)
                .accessibilityIdentifier("round-trip-migration-notice")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(showStages ? "Etappen & Reiseverlauf" : "Route planen")
                    .font(.title2.bold())
                Text("Ortssuche und Routing benötigen Internet. Suchtext, angeklickte Kartenpositionen und Wegpunkt-Koordinaten werden an Apple gesendet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Ansicht", selection: Binding(
                    get: { showStages },
                    set: { if $0 { showStages = true } else { requestWaypointAction(.showRoute) } }
                )) {
                    Text("Route").tag(false)
                    Text("Etappen").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("planner-mode")
                .onChange(of: showStages) { _, showStages in
                    if showStages { dismissWaypointSearch() }
                    else if mapStageID != nil { showStageOnMap(nil) }
                }
            }
            .padding(.horizontal)

            if showStages {
                stageList
            } else {
                waypointList
            }

            routingControls
        }
        .padding(.top)
    }

    private var waypointList: some View {
            List {
                if model.hasEndpoints {
                    Section("Routeneinstellungen") {
                        ForEach(Array(model.stages.enumerated()), id: \.offset) { index, stage in
                            Picker("\(model.isRoundTripStage(stage) ? "Rundtour" : "Etappe") \(index + 1)",
                                   selection: Binding(
                                    get: { model.mode(for: stage) },
                                    set: { model.setMode($0, for: stage) }
                                   )) {
                                ForEach(TravelMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .accessibilityIdentifier("route-stage-mode-\(index + 1)")
                        }
                    }
                }
                Section("Wegpunkte") {
                    waypointSearch(.start, title: "Start", icon: "play.fill", id: "start")
                    if let start = model.start { lodgingTourCards(at: start, showAdd: true) }
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { index, stop in
                        waypointSearch(.stop(stop.id), title: "Zwischenziel \(index + 1)", icon: "mappin",
                                       id: "stop-\(index + 1)") {
                            if focusedWaypoint == .stop(stop.id) { focusedWaypoint = nil }
                            confirmTransitChange { model.removeStop(stop) }
                        }
                        lodgingTourCards(at: stop, showAdd: true)
                    }
                    if model.searchField == .newStop {
                        waypointSearch(.newStop, title: "Neues Zwischenziel", icon: "mappin", id: "new-stop")
                            .onAppear { focusedWaypoint = .newStop }
                    } else {
                        Button {
                            model.beginSearch(in: .newStop)
                            focusedWaypoint = .newStop
                        } label: {
                            Label("Zwischenziel hinzufügen", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.hasEndpoints)
                    }
                    if model.isRoundTrip {
                        Label("Rückkehr: \(model.destination?.name ?? "Ausgangspunkt wählen")", systemImage: "flag.checkered")
                    } else {
                        waypointSearch(.destination, title: "Ziel", icon: "flag.checkered", id: "destination")
                        if let destination = model.destination { lodgingTourCards(at: destination, showAdd: true) }
                    }
                    if model.manualOrder {
                        Button("Nach Luftlinie sortieren") { confirmTransitChange { model.useProvisionalOrder() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("route-waypoint-list")
    }

    @ViewBuilder
    private func lodgingTourCards(at stop: RoadStop, showAdd: Bool = false) -> some View {
        let tours = model.lodgingTours.filter { $0.anchorID == stop.id }
        if showAdd && !model.isRoundTrip && model.waypointDetails(for: stop).overnight {
            Button("Rundtour hinzufügen", systemImage: "plus.circle") { model.addLodgingTour(at: stop) }
                .padding(.leading, 14)
        }
        ForEach(Array(tours.enumerated()), id: \.element.id) { index, tour in
            if let planner = model.tourPlanners[tour.id] {
                LodgingTourCard(model: planner, anchor: stop, number: index + 1, draft: $tourEditor, onMap: {
                    clearMapPOI()
                    mapStageID = nil
                    mapTourID = tour.id
                    showSuggestionOnMap = false
                    cameraPosition = .automatic
                }, onOpenMaps: { stop in
                    openInMaps(stop, planner: planner)
                }, onFocus: { stop in
                    mapTourID = tour.id
                    mapStageID = nil
                    showSuggestionOnMap = false
                    focusWaypoint(on: stop)
                }, onDelete: {
                    if mapTourID == tour.id { mapTourID = nil }
                    if let draft = tourEditor, planner.orderedWaypoints.contains(draft.stop) { tourEditor = nil }
                    model.removeLodgingTour(tour.id)
                })
                .padding(.leading, 14)
                .disabled(waypointEditor != nil)
            }
        }
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = model.roadPreview {
                HStack {
                    Text("\(model.lodgingTours.isEmpty ? "" : "Hauptreise · ")\(model.stageModes.values.contains(.walking) ? "Reisezeit" : "Fahrzeit"): ca. \(formatDuration(preview.duration))")
                    Spacer(minLength: 4)
                    Text("\(model.hasActiveTransit ? "Strecke ca." : "Strecke"): \(formatDistance(preview.distance))")
                        .accessibilityIdentifier("route-distance")
                }
            } else if !model.hasEndpoints {
                Text("Start und Ziel wählen.")
            }
            if !model.lodgingTours.isEmpty {
                if let total = model.completeJourneyTotals {
                    Text("Gesamt inkl. Rundtouren und Aufenthalten: \(formatDuration(total.duration)) · \(formatDistance(total.distance))")
                        .accessibilityIdentifier("journey-total")
                } else {
                    Text("Gesamt inkl. Rundtouren: noch nicht vollständig berechnet")
                        .accessibilityIdentifier("journey-total-incomplete")
                }
            }
            if model.hasEndpoints && !model.stops.isEmpty {
                Text("\(model.manualOrder ? "Fixiert" : "Luftlinien-Reihenfolge") · \(model.isProvisional ? "nicht optimiert" : (model.stageModes.values.contains(.walking) ? "zeitgeprüft" : "fahrzeitgeprüft"))")
                    .foregroundStyle(.secondary)
            }
            routeCalculationStatus
            if let notice = model.transitNotice {
                Text(notice).foregroundStyle(.orange)
            }
            if model.hasActiveTransit {
                Text("ÖPNV: gepunktete Luftlinie; Zeit und Strecke sind Schätzungen, kein abgestimmter Fahrplan.")
                    .foregroundStyle(.secondary)
            }
            if let proposal = model.suggestion {
                HStack(spacing: 6) {
                    Text("Vorschlag: ca. \(formatDuration(proposal.duration)) · \(formatDistance(proposal.distance))")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Vorschlagsdetails", systemImage: "info.circle") {
                        showSuggestionPopover.toggle()
                    }
                    .help("Reihenfolge und Fahrzeit des Vorschlags anzeigen")
                    .popover(isPresented: $showSuggestionPopover) {
                        suggestionDetails(proposal)
                    }
                    let mapAction = showSuggestionOnMap ? "Aktuelle Route auf Karte zeigen" : "Vorschlag auf Karte zeigen"
                    Button(mapAction, systemImage: showSuggestionOnMap ? "map.fill" : "map") {
                        let showSuggestion = !showSuggestionOnMap
                        showStageOnMap(nil)
                        showSuggestionOnMap = showSuggestion
                    }
                    .help(mapAction)
                    .accessibilityIdentifier("toggle-suggestion-map")
                    Button("Vorschlag übernehmen", systemImage: "checkmark.circle") {
                        if model.suggestionRemovesTransit {
                            showTransitSuggestionConfirmation = true
                        } else {
                            model.acceptSuggestion()
                        }
                    }
                    .help("Vorschlag übernehmen")
                }
                .labelStyle(.iconOnly)
            }
            HStack(spacing: 6) {
                if model.hasEndpoints && !model.stops.isEmpty {
                    if !model.manualOrder {
                        Button("Aktuelle Reihenfolge fixieren", systemImage: "lock") {
                            model.fixCurrentOrder()
                        }
                        .help("Aktuelle Reihenfolge fixieren")
                        .disabled(model.isOptimizing)
                    }
                }
                if !availableAlternativeConnections.isEmpty {
                    Button("Alternative Verbindungen", systemImage: "point.3.connected.trianglepath.dotted") {
                        showAlternativePopover.toggle()
                    }
                    .help("Alternative Verbindungen auswählen und auf der Karte anzeigen")
                    .foregroundStyle(showAlternativeConnections ? Color.purple : Color.primary)
                    .accessibilityIdentifier("alternative-connections")
                    .popover(isPresented: $showAlternativePopover) {
                        alternativeConnectionsPopover
                    }
                }
                Spacer()
                Button("Reihenfolge optimieren", systemImage: "arrow.triangle.branch") {
                    model.optimizeRoute()
                }
                .help(optimizationHelp)
                .accessibilityIdentifier("optimize-route")
                .disabled(!model.hasEndpoints || model.stops.isEmpty || !model.automaticRouting || model.isOptimizing)
                if model.automaticRouting {
                    Button("Automatische Berechnung pausieren", systemImage: "pause.circle", action: model.pauseRouting)
                        .help("Automatische Berechnung pausieren")
                } else {
                    Button("Automatische Berechnung aktivieren", systemImage: "play.circle") {
                        showRoutingConfirmation = true
                    }
                    .help("Automatische Berechnung aktivieren")
                    .disabled(!model.hasEndpoints)
                }
            }
            .labelStyle(.iconOnly)
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-controls")
        .alert("ÖPNV-Markierungen entfernen?", isPresented: $showTransitSuggestionConfirmation) {
            Button("Vorschlag übernehmen") { model.acceptSuggestion() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Im Vorschlag sind einige markierte Punkte nicht mehr benachbart. Ihre ÖPNV-Markierungen werden beim Übernehmen entfernt.")
        }
    }

    private var optimizationHelp: String {
        if !model.hasEndpoints { return "Start und Ziel für die Optimierung wählen" }
        if model.stops.isEmpty { return "Für die Optimierung ein Zwischenziel hinzufügen" }
        if !model.automaticRouting { return "Automatische Berechnung für die Optimierung aktivieren" }
        if model.isOptimizing { return "Berechnung läuft" }
        return "Reihenfolge nach Reisezeit optimieren"
    }

    private func suggestionDetails(_ proposal: PlannedRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reihenfolge des Vorschlags").font(.headline)
            ScrollView {
                Text(proposal.orderedStops.map(\.name).joined(separator: " → "))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            Text("Reisezeit: ca. \(formatDuration(proposal.duration)) · Strecke: \(formatDistance(proposal.distance))")
            if let preview = model.roadPreview {
                Text("Ca. \(formatDuration(preview.duration - proposal.duration)) weniger Reisezeit")
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var alternativeConnectionsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alternative Verbindungen").font(.headline)
            Toggle("Auf Karte anzeigen", isOn: $showAlternativeConnections)
                .accessibilityIdentifier("show-alternative-connections")
            Text("Lila gestrichelt · Fahrtrichtung beachten")
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Button {
                        selectedAlternativeConnection = nil
                        showAlternativeConnections = true
                    } label: {
                        Label("Alle Verbindungen", systemImage: selectedAlternativeConnection == nil
                              ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("all-alternative-connections")
                    .accessibilityLabel(selectedAlternativeConnection == nil
                                        ? "Alle Verbindungen, ausgewählt" : "Alle Verbindungen")
                    ForEach(availableAlternativeConnections) { connection in
                        Button {
                            selectedAlternativeConnection = connection.id
                            showAlternativeConnections = true
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: selectedAlternativeConnection == connection.id
                                      ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(connection.from.name) → \(connection.to.name)")
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(formatDuration(connection.leg.duration)) · \(formatDistance(connection.leg.distance))")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("alternative-\(connection.from.id)-\(connection.to.id)")
                        .accessibilityLabel("\(connection.from.name) → \(connection.to.name), \(formatDuration(connection.leg.duration)), \(formatDistance(connection.leg.distance))\(selectedAlternativeConnection == connection.id ? ", ausgewählt" : "")")
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: min(CGFloat(availableAlternativeConnections.count + 1) * 50, 240))
        }
        .padding()
        .frame(width: 340)
    }

    private var stageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.hasEndpoints {
                        Section {
                            if let next = model.nextWaypoint {
                                Text("Nächstes Ziel: \(next.name)")
                                    .accessibilityIdentifier("next-waypoint")
                                HStack {
                                    mapsButton(for: next, id: "open-next-waypoint")
                                    Button("Besucht") { model.setVisitStatus(.visited, for: next) }
                                        .disabled(waypointEditor?.id == next.id && waypointEditor?.isStageBudget == false)
                                        .help(waypointEditor?.id == next.id && waypointEditor?.isStageBudget == false
                                              ? "Besuchsstatus in den Wegpunktdetails bearbeiten" : "Als besucht markieren")
                                    Button("Überspringen") { model.setVisitStatus(.skipped, for: next) }
                                        .accessibilityIdentifier("skip-next-waypoint")
                                        .disabled(waypointEditor?.id == next.id && waypointEditor?.isStageBudget == false)
                                        .help(waypointEditor?.id == next.id && waypointEditor?.isStageBudget == false
                                              ? "Besuchsstatus in den Wegpunktdetails bearbeiten" : "Wegpunkt überspringen")
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("Keine offenen Ziele mehr.")
                            }
                        } header: {
                            Text("Reiseverlauf").font(.headline)
                        }
                        Section {
                            Text("Mit dem Bett-Symbol markierst du eine Übernachtung. An einem Zwischenziel endet dort die Etappe.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Standard-Zeitbudget: \(model.defaultStageBudgetMinutes.map(DurationInputFormat.string) ?? "keins")") {
                                showDefaultBudget = true
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("default-stage-budget")
                            if mapStage != nil {
                                Button("Gesamtroute auf der Karte", action: { showStageOnMap(nil) })
                                    .buttonStyle(.borderless)
                            }
                        } header: {
                            Text("Etappenplanung").font(.headline)
                        }
                        if let start = model.start {
                            lodgingTourCards(at: start, showAdd: true)
                        }
                        ForEach(Array(model.stages.enumerated()), id: \.element.id) { index, stage in
                            let placeholder = stage.budgetPlaceholder
                            Section {
                                stageSummary(stage, number: index + 1)
                                Picker("Verkehrsmittel", selection: Binding(
                                    get: { model.mode(for: stage) },
                                    set: { model.setMode($0, for: stage) }
                                )) {
                                    ForEach(TravelMode.allCases, id: \.self) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .accessibilityIdentifier("stage-mode-\(index + 1)")
                                HStack {
                                    if model.isRoundTripStage(stage) {
                                        Button("Zwischenziel zur Rundtour") {
                                            showStages = false
                                            model.beginAddingStop(to: stage)
                                            focusedWaypoint = .newStop
                                        }
                                        .accessibilityIdentifier("round-trip-add-stop-\(index + 1)")
                                    }
                                    if model.waypointDetails(for: stage.end).overnight && !model.isRoundTrip {
                                        Button("Rundtour hinzufügen") {
                                            model.addLodgingTour(at: stage.end)
                                        }
                                        .accessibilityIdentifier("add-round-trip-\(index + 1)")
                                    }
                                }
                                .buttonStyle(.borderless)
                                if index > 0, let start = stage.waypoints.first {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Abfahrt: \(start.name)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let placeholder, placeholder.afterWaypointID == start.id {
                                            budgetPlaceholderRow(placeholder, stage: stage, number: index + 1)
                                        }
                                    }
                                }
                                ForEach(index == 0 ? stage.waypoints : Array(stage.waypoints.dropFirst())) { stop in
                                    if let position = stage.waypoints.firstIndex(of: stop), position > 0,
                                       model.mode(for: stage) == .walking {
                                        let previous = stage.waypoints[position - 1]
                                        Toggle("ÖPNV: \(previous.name) → \(stop.name)", isOn: Binding(
                                            get: { model.isTransit(from: previous, to: stop) },
                                            set: { model.setTransit($0, from: previous, to: stop) }
                                        ))
                                        .accessibilityIdentifier("transit-stage-\(index + 1)-\(position)")
                                        .disabled(previous.coordinate.latitude == stop.coordinate.latitude
                                                  && previous.coordinate.longitude == stop.coordinate.longitude)
                                    }
                                    stageWaypointRow(stop, number: (model.orderedWaypoints.firstIndex(of: stop) ?? 0) + 1)
                                    if let draft = waypointEditor, draft.id == stop.id, !draft.isStageBudget {
                                        waypointDetailsEditor(draft)
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("waypoint-editor-\(stop.id)", anchor: .bottom)
                                            }
                                        }
                                    }
                                    if let placeholder, placeholder.afterWaypointID == stop.id {
                                        budgetPlaceholderRow(placeholder, stage: stage, number: index + 1)
                                    }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 6) {
                                    let expanded = waypointEditor?.id == stage.end.id && waypointEditor?.isStageBudget == true
                                    Button {
                                        requestWaypointAction(expanded ? .close : .openStageBudget(stage.end))
                                    } label: {
                                        HStack {
                                            Text("\(model.isRoundTripStage(stage) ? "Rundtour" : "Etappe") \(index + 1): \(stage.end.name)")
                                            Spacer()
                                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                                .font(.caption)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityHint(expanded ? "Etappenbudget einklappen" : "Etappenbudget ausklappen")
                                    .accessibilityIdentifier("stage-details-\(index + 1)")
                                    if let draft = waypointEditor, draft.id == stage.end.id, draft.isStageBudget {
                                        InlineStageBudgetEditor(draft: draft) { edited, minutes in
                                            var details = model.waypointDetails(for: edited.stop)
                                            details.stageBudgetMinutes = minutes
                                            model.updateDetails(details, for: edited.stop)
                                            waypointEditor = nil
                                        } cancel: {
                                            waypointEditor = nil
                                        }
                                        .id("stage-budget-editor-\(stage.id)")
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("stage-budget-editor-\(stage.id)", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            }
                            lodgingTourCards(at: stage.end)
                        }
                    } else {
                        Text("Wähle Start und Ziel in der Routenansicht, um Etappen zu planen.")
                    }
                }
                .padding()
            }
            .accessibilityIdentifier("stage-list")
        }
    }

    private func budgetPlaceholderRow(_ placeholder: TripStage.BudgetPlaceholder, stage: TripStage,
                                      number: Int) -> some View {
        Button {
            showStageOnMap(stage.id)
            let span = Self.overnightSearchRadius * 3.5
            cameraPosition = .region(MKCoordinateRegion(center: placeholder.coordinate,
                                                         latitudinalMeters: span, longitudinalMeters: span))
        } label: {
            Label("Zeitbudget erreicht · Übernachtung suchen", systemImage: "bed.double")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help("Suchbereich mit 5 km Durchmesser auf der Karte zeigen")
        .accessibilityIdentifier("budget-placeholder-\(number)")
    }

    private func stageSummary(_ stage: TripStage, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verweilzeit: \(formatDuration(stage.stayMinutes * 60))")
            if let drive = stage.driveDuration, let total = stage.totalDuration {
                Text("Etappenzeit: \(formatDuration(total)) · davon \(model.mode(for: stage) == .driving ? "Fahrt" : "unterwegs"): \(formatDuration(drive))")
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("stage-totals-\(number)")
            } else {
                Text("Etappenzeit: \(formatDuration(stage.stayMinutes * 60)) + ausstehende \(model.mode(for: stage) == .driving ? "Fahrzeit" : "Reisezeit")")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("stage-totals-\(number)")
            }
            if let budget = stage.budgetMinutes {
                let seconds = Double(budget) * 60
                Text("Zeitbudget: \(DurationInputFormat.string(budget))")
                if let total = stage.totalDuration, total > seconds {
                    Text("Zeitbudget überschritten")
                        .foregroundStyle(.orange)
                }
            }
            if stage.isBudgetOverrunAccepted {
                Text("Zeitüberschreitung akzeptiert")
                Button("Budgetpunkt wieder anzeigen") {
                    model.clearBudgetOverrunAcceptance(endingAt: stage.end)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("restore-budget-point-\(number)")
            } else if let overrun = stage.budgetOverrun {
                Button("Übernachtung \(DurationInputFormat.string(overrun.arrivalMinutes - overrun.budgetMinutes)) nach Budget bestätigen") {
                    overrunStage = stage
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("confirm-budget-overrun-\(number)")
            }
            Button(mapStageID == stage.id ? "Auf der Karte ausgewählt" : "Etappe auf der Karte zeigen") {
                showStageOnMap(stage.id)
            }
            .accessibilityIdentifier("show-stage-\(number)")
            .buttonStyle(.borderless)
            .disabled(mapStageID == stage.id)
        }
        .font(.caption)
    }

    private func stageWaypointRow(_ stop: RoadStop, number: Int) -> some View {
        let details = model.waypointDetails(for: stop)
        let appearance = waypointAppearance(for: stop)
        return HStack {
            Button {
                focusWaypoint(on: stop)
                toggleWaypointDetails(stop)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(stop.name)
                    } icon: {
                        Image(systemName: appearance.systemImage)
                            .foregroundStyle(appearance.color)
                    }
                    if stop != model.start {
                        Text(details.status.title)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("visit-status-\(number)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(details.overnight ? "Übernachtung" : details.category?.title ?? "Wegpunkt")
            .accessibilityHint(waypointEditor?.id == stop.id && waypointEditor?.isStageBudget == false
                               ? "Details einklappen" : "Details ausklappen")
            .accessibilityIdentifier("stage-waypoint-\(number)")
            let expanded = waypointEditor?.id == stop.id && waypointEditor?.isStageBudget == false
            Button(expanded ? "Details einklappen" : "Details ausklappen",
                   systemImage: expanded ? "chevron.up" : "chevron.down") {
                toggleWaypointDetails(stop)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(expanded ? "Wegpunktdetails einklappen" : "Wegpunktdetails ausklappen")
            .accessibilityIdentifier("waypoint-details-\(number)")
            if stop != model.start {
                let action = details.overnight ? "Übernachtungsmarkierung entfernen" : "Als Übernachtung markieren"
                Button(action, systemImage: details.overnight ? "bed.double.fill" : "bed.double") {
                    var updated = model.waypointDetails(for: stop)
                    updated.overnight.toggle()
                    if !updated.overnight && stop != model.destination {
                        updated.stageBudgetMinutes = nil
                    }
                    model.updateDetails(updated, for: stop)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(waypointEditor?.id == stop.id
                      ? "Details vor dem Ändern der Übernachtung schließen" : action)
                .accessibilityIdentifier("toggle-overnight-\(number)")
                .disabled(waypointEditor?.id == stop.id || model.isOvernightLocked(stop))
                mapsButton(for: stop, id: "open-stage-waypoint-\(number)")
            }
            if stop != model.start && stop != model.destination {
                Button("Zwischenziel entfernen", systemImage: "minus.circle") {
                    stageStopToRemove = stop
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Zwischenziel entfernen")
                .accessibilityIdentifier("remove-stage-waypoint-\(number)")
                .disabled(model.isProtectedRoundTripAnchor(stop))
            }
        }
    }

    private func waypointAppearance(for stop: RoadStop, in planner: TripPlannerViewModel? = nil) -> WaypointAppearance {
        let planner = planner ?? model
        return WaypointAppearance(details: planner.waypointDetails(for: stop),
                                  isStart: stop == planner.start, isDestination: stop == planner.destination)
    }

    private func mapWaypoints(_ waypoints: [RoadStop]) -> [RoadStop] {
        var seen = Set<RoadStop.ID>()
        return waypoints.filter { stop in
            let planner = activeMapModel
            let root = planner.roundTripAnchors[stop.id]
                ?? (planner.isRoundTrip && stop == planner.destination ? planner.start?.id : nil)
                ?? stop.id
            return seen.insert(root).inserted
        }
    }

    private func overlappingPhotosByWaypoint(waypoints: [RoadStop],
                                             photos: [TripPhoto]) -> [RoadStop.ID: [TripPhoto]] {
        var groupedPhotos: [RoadStop.ID: [TripPhoto]] = [:]
        for photo in photos {
            guard let coordinate = photo.coordinate else { continue }
            let photoLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let nearestWaypoint = waypoints.min(by: {
                CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                    .distance(from: photoLocation)
                    < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)
                    .distance(from: photoLocation)
            }) else {
                continue
            }
            let waypointLocation = CLLocation(latitude: nearestWaypoint.coordinate.latitude,
                                              longitude: nearestWaypoint.coordinate.longitude)
            guard waypointLocation.distance(from: photoLocation) <= Self.photoWaypointOverlapDistance else {
                continue
            }
            groupedPhotos[nearestWaypoint.id, default: []].append(photo)
        }
        return groupedPhotos
    }

    private func toggleWaypointDetails(_ stop: RoadStop) {
        let expanded = waypointEditor?.id == stop.id && waypointEditor?.isStageBudget == false
        requestWaypointAction(expanded ? .close : .open(stop))
    }

    private func waypointDetailsEditor(_ draft: WaypointEditorDraft) -> some View {
        WaypointDetailsEditor(draft: draft) { edited, minutes in
            let current = model.waypointDetails(for: edited.stop)
            model.updateDetails(edited.merging(current, stayMinutes: minutes), for: edited.stop)
            waypointEditor = nil
        } cancel: {
            waypointEditor = nil
        }
        .id("waypoint-editor-\(draft.id)")
    }

    private func requestWaypointAction(_ action: WaypointEditorAction) {
        if waypointEditor?.hasChanges == true || tourEditor?.hasChanges == true {
            pendingWaypointAction = action
            showDiscardWaypointChanges = true
        } else {
            performWaypointAction(action)
        }
    }

    private func performWaypointAction(_ action: WaypointEditorAction) {
        waypointEditor = nil
        tourEditor = nil
        switch action {
        case .close:
            break
        case .open(let stop):
            waypointEditor = WaypointEditorDraft(stop: stop, details: model.waypointDetails(for: stop),
                                                  isStart: stop == model.start, isDestination: stop == model.destination,
                                                  protectedOvernight: model.isOvernightLocked(stop))
        case .openStageBudget(let stop):
            waypointEditor = WaypointEditorDraft(stop: stop, details: model.waypointDetails(for: stop),
                                                  isStart: stop == model.start, isDestination: stop == model.destination,
                                                  isStageBudget: true)
        case .selectTrip(let id):
            library.select(id)
        case .newTrip:
            editor = TripEditorDraft()
        case .importTrip:
            importExchange()
        case .exportTrip:
            showExchangePrivacy = true
        case .exportHTML:
            exportHTML()
        case .editTrip(let trip):
            editor = TripEditorDraft(trip: trip)
        case .showRoute:
            showStages = false
        }
    }

    private func importExchange() {
        let panel = NSOpenPanel()
        panel.title = "Reise importieren"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferInProgress = true
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                transferInProgress = false
            }
            do {
                try await library.importTrip(from: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportExchange() {
        guard let trip = library.selectedTrip else { return }
        let panel = NSSavePanel()
        panel.title = "Reise exportieren"
        panel.nameFieldStringValue = "\(trip.name).roadtrip"
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "roadtrip" else {
            exportError = "Der Dateiname muss mit .roadtrip enden."
            return
        }
        transferInProgress = true
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                transferInProgress = false
            }
            do {
                try await library.exportTrip(trip, to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportHTML() {
        guard let trip = library.selectedTrip else { return }
        let panel = NSSavePanel()
        panel.title = "Ordner für HTML-Reisetagebuch wählen"
        panel.nameFieldStringValue = "\(trip.name) – Reisetagebuch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferInProgress = true
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                transferInProgress = false
            }
            do {
                try await library.exportHTML(trip, to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func showStageOnMap(_ id: RoadStop.ID?) {
        clearMapPOI()
        mapStageID = id
        mapTourID = nil
        showSuggestionOnMap = false
        cameraPosition = .automatic
    }

    private var routeCalculationStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
        switch model.routeStatus {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("Route wird vorbereitet …")
        case let .running(.streetRoute(done, total)):
            routeStepProgress(model.stageModes.values.contains(.walking) ? "Route" : "Straßenroute", done: done, total: total)
        case let .running(.alternativeLegs(done, total)):
            routeStepProgress("Alternative Verbindungen", done: done, total: total)
        case .running(.comparingOrders):
            ProgressView("Reihenfolgen vergleichen …")
        case .finished:
            if model.suggestion != nil {
                Label("Vorschlag bereit", systemImage: "checkmark.circle")
            } else if model.stops.isEmpty || model.isProvisional {
                Label(model.stageModes.values.contains(.walking) ? "Route berechnet" : "Straßenroute berechnet",
                      systemImage: "checkmark.circle")
            } else {
                Label("Reihenfolge nach Fahrzeit geprüft", systemImage: "checkmark.circle")
            }
        case .paused:
            Label("Berechnung pausiert", systemImage: "pause.circle")
        case .failed:
            Button {
                showRoutingDiagnostics = true
            } label: {
                HStack {
                    Label(model.roadPreview == nil
                          ? (model.currentConnections.isEmpty
                             ? "Routenberechnung fehlgeschlagen."
                             : "Teilroute verfügbar; Verbindungen fehlen.")
                          : "Optimierung nicht abgeschlossen.",
                          systemImage: "exclamationmark.triangle")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Image(systemName: "info.circle")
                }
            }
            .buttonStyle(.plain)
            .help("Fehlerdiagnose anzeigen")
            .accessibilityIdentifier("routing-diagnostics")
            ForEach(model.unavailableConnections) { connection in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ohne Verbindung:").foregroundStyle(.red)
                    Button("Von: \(connection.from.name)") { focusWaypoint(on: connection.from) }
                    Button("Nach: \(connection.to.name)") { focusWaypoint(on: connection.to) }
                }
            }
            Button("Erneut versuchen", action: model.retryRouting)
            if model.unavailableConnections.contains(where: { model.mode(from: $0.from, to: $0.to) == .driving }) {
                parkingSuggestions
            }
        }
            if model.isOptimizing || model.routeStatus == .paused {
                Button("Diagnose anzeigen", systemImage: "info.circle") {
                    showRoutingDiagnostics = true
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routing-diagnostics")
            }
        }
        .popover(isPresented: $showRoutingDiagnostics, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Routenberechnung – Diagnose").font(.headline)
                Text("Die Angaben bleiben lokal und können Standortdaten enthalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.routingDiagnostic ?? model.liveRoutingDiagnostic(at: context.date))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("routing-diagnostics-details")
                    }
                }
                Button("Schließen") { showRoutingDiagnostics = false }
            }
            .padding()
            .frame(width: 520, height: 420)
        }
    }

    private var parkingSuggestions: some View {
        let affectedIDs = Set(model.unavailableConnections
            .filter { model.mode(from: $0.from, to: $0.to) == .driving }
            .flatMap { [$0.from.id, $0.to.id] })
        let affectedWaypoints = model.orderedWaypoints.filter { affectedIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Parkplatz in der Nähe suchen").fontWeight(.semibold)
            Text("Die nächsten fünf Treffer im Umkreis von 2 km werden als Ersatz für den gewählten Punkt auf ihre Straßenanbindung geprüft. Der ursprüngliche Wegpunkt bleibt unverändert.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(affectedWaypoints) { waypoint in
                Button("Parkplätze bei „\(waypoint.name)“ prüfen") {
                    model.searchParking(near: waypoint)
                }
                .disabled(model.isSearchingParking)
            }
            if let waypoint = model.parkingSearchWaypoint {
                if model.isSearchingParking {
                    ProgressView("Parkplätze bei „\(waypoint.name)“ werden geprüft …")
                } else if let error = model.parkingSearchError {
                    Text("Parkplatzsuche fehlgeschlagen: \(error)").foregroundStyle(.red)
                } else if model.parkingSuggestions.isEmpty {
                    Text("Unter den geprüften Treffern wurde kein passend angebundener Parkplatz gefunden.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Als Ersatz für „\(waypoint.name)“ geprüft; Entfernung ist Luftlinie, kein geprüfter Fußweg.")
                        .font(.caption)
                    ForEach(model.parkingSuggestions) { parking in
                        Button("\(parking.name) · \(formatDistance(parking.distance(to: waypoint)))") {
                            focusWaypoint(on: parking)
                        }
                        .help("Parkplatz auf der Karte anzeigen")
                    }
                }
            }
        }
    }

    private func routeStepProgress(_ title: String, done: Int, total: Int) -> some View {
        ProgressView(value: Double(done), total: Double(total)) {
            Text("\(title): \(done)/\(total)").fontWeight(.semibold)
        }
        .accessibilityValue("\(done) von \(total) neuen MapKit-Abfragen")
    }

    private func waypointSearch(_ field: WaypointField, title: String, icon: String, id: String,
                                remove: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let stop = model.waypoint(in: field)
            let appearance = stop.map { waypointAppearance(for: $0) }
            let heading = Label {
                Text(title)
            } icon: {
                Image(systemName: appearance?.systemImage ?? icon)
                    .foregroundStyle(appearance?.color ?? .secondary)
            }
            if let stop {
                Button {
                    focusWaypoint(on: stop)
                } label: {
                    heading
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("\(title) auf der Karte zeigen")
                .accessibilityLabel("\(title) auf der Karte zeigen")
                .accessibilityIdentifier("focus-waypoint-\(id)")
            } else {
                heading
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack {
                TextField("Ort oder POI suchen", text: Binding(
                    get: { model.fieldText(field) },
                    set: { model.updateSearch($0, in: field) }
                ))
                .accessibilityLabel(title)
                .accessibilityIdentifier("waypoint-\(id)")
                .disabled(stop.map { model.roundTripAnchors[$0.id] != nil } ?? false)
                .focused($focusedWaypoint, equals: field)
                .onSubmit {
                    if model.searchField == field, let first = model.searchResults.first {
                        choose(first, in: field)
                    }
                }
                .onExitCommand {
                    if model.searchField == field { dismissWaypointSearch() }
                }
                if model.searchField == field {
                    Button("Suche abbrechen", systemImage: "xmark.circle", action: dismissWaypointSearch)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                if let stop = model.waypoint(in: field) {
                    if case .stop = field, let index = model.stops.firstIndex(of: stop) {
                        Button("Zwischenziel nach oben", systemImage: "arrow.up") {
                            confirmTransitChange { model.moveStop(stop, by: -1) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("move-up-\(id)")
                        .disabled(index == 0 || model.isProtectedRoundTripAnchor(stop)
                                  || model.isProtectedRoundTripAnchor(model.stops[index - 1]))
                        Button("Zwischenziel nach unten", systemImage: "arrow.down") {
                            confirmTransitChange { model.moveStop(stop, by: 1) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(index == model.stops.count - 1 || model.isProtectedRoundTripAnchor(stop)
                                  || model.isProtectedRoundTripAnchor(model.stops[index + 1]))
                    }
                    mapsButton(for: stop, id: "open-maps-\(id)")
                    let expanded = waypointEditor?.id == stop.id && waypointEditor?.isStageBudget == false
                    Button(expanded ? "Wegpunktdetails einklappen" : "Wegpunktdetails ausklappen",
                           systemImage: expanded ? "chevron.up" : "chevron.down") {
                        toggleWaypointDetails(stop)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(expanded ? "Wegpunktdetails einklappen" : "Wegpunktdetails ausklappen")
                    .accessibilityIdentifier("route-waypoint-details-\(id)")
                }
                if let remove {
                    Button("Zwischenziel entfernen", systemImage: "minus.circle", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(stop.map { model.isProtectedRoundTripAnchor($0) } ?? false)
                }
            }
            if let stop {
                let details = model.waypointDetails(for: stop)
                WaypointSummary(details: details, identifier: "waypoint-summary-\(id)")
                if let draft = waypointEditor, draft.id == stop.id, !draft.isStageBudget {
                    waypointDetailsEditor(draft)
                }
            }
            if model.searchField == field {
                if model.isSearching {
                    ProgressView("Suche läuft …").controlSize(.small)
                } else if let error = model.errorMessage {
                    Text("Suche fehlgeschlagen: \(error)").foregroundStyle(.red)
                    Button("Suche erneut versuchen") {
                        model.updateSearch(model.query, in: field)
                    }
                    .buttonStyle(.borderless)
                } else if model.searchFinished && model.searchResults.isEmpty {
                    Text("Keine passenden Orte gefunden.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.searchResults.prefix(5).enumerated()), id: \.element.id) { index, result in
                    Button {
                        choose(result, in: field)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("search-result-\(index)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func choose(_ result: RoadStop, in field: WaypointField) {
        let changesAnchor: Bool
        if case .stop(let id) = field {
            changesAnchor = model.roundTripAnchors.values.contains(id)
                || model.lodgingTours.contains { $0.anchorID == id }
        } else if field == .destination, let id = model.destination?.id {
            changesAnchor = model.lodgingTours.contains { $0.anchorID == id }
        } else if field == .start, let id = model.start?.id {
            changesAnchor = model.lodgingTours.contains { $0.anchorID == id }
        } else {
            changesAnchor = false
        }
        confirmTransitChange(changesAnchor: changesAnchor) {
            if model.chooseSearchResult(result, in: field) {
                focusedWaypoint = nil
                if fixturePOI == nil { focusMap(on: result) }
            }
        }
    }

    private func confirmTransitChange(changesAnchor: Bool = false, planner: TripPlannerViewModel? = nil,
                                      _ action: @escaping () -> Void) {
        if (planner ?? model).transitLegs.isEmpty && !changesAnchor { action() }
        else {
            transitChangeMessage = changesAnchor
                ? "Der Übernachtungsort und die Start- und Endpunkte aller zugehörigen Rundtouren werden geändert. Betroffene ÖPNV-Markierungen werden entfernt."
                : "Wenn markierte Punkte nicht mehr benachbart sind, werden ihre ÖPNV-Markierungen entfernt."
            pendingTransitChange = action
        }
    }

    private func dismissWaypointSearch() {
        focusedWaypoint = nil
        model.cancelSearch()
    }

    private func focusMap(on stop: RoadStop) {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: stop.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
            )
        )
    }

    private func focusWaypoint(on stop: RoadStop) {
        cameraPosition = .region(waypointFocusRegion(for: stop))
    }

    private func photoPopoverBinding(for photoID: TripPhoto.ID) -> Binding<Bool> {
        Binding {
            presentedMapPhotoID == photoID
        } set: { isPresented in
            if isPresented {
                presentedMapPhotoID = photoID
            } else if presentedMapPhotoID == photoID {
                presentedMapPhotoID = nil
            }
        }
    }

    private func mapsButton(for stop: RoadStop, id: String) -> some View {
        Button("In Apple Karten öffnen", systemImage: "map") {
            openInMaps(stop)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("In Apple Karten öffnen")
        .accessibilityIdentifier(id)
    }

    private func openInMaps(_ stop: RoadStop, planner: TripPlannerViewModel? = nil) {
        let model = planner ?? model
        let item = MapKitRouteService.mapItem(for: stop)
        let waypoints = model.orderedWaypoints
        let index = waypoints.firstIndex(of: stop)
        let previous = index.flatMap { $0 > 0 ? waypoints[$0 - 1] : nil }
        let direction: String
        if let previous, model.mode(from: previous, to: stop) == .walking {
            direction = model.isTransit(from: previous, to: stop)
                ? MKLaunchOptionsDirectionsModeTransit : MKLaunchOptionsDirectionsModeWalking
        } else {
            direction = MKLaunchOptionsDirectionsModeDriving
        }
        if !launchMaps(item, [MKLaunchOptionsDirectionsModeKey: direction]) {
            showMapsError = true
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard let totalMinutes = Int(exactly: (duration / 60).rounded(.towardZero)) else { return "—" }
        guard totalMinutes >= 60 else { return "\(totalMinutes) min" }
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }

    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1_000 {
            return "\(distance.formatted(.number.precision(.fractionLength(0)))) m"
        }
        return "\((distance / 1_000).formatted(.number.precision(.fractionLength(0...1)))) km"
    }
}

private struct WaypointPhotoOverlapAnnotation: View {
    let waypoint: RoadStop
    let photos: [TripPhoto]
    @ObservedObject var library: TripLibrary
    @ObservedObject var model: TripPlannerViewModel
    let tripID: RoadTrip.ID
    @Binding var presentedPhotoID: TripPhoto.ID?

    @State private var separation: CGFloat = 0

    private let itemSize: CGFloat = 42
    private let itemSpacing: CGFloat = 8
    private let maximumSeparation: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(photos.indices, id: \.self) { index in
                    let horizontalOffset = photoHorizontalOffset(at: index)
                    connector(in: geometry, to: CGPoint(
                        x: center.x + horizontalOffset + separation,
                        y: center.y - itemSize / 2
                    ))
                }

                HStack(spacing: itemSpacing) {
                    ForEach(photos) { photo in
                        photoButton(photo)
                    }
                }
                .offset(x: separation, y: -itemSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: CGFloat(photos.count) * itemSize
               + CGFloat(max(0, photos.count - 1)) * itemSpacing + 2 * maximumSeparation,
               height: 140)
        .contentShape(Rectangle())
        .onHover { isHovered in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                separation = isHovered ? maximumSeparation : 0
            }
        }
        .accessibilityIdentifier("planner-waypoint-photo-overlap-\(waypoint.id.uuidString)")
    }

    private func photoButton(_ photo: TripPhoto) -> some View {
        Button {
            presentedPhotoID = photo.id
        } label: {
            TripPhotoThumbnail(url: library.photoURL(for: photo, tripID: tripID),
                               rotationQuarterTurns: photo.rotationQuarterTurns)
                .frame(width: itemSize, height: itemSize)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Foto auf der Karte: \(photo.caption.isEmpty ? photo.originalName : photo.caption)")
        .accessibilityIdentifier("planner-photo-marker-\(photo.id.uuidString)")
        .popover(isPresented: photoPopoverBinding(for: photo.id), arrowEdge: .trailing) {
            TripPhotoDetailPopover(library: library, model: model,
                                   tripID: tripID, photoID: photo.id) {
                presentedPhotoID = nil
            }
        }
    }

    private func photoPopoverBinding(for photoID: TripPhoto.ID) -> Binding<Bool> {
        Binding {
            presentedPhotoID == photoID
        } set: { isPresented in
            if isPresented {
                presentedPhotoID = photoID
            } else if presentedPhotoID == photoID {
                presentedPhotoID = nil
            }
        }
    }

    private func photoHorizontalOffset(at index: Int) -> CGFloat {
        (CGFloat(index) - CGFloat(photos.count - 1) / 2) * (itemSize + itemSpacing)
    }

    private func connector(in geometry: GeometryProxy, to endpoint: CGPoint) -> some View {
        Path { path in
            path.move(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
            path.addLine(to: endpoint)
        }
        .stroke(.white, lineWidth: 2)
        .shadow(color: .black.opacity(0.75), radius: 2)
        .opacity(separation == 0 ? 0 : 1)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: separation)
    }
}

func waypointFocusRegion(for stop: RoadStop) -> MKCoordinateRegion {
    MKCoordinateRegion(center: stop.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
}

private struct LodgingTourCard: View {
    @ObservedObject var model: TripPlannerViewModel
    let anchor: RoadStop
    let number: Int
    @Binding var draft: WaypointEditorDraft?
    let onMap: () -> Void
    let onOpenMaps: (RoadStop) -> Void
    let onFocus: (RoadStop) -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var showDiagnostics = false
    @State private var confirmRouting = false
    @State private var confirmOverrun = false
    @State private var pendingChange: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Rundtour \(number) ab \(anchor.name)", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let stage = model.stages.first {
                Picker("Verkehrsmittel", selection: Binding(
                    get: { model.mode(for: stage) },
                    set: { model.setMode($0, for: stage) }
                )) {
                    ForEach(TravelMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("lodging-tour-mode")
                Text("Start: \(anchor.name)").font(.caption)
                ForEach(Array(model.stops.enumerated()), id: \.element.id) { index, stop in
                    if model.mode(for: stage) == .walking,
                       let previous = model.orderedWaypoints.firstIndex(of: stop).map({ model.orderedWaypoints[$0 - 1] }) {
                        transitToggle(from: previous, to: stop)
                    }
                    tourWaypoint(stop, index: index)
                    if draft?.id == stop.id, let draft {
                        WaypointDetailsEditor(draft: draft) { edited, minutes in
                            model.updateDetails(edited.merging(model.waypointDetails(for: edited.stop),
                                                               stayMinutes: minutes), for: edited.stop)
                            self.draft = nil
                        } cancel: { self.draft = nil }
                    }
                }
                if model.mode(for: stage) == .walking, let previous = model.orderedWaypoints.dropLast().last,
                   let end = model.destination, previous.distance(to: end) > 0 {
                    transitToggle(from: previous, to: end)
                }
                HStack {
                    Text("Rückkehr: \(anchor.name)").font(.caption)
                    Button("In Apple Karten öffnen", systemImage: "map") {
                        if let destination = model.destination { onOpenMaps(destination) }
                    }.labelStyle(.iconOnly)
                }
                if model.searchField == .newStop {
                    TextField("Ort oder POI suchen", text: Binding(
                        get: { model.query }, set: { model.updateSearch($0, in: .newStop) }
                    ))
                    .accessibilityIdentifier("lodging-tour-search")
                    ForEach(Array(model.searchResults.enumerated()), id: \.element.id) { index, result in
                        Button(result.name) {
                            requestChange { _ = model.chooseSearchResult(result, in: .newStop, distinctOccurrence: true) }
                        }
                            .accessibilityIdentifier("lodging-tour-search-result-\(index)")
                    }
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                    Button("Suche abbrechen") { model.cancelSearch() }
                } else {
                    Button("Zwischenziel hinzufügen", systemImage: "plus.circle") {
                        model.beginSearch(in: .newStop)
                    }
                    .accessibilityIdentifier("lodging-tour-add-stop")
                    .disabled(draft != nil)
                }
                if let end = model.destination {
                    let explicitBudget = model.waypointDetails(for: end).stageBudgetMinutes
                    let budget = explicitBudget.map(DurationInputFormat.string)
                        ?? model.defaultStageBudgetMinutes.map { "Standard \(DurationInputFormat.string($0))" } ?? "keins"
                    Button("Budget: \(budget)") {
                        draft = WaypointEditorDraft(stop: end, details: model.waypointDetails(for: end),
                                                    isStart: false, isDestination: true, isStageBudget: true)
                    }
                    .disabled(draft != nil)
                    if draft?.id == end.id, let draft {
                        InlineStageBudgetEditor(draft: draft) { edited, minutes in
                            var details = model.waypointDetails(for: edited.stop)
                            details.stageBudgetMinutes = minutes
                            model.updateDetails(details, for: edited.stop)
                            self.draft = nil
                        } cancel: { self.draft = nil }
                    }
                }
                if let overrun = stage.budgetOverrun {
                    if stage.isBudgetOverrunAccepted {
                        Text("Budgetüberschreitung bestätigt").font(.caption)
                        Button("Budgetbestätigung zurücknehmen") {
                            model.clearBudgetOverrunAcceptance(endingAt: stage.end)
                        }
                    } else {
                        Text("Budget voraussichtlich um \(DurationInputFormat.string(overrun.arrivalMinutes - overrun.budgetMinutes)) (hh:mm) überschritten.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Budgetüberschreitung bestätigen") { confirmOverrun = true }
                        Button("Budgetpunkt auf der Karte zeigen", action: onMap)
                    }
                }
                if let route = model.roadPreview {
                    let minutes = Int(exactly: ceil(route.duration / 60))
                    Text("Berechnet: \(minutes.map(DurationInputFormat.string) ?? "Zeit nicht verfügbar") · \(route.distance.formatted(.number.precision(.fractionLength(0)))) m")
                        .accessibilityIdentifier("lodging-tour-route-summary")
                } else if model.isOptimizing {
                    ProgressView("Rundtour wird berechnet …")
                } else if model.routeStatus == .failed {
                    Text("Rundtour nicht vollständig berechnet").foregroundStyle(.orange)
                }
                HStack {
                    Button("Auf Karte", systemImage: "map", action: onMap)
                    if model.automaticRouting {
                        Button("Pausieren", systemImage: "pause.circle") { model.pauseRouting() }
                        Button("Erneut", systemImage: "arrow.clockwise") { model.retryRouting() }
                    } else {
                        Button("Berechnen", systemImage: "play.circle") { confirmRouting = true }
                            .accessibilityIdentifier("lodging-tour-calculate")
                    }
                    Button("Optimieren", systemImage: "arrow.triangle.branch") { model.optimizeRoute() }
                        .disabled(!model.automaticRouting || model.isOptimizing || model.stops.isEmpty)
                    Button("Diagnose", systemImage: "info.circle") { showDiagnostics = true }
                        .popover(isPresented: $showDiagnostics) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                ScrollView {
                                    Text(model.routingDiagnostic ?? model.liveRoutingDiagnostic(at: context.date))
                                        .textSelection(.enabled).padding()
                                }.frame(width: 520, height: 360)
                            }
                        }
                    Button("Rundtour löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("lodging-tour-delete")
                }.labelStyle(.iconOnly)
                if model.suggestion != nil {
                    Button("Optimierung übernehmen") { requestChange { model.acceptSuggestion() } }
                }
                if let notice = model.transitNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                let affectedIDs = Set(model.unavailableConnections
                    .filter { model.mode(from: $0.from, to: $0.to) == .driving }
                    .flatMap { [$0.from.id, $0.to.id] })
                ForEach(model.orderedWaypoints.filter { affectedIDs.contains($0.id) }) { waypoint in
                    Button("Parkplätze bei „\(waypoint.name)“ prüfen") { model.searchParking(near: waypoint) }
                        .disabled(model.isSearchingParking)
                }
                if model.isSearchingParking {
                    ProgressView("Parkplätze werden geprüft …")
                } else if let error = model.parkingSearchError {
                    Text("Parkplatzsuche fehlgeschlagen: \(error)").foregroundStyle(.red)
                } else if model.parkingSearchWaypoint != nil {
                    if model.parkingSuggestions.isEmpty {
                        Text("Kein passend angebundener Parkplatz gefunden.").font(.caption)
                    } else {
                        Text("Geprüfte Ersatzpunkte; Entfernung ist Luftlinie, kein geprüfter Fußweg.")
                            .font(.caption)
                        ForEach(model.parkingSuggestions) { parking in
                            Button(parking.name) { onFocus(parking) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.35)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lodging-tour-card")
        .alert("Rundtour mit Apple MapKit berechnen?", isPresented: $confirmRouting) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren") { model.enableAutomaticRouting() }
                .accessibilityIdentifier("lodging-tour-confirm-routing")
        } message: {
            Text("Wegpunkt-Koordinaten und ein gegebenenfalls festgelegtes Reisestartdatum werden an Apple gesendet. Nach Änderungen wird die Rundtour automatisch neu berechnet. ÖPNV-Zeiten sind Schätzungen.")
        }
        .alert("Rundtour löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive, action: onDelete)
                .accessibilityIdentifier("confirm-lodging-tour-delete")
            Button("Abbrechen", role: .cancel) {}
                .accessibilityIdentifier("cancel-lodging-tour-delete")
        } message: {
            Text("Die Tour und ihre Zwischenziele werden entfernt. Ungespeicherte Änderungen gehen verloren. Fotos bleiben erhalten; ihre Zuordnungen müssen gegebenenfalls neu gewählt werden.")
        }
        .alert("Zeitüberschreitung bestätigen?", isPresented: $confirmOverrun) {
            Button("Budgetpunkt ausblenden") {
                if let stage = model.stages.first, let overrun = stage.budgetOverrun {
                    model.acceptBudgetOverrun(overrun, endingAt: stage.end)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Budgetpunkt wird ausgeblendet. Die Route bleibt unverändert.")
        }
        .alert("ÖPNV-Markierungen prüfen?", isPresented: Binding(
            get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }
        )) {
            Button("Fortfahren") { let action = pendingChange; pendingChange = nil; action?() }
            Button("Abbrechen", role: .cancel) { pendingChange = nil }
        } message: {
            Text("Nicht mehr benachbarte ÖPNV-Markierungen werden entfernt.")
        }
    }

    private func requestChange(_ action: @escaping () -> Void) {
        if model.transitLegs.isEmpty { action() } else { pendingChange = action }
    }

    private func tourWaypoint(_ stop: RoadStop, index: Int) -> some View {
        let field = WaypointField.stop(stop.id)
        let title = "Zwischenziel \(index + 1)"
        let details = model.waypointDetails(for: stop)
        let appearance = WaypointAppearance(details: details, isStart: false, isDestination: false)
        return VStack(alignment: .leading, spacing: 6) {
            Button { onFocus(stop) } label: {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: appearance.systemImage).foregroundStyle(appearance.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("\(title) auf der Karte zeigen")
            .accessibilityLabel("\(title) auf der Karte zeigen")
            .accessibilityIdentifier("lodging-tour-focus-stop-\(index + 1)")
            HStack {
                TextField("Ort oder POI suchen", text: Binding(
                    get: { model.fieldText(field) }, set: { model.updateSearch($0, in: field) }
                ))
                .accessibilityLabel(title)
                .accessibilityIdentifier("lodging-tour-stop-\(index + 1)")
                .onSubmit {
                    if model.searchField == field, let first = model.searchResults.first {
                        requestChange { _ = model.chooseSearchResult(first, in: field, distinctOccurrence: true) }
                    }
                }
                .onExitCommand { if model.searchField == field { model.cancelSearch() } }
                if model.searchField == field {
                    Button("Suche abbrechen", systemImage: "xmark.circle") { model.cancelSearch() }
                }
                Button("Zwischenziel nach oben", systemImage: "arrow.up") {
                    requestChange { model.moveStop(stop, by: -1) }
                }.disabled(index == 0)
                Button("Zwischenziel nach unten", systemImage: "arrow.down") {
                    requestChange { model.moveStop(stop, by: 1) }
                }.disabled(index == model.stops.count - 1)
                Button("In Apple Karten öffnen", systemImage: "map") { onOpenMaps(stop) }
                    .accessibilityIdentifier("lodging-tour-open-maps-\(index + 1)")
                let expanded = draft?.id == stop.id && draft?.isStageBudget == false
                Button(expanded ? "Wegpunktdetails einklappen" : "Wegpunktdetails ausklappen",
                       systemImage: expanded ? "chevron.up" : "chevron.down") {
                    draft = WaypointEditorDraft(stop: stop, details: details, isStart: false,
                                                isDestination: false, protectedOvernight: true)
                }
                .accessibilityIdentifier("lodging-tour-waypoint-details-\(index + 1)")
                Button("Zwischenziel entfernen", systemImage: "minus.circle") {
                    requestChange { model.removeStop(stop) }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(draft != nil)
            WaypointSummary(details: details, identifier: "lodging-tour-waypoint-summary-\(index + 1)")
            if model.searchField == field {
                if model.isSearching {
                    ProgressView("Suche läuft …").controlSize(.small)
                } else if let error = model.errorMessage {
                    Text("Suche fehlgeschlagen: \(error)").foregroundStyle(.red)
                    Button("Suche erneut versuchen") { model.updateSearch(model.query, in: field) }
                        .buttonStyle(.borderless)
                } else if model.searchFinished && model.searchResults.isEmpty {
                    Text("Keine passenden Orte gefunden.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.searchResults.prefix(5).enumerated()), id: \.element.id) { resultIndex, result in
                    Button {
                        requestChange { _ = model.chooseSearchResult(result, in: field, distinctOccurrence: true) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("lodging-tour-edit-search-result-\(resultIndex)")
                    .disabled(draft != nil)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func transitToggle(from: RoadStop, to: RoadStop) -> some View {
        Toggle("ÖPNV: \(from.name) → \(to.name)", isOn: Binding(
            get: { model.isTransit(from: from, to: to) },
            set: { model.setTransit($0, from: from, to: to) }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .accessibilityIdentifier("lodging-tour-transit-\(model.orderedWaypoints.firstIndex(of: to) ?? 0)")
    }
}

private struct WaypointSummary: View {
    let details: WaypointDetails
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Label(details.category?.title ?? "Keine Kategorie",
                  systemImage: details.category?.systemImage ?? "tag")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("Verweilzeit: \(DurationInputFormat.string(details.stayMinutes))")
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Kategorie: \(details.category?.title ?? "Keine Kategorie"), Verweilzeit: \(DurationInputFormat.string(details.stayMinutes))"
        )
        .accessibilityIdentifier(identifier)
    }
}

struct WaypointAppearance {
    let systemImage: String
    let color: Color

    init(details: WaypointDetails, isStart: Bool, isDestination: Bool) {
        if details.overnight {
            color = .blue
        } else if details.category == .photo {
            color = details.stayMinutes > 0 ? .green : .purple
        } else {
            color = details.category == nil ? .red : .green
        }
        if details.overnight {
            systemImage = details.systemImage
        } else if isStart {
            systemImage = "play.fill"
        } else if isDestination {
            systemImage = "flag.checkered"
        } else {
            systemImage = details.systemImage
        }
    }
}

private enum WaypointEditorAction {
    case close, open(RoadStop), openStageBudget(RoadStop), selectTrip(RoadTrip.ID), newTrip, importTrip, exportTrip,
         exportHTML, editTrip(RoadTrip), showRoute
}

private final class WaypointEditorDraft: ObservableObject, Identifiable {
    var id: RoadStop.ID { stop.id }
    let stop: RoadStop
    let original: WaypointDetails
    let isStart: Bool
    let isDestination: Bool
    let isStageBudget: Bool
    let protectedOvernight: Bool
    @Published var details: WaypointDetails
    @Published var stay: String
    @Published var budget: String

    init(stop: RoadStop, details: WaypointDetails, isStart: Bool, isDestination: Bool,
         isStageBudget: Bool = false, protectedOvernight: Bool = false) {
        self.stop = stop
        self.original = details
        self.isStart = isStart
        self.isDestination = isDestination
        self.isStageBudget = isStageBudget
        self.protectedOvernight = protectedOvernight
        self.details = details
        self.stay = DurationInputFormat.string(details.stayMinutes)
        self.budget = details.stageBudgetMinutes.map(DurationInputFormat.string) ?? ""
    }

    var hasStageBudget: Bool { isDestination || (!isStart && details.overnight) }
    var hasChanges: Bool {
        details != original || stay != DurationInputFormat.string(original.stayMinutes)
            || budget != (original.stageBudgetMinutes.map(DurationInputFormat.string) ?? "")
    }

    func merging(_ current: WaypointDetails, stayMinutes: Int) -> WaypointDetails {
        var result = current
        if stayMinutes != original.stayMinutes { result.stayMinutes = stayMinutes }
        if details.category != original.category { result.category = details.category }
        if details.notes != original.notes { result.notes = details.notes }
        if details.rating != original.rating { result.rating = details.rating }
        if details.status != original.status { result.status = details.status }
        if details.overnight != original.overnight {
            result.overnight = details.overnight
            if !details.overnight && !isDestination { result.stageBudgetMinutes = nil }
        }
        if hasStageBudget && budget != (original.stageBudgetMinutes.map(DurationInputFormat.string) ?? "") {
            result.stageBudgetMinutes = DurationInputFormat.minutes(budget)
        }
        return result
    }
}

private struct WaypointDetailsEditor: View {
    @ObservedObject var draft: WaypointEditorDraft
    let save: (WaypointEditorDraft, Int) -> Void
    let cancel: () -> Void

    private var stayMinutes: Int? { DurationInputFormat.minutes(draft.stay, allowsZero: true) }
    private var validBudget: Bool {
        !draft.hasStageBudget || draft.budget.isEmpty || DurationInputFormat.minutes(draft.budget) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Verweilzeit") {
                TextField("hh:mm", text: $draft.stay)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                    .accessibilityLabel("Verweilzeit (hh:mm)")
                    .accessibilityIdentifier("waypoint-stay")
            }
            LabeledContent("Kategorie") {
                Picker("Kategorie", selection: $draft.details.category) {
                    Text("Keine Kategorie").tag(nil as WaypointCategory?)
                    ForEach(WaypointCategory.allCases, id: \.self) { category in
                        Label(category.title, systemImage: category.systemImage).tag(Optional(category))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("waypoint-category")
            }
            if !draft.isStart {
                Toggle("Übernachtungsort", isOn: $draft.details.overnight)
                    .toggleStyle(.checkbox)
                    .disabled(draft.protectedOvernight)
                    .accessibilityIdentifier("waypoint-overnight")
                LabeledContent("Besuchsstatus") {
                    Picker("Besuchsstatus", selection: $draft.details.status) {
                        ForEach(VisitStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            if draft.hasStageBudget {
                LabeledContent("Etappenbudget") {
                    TextField("hh:mm", text: $draft.budget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                        .accessibilityLabel("Zeitbudget (hh:mm, optional)")
                        .accessibilityIdentifier("stage-budget-override")
                }
            }
            LabeledContent("Bewertung") {
                Picker("Bewertung", selection: $draft.details.rating) {
                    Text("Keine Bewertung").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) von 5").tag($0) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Notiz")
                TextEditor(text: $draft.details.notes)
                    .frame(height: 48)
                    .accessibilityLabel("Notiz")
                    .accessibilityIdentifier("waypoint-notes")
            }
            if stayMinutes == nil {
                Text("Verweilzeit als hh:mm eingeben, z. B. 00:45 oder 00:00.")
                    .foregroundStyle(.red)
            }
            if !validBudget {
                Text(DurationInputFormat.invalidBudgetMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Abbrechen", action: cancel)
                    .accessibilityIdentifier("cancel-waypoint-details")
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    guard let minutes = stayMinutes, validBudget else { return }
                    save(draft, minutes)
                }
                .disabled(stayMinutes == nil || !validBudget)
                .accessibilityIdentifier("save-waypoint-details")
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-waypoint-details")
    }
}

private struct InlineStageBudgetEditor: View {
    @ObservedObject var draft: WaypointEditorDraft
    let save: (WaypointEditorDraft, Int?) -> Void
    let cancel: () -> Void

    private var valid: Bool { draft.budget.isEmpty || DurationInputFormat.minutes(draft.budget) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Etappenbudget") {
                TextField("hh:mm", text: $draft.budget)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                    .accessibilityLabel("Etappenbudget (hh:mm, optional)")
                    .accessibilityIdentifier("stage-budget-input")
            }
            Text(valid ? "Leer lassen, um das Standardbudget zu übernehmen." : DurationInputFormat.invalidBudgetMessage)
                .foregroundStyle(valid ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Abbrechen", action: cancel)
                    .accessibilityIdentifier("cancel-stage-budget")
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { save(draft, DurationInputFormat.minutes(draft.budget)) }
                    .disabled(!valid)
                    .accessibilityIdentifier("save-stage-budget")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-stage-budget")
    }
}

enum DurationInputFormat {
    static let invalidBudgetMessage = "Gib eine Dauer größer als 00:00 ein, z. B. 06:30. Minuten: 00 bis 59."

    static func string(_ minutes: Int) -> String {
        String(format: "%02ld:%02ld", minutes / 60, minutes % 60)
    }

    static func minutes(_ input: String, allowsZero: Bool = false) -> Int? {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60,
              hours <= (Int.max - minutes) / 60 else { return nil }
        let total = hours * 60 + minutes
        return total > 0 || allowsZero ? total : nil
    }
}

private struct StageBudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    let save: (Int?) -> Void

    init(minutes: Int?, save: @escaping (Int?) -> Void) {
        _input = State(initialValue: minutes.map(DurationInputFormat.string) ?? "")
        self.save = save
    }

    private var valid: Bool { input.isEmpty || DurationInputFormat.minutes(input) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Standard-Zeitbudget pro Etappe").font(.headline)
            TextField("Stunden:Minuten (hh:mm)", text: $input)
                .accessibilityIdentifier("default-stage-budget-input")
            Text(valid ? "Beispiel: 06:30. Leer lassen, um kein Standardbudget zu setzen." : DurationInputFormat.invalidBudgetMessage)
                .font(.caption)
                .foregroundStyle(valid ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { save(DurationInputFormat.minutes(input)) }
                    .disabled(!valid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct TransitChangeConfirmation: ViewModifier {
    @Binding var action: (() -> Void)?
    var message = "Wenn markierte Punkte nicht mehr benachbart sind, werden ihre ÖPNV-Markierungen entfernt."

    func body(content: Content) -> some View {
        content.alert("Routenänderung bestätigen?", isPresented: Binding(
            get: { action != nil },
            set: { if !$0 { action = nil } }
        )) {
            Button("Änderung durchführen") {
                let change = action
                action = nil
                change?()
            }
            Button("Abbrechen", role: .cancel) { action = nil }
        } message: {
            Text(message)
        }
    }
}

private struct TripEditorDraft: Identifiable {
    let id = UUID()
    let tripID: RoadTrip.ID?
    var name: String
    var notes: String
    var hasDepartureDate: Bool
    var departureDate: Date
    var isRoundTrip: Bool
    let originalIsRoundTrip: Bool

    init(trip: RoadTrip? = nil) {
        tripID = trip?.id
        name = trip?.name ?? ""
        notes = trip?.notes ?? ""
        hasDepartureDate = trip?.departureDate != nil
        departureDate = trip?.departureDate ?? Date()
        isRoundTrip = trip?.waypoints.isRoundTrip ?? false
        originalIsRoundTrip = isRoundTrip
    }
}

private struct TripEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State var draft: TripEditorDraft
    @State private var showTypeChangeConfirmation = false
    let onSave: (String, String, Date?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.tripID == nil ? "Neue Reise" : "Reise bearbeiten")
                .font(.headline)
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("trip-name")
                .focused($nameIsFocused)
            Picker("Routentyp", selection: $draft.isRoundTrip) {
                Text("Start–Ziel").tag(false)
                Text("Rundtour").tag(true)
            }
            .accessibilityIdentifier("trip-type")
            Text("Beschreibung")
            TextEditor(text: $draft.notes)
                .accessibilityLabel("Beschreibung")
                .frame(minHeight: 100)

            Toggle("Reisestart festlegen", isOn: $draft.hasDepartureDate)
                .accessibilityIdentifier("trip-has-departure-date")
            if draft.hasDepartureDate {
                DatePicker("Startdatum und -zeit", selection: $draft.departureDate,
                           displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("trip-departure-date-picker")
                Text("MapKit erhält diesen Zeitpunkt für alle Teilstrecken. Spätere Etappen und Aufenthalte werden zeitlich nicht berücksichtigt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    if draft.tripID != nil && draft.isRoundTrip != draft.originalIsRoundTrip {
                        showTypeChangeConfirmation = true
                    } else {
                        save()
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .defaultFocus($nameIsFocused, true)
        .padding()
        .frame(width: 400)
        .alert("Routentyp ändern?", isPresented: $showTypeChangeConfirmation) {
            Button("Routentyp ändern") { save() }
                .accessibilityIdentifier("confirm-trip-type-change")
            Button("Abbrechen", role: .cancel) {}
                .accessibilityIdentifier("cancel-trip-type-change")
        } message: {
            Text(draft.isRoundTrip
                 ? "Alle Unterkunftstouren und ihre Wegpunkte werden in ihrer bisherigen Reihenfolge in eine einzige Rundtour übernommen. Das bisherige Ziel bleibt Zwischenpunkt; die Route endet am Start. Übernachtungsgrenzen entfallen, der erste Modus gilt für die gesamte Tour, explizite Budgets werden addiert und frühere Budgetbestätigungen zurückgesetzt. Weiterhin benachbarte ÖPNV-Markierungen und Fotozuordnungen bleiben erhalten; andere müssen gegebenenfalls überprüft werden."
                 : "Der Rückweg zum Start entfällt. Der letzte Zwischenpunkt wird zum Ziel; ohne Zwischenpunkt muss ein neues Ziel gewählt werden. Zuordnungen und ÖPNV-Markierungen des entfallenden Rückwegs können ungültig werden.")
        }
    }

    private func save() {
        onSave(draft.name, draft.notes, draft.hasDepartureDate ? draft.departureDate : nil,
               draft.isRoundTrip)
    }
}
