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
    @State private var showSuggestionOnMap = false
    @State private var showAlternativeConnections = false
    @State private var selectedAlternativeConnection: RouteConnection.ID?
    @State private var showAlternativePopover = false
    @State private var showSuggestionPopover = false
    @State private var waypointEditor: WaypointEditorDraft?
    @State private var pendingWaypointAction: WaypointEditorAction?
    @State private var showDiscardWaypointChanges = false
    @State private var showDefaultBudget = false
    @State private var showPhotoLibrary = false
    @State private var presentedMapPhotoID: TripPhoto.ID?
    @State private var overrunStage: TripStage?
    @State private var stageStopToRemove: RoadStop?
    @State private var showRouteInspector = true

    private var mapStage: TripStage? {
        guard let mapStageID else { return nil }
        return model.stages.first { $0.id == mapStageID }
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
        .onChange(of: library.selectedID) { _, _ in
            focusedWaypoint = nil
            clearMapPOI()
            showStages = false
            mapStageID = nil
            showSuggestionOnMap = false
            showAlternativeConnections = false
            selectedAlternativeConnection = nil
            presentedMapPhotoID = nil
            showAlternativePopover = false
            showSuggestionPopover = false
            waypointEditor = nil
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
            if status != .failed { showRoutingDiagnostics = false }
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
            TripEditorView(draft: draft) { name, notes, departureDate in
                library.updateTrip(id: draft.tripID, name: name, notes: notes, departureDate: departureDate)
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
            if waypointEditor?.hasChanges == true && trip.id == library.selectedID {
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
            Text(waypointEditor?.isStageBudget == true
                 ? "Das Etappenbudget wurde noch nicht gespeichert."
                 : "Die Änderungen an diesem Wegpunkt wurden noch nicht gespeichert.")
        }
        .alert("Fahrzeit mit Apple MapKit berechnen?", isPresented: $showRoutingConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren") {
                model.enableAutomaticRouting()
            }
        } message: {
            Text("Nach Änderungen an den Wegpunkten berechnet MapKit automatisch die Straßenroute in der aktuellen Reihenfolge. Eine Optimierung weiterer Reihenfolgen startest du separat. Dabei werden Koordinaten und ein gegebenenfalls festgelegter Reisestart an Apple gesendet. Du kannst die Berechnung jederzeit pausieren.")
        }
        .alert("Apple Karten konnte nicht geöffnet werden", isPresented: $showMapsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Das Ziel konnte nicht an Apple Karten übergeben werden.")
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
            if waypointEditor?.id == stop.id && waypointEditor?.hasChanges == true
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
                Text("Du erreichst „\(stage.end.name)“ voraussichtlich \(overrun.arrivalMinutes - overrun.budgetMinutes) min nach dem Zeitbudget. Der Budgetpunkt und der Suchkreis werden ausgeblendet. Die Route bleibt unverändert.")
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
                        Text(trip.name).tag(trip.id)
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
                    Button("Bearbeiten") { editor = TripEditorDraft(trip: trip) }
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
        let waypoints = stage?.waypoints ?? model.orderedWaypoints
        let trip = library.selectedTrip
        let photosByWaypoint = overlappingPhotosByWaypoint(waypoints: waypoints, photos: trip?.photos ?? [])
        let clusteredPhotoIDs = Set(photosByWaypoint.values.flatMap { $0.map(\.id) })
        let visibleStages = showStages && !showSuggestionOnMap ? (stage.map { [$0] } ?? model.stages) : []
        return MapReader { proxy in
            Map(position: $cameraPosition) {
                let coordinates = stage?.coordinates
                    ?? (showSuggestionOnMap ? model.suggestion?.coordinates : model.roadPreview?.coordinates)
                    ?? []
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, lineWidth: 4)
                }
                if model.roadPreview == nil && !showSuggestionOnMap {
                    let visibleIDs = Set(waypoints.map(\.id))
                    ForEach(model.currentConnections.filter {
                        visibleIDs.contains($0.from.id) && visibleIDs.contains($0.to.id)
                    }) { connection in
                        if connection.leg.coordinates.count >= 2 {
                            MapPolyline(coordinates: connection.leg.coordinates)
                                .stroke(.blue, lineWidth: 4)
                        }
                    }
                }
                if showAlternativeConnections {
                    ForEach(availableAlternativeConnections.filter {
                        selectedAlternativeConnection == nil || $0.id == selectedAlternativeConnection
                    }) { connection in
                        if connection.leg.coordinates.count >= 2 {
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
                    let appearance = waypointAppearance(for: stop)
                    Marker(stop.name, systemImage: appearance.systemImage, coordinate: stop.coordinate)
                        .tint(appearance.color)
                    if let trip, let photos = photosByWaypoint[stop.id], !photos.isEmpty {
                        Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                            WaypointPhotoOverlapAnnotation(
                                waypoint: stop,
                                photos: photos,
                                library: library,
                                model: model,
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
                                    TripPhotoDetailPopover(library: library, model: model,
                                                           tripID: trip.id, photoID: photo.id) {
                                        presentedMapPhotoID = nil
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(model.searchResults.prefix(5)) { result in
                    Marker(result.name, coordinate: result.coordinate)
                        .tint(.orange)
                }
                ForEach(model.parkingSuggestions) { parking in
                    Marker(parking.name, systemImage: "parkingsign.circle", coordinate: parking.coordinate)
                        .tint(.orange)
                }
                if let selectedPOI, !model.hasMapPlace(selectedPOI.stop) {
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
            if showSuggestionOnMap || showAlternativeConnections {
                VStack(alignment: .leading) {
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
                .allowsHitTesting(false)
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
                Button("Zur Route hinzufügen", systemImage: "plus.circle") { model.addMapPOI(poi.stop) }
                    .accessibilityIdentifier("add-map-poi")
                Button("Als Übernachtung hinzufügen", systemImage: "bed.double") {
                    model.addMapPOI(poi.stop, asOvernight: true)
                }
                .accessibilityIdentifier("add-map-poi-overnight")
            }
            .disabled(!canAdd)
            if alreadyInRoute {
                Text("Bereits in der Route").foregroundStyle(.secondary)
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
                Section("Wegpunkte") {
                    waypointSearch(.start, title: "Start", icon: "play.fill", id: "start")
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { index, stop in
                        waypointSearch(.stop(stop.id), title: "Zwischenziel \(index + 1)", icon: "mappin",
                                       id: "stop-\(index + 1)") {
                            if focusedWaypoint == .stop(stop.id) { focusedWaypoint = nil }
                            model.removeStop(stop)
                        }
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
                    waypointSearch(.destination, title: "Ziel", icon: "flag.checkered", id: "destination")
                    if model.manualOrder {
                        Button("Nach Luftlinie sortieren", action: model.useProvisionalOrder)
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = model.roadPreview {
                HStack {
                    Text("Fahrzeit: ca. \(formatDuration(preview.duration))")
                    Spacer(minLength: 4)
                    Text("Strecke: \(formatDistance(preview.distance))")
                        .accessibilityIdentifier("route-distance")
                }
            } else if !model.hasEndpoints {
                Text("Start und Ziel wählen.")
            }
            if model.hasEndpoints && !model.stops.isEmpty {
                Text("\(model.manualOrder ? "Fixiert" : "Luftlinien-Reihenfolge") · \(model.isProvisional ? "nicht optimiert" : "fahrzeitgeprüft")")
                    .foregroundStyle(.secondary)
            }
            routeCalculationStatus
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
                        model.acceptSuggestion()
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
    }

    private var optimizationHelp: String {
        if !model.hasEndpoints { return "Start und Ziel für die Optimierung wählen" }
        if model.stops.isEmpty { return "Für die Optimierung ein Zwischenziel hinzufügen" }
        if !model.automaticRouting { return "Automatische Berechnung für die Optimierung aktivieren" }
        if model.isOptimizing { return "Berechnung läuft" }
        return "Reihenfolge nach Fahrzeit optimieren"
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
            Text("Fahrzeit: ca. \(formatDuration(proposal.duration)) · Strecke: \(formatDistance(proposal.distance))")
            if let preview = model.roadPreview {
                Text("Ca. \(formatDuration(preview.duration - proposal.duration)) weniger Fahrzeit")
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
                        ForEach(Array(model.stages.enumerated()), id: \.element.id) { index, stage in
                            let placeholder = stage.budgetPlaceholder
                            Section {
                                stageSummary(stage, number: index + 1)
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
                                            Text("Etappe \(index + 1): \(stage.end.name)")
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
                Text("Etappenzeit: \(formatDuration(total)) · davon Fahrt: \(formatDuration(drive))")
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("stage-totals-\(number)")
            } else {
                Text("Etappenzeit: \(formatDuration(stage.stayMinutes * 60)) + ausstehende Fahrzeit")
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
                Button("Übernachtung \(overrun.arrivalMinutes - overrun.budgetMinutes) min nach Budget bestätigen") {
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
                .disabled(waypointEditor?.id == stop.id)
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
            }
        }
    }

    private func waypointAppearance(for stop: RoadStop) -> WaypointAppearance {
        WaypointAppearance(details: model.waypointDetails(for: stop),
                           isStart: stop == model.start, isDestination: stop == model.destination)
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
        if waypointEditor?.hasChanges == true {
            pendingWaypointAction = action
            showDiscardWaypointChanges = true
        } else {
            performWaypointAction(action)
        }
    }

    private func performWaypointAction(_ action: WaypointEditorAction) {
        waypointEditor = nil
        switch action {
        case .close:
            break
        case .open(let stop):
            waypointEditor = WaypointEditorDraft(stop: stop, details: model.waypointDetails(for: stop),
                                                  isStart: stop == model.start, isDestination: stop == model.destination)
        case .openStageBudget(let stop):
            waypointEditor = WaypointEditorDraft(stop: stop, details: model.waypointDetails(for: stop),
                                                  isStart: stop == model.start, isDestination: stop == model.destination,
                                                  isStageBudget: true)
        case .selectTrip(let id):
            library.select(id)
        case .newTrip:
            editor = TripEditorDraft()
        case .showRoute:
            showStages = false
        }
    }

    private func showStageOnMap(_ id: RoadStop.ID?) {
        clearMapPOI()
        mapStageID = id
        showSuggestionOnMap = false
        cameraPosition = .automatic
    }

    @ViewBuilder
    private var routeCalculationStatus: some View {
        switch model.routeStatus {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("Route wird vorbereitet …")
        case let .running(.streetRoute(done, total)):
            routeStepProgress("Straßenroute", done: done, total: total)
        case let .running(.alternativeLegs(done, total)):
            routeStepProgress("Alternative Verbindungen", done: done, total: total)
        case .running(.comparingOrders):
            ProgressView("Reihenfolgen vergleichen …")
        case .finished:
            if model.suggestion != nil {
                Label("Vorschlag bereit", systemImage: "checkmark.circle")
            } else if model.stops.isEmpty || model.isProvisional {
                Label("Straßenroute berechnet", systemImage: "checkmark.circle")
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
            .popover(isPresented: $showRoutingDiagnostics, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Routenfehler – Diagnose").font(.headline)
                    Text("Die Angaben bleiben lokal und können Standortdaten enthalten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(model.routingDiagnostic ?? "Keine Diagnose verfügbar.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("routing-diagnostics-details")
                    }
                    Button("Schließen") { showRoutingDiagnostics = false }
                }
                .padding()
                .frame(width: 520, height: 420)
            }
            ForEach(model.unavailableConnections) { connection in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ohne Autoroute:").foregroundStyle(.red)
                    Button("Von: \(connection.from.name)") { focusWaypoint(on: connection.from) }
                    Button("Nach: \(connection.to.name)") { focusWaypoint(on: connection.to) }
                }
            }
            Button("Erneut versuchen", action: model.retryRouting)
            if !model.unavailableConnections.isEmpty {
                parkingSuggestions
            }
        }
    }

    private var parkingSuggestions: some View {
        let affectedIDs = Set(model.unavailableConnections.flatMap { [$0.from.id, $0.to.id] })
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
                            model.moveStop(stop, by: -1)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("move-up-\(id)")
                        .disabled(index == 0)
                        Button("Zwischenziel nach unten", systemImage: "arrow.down") {
                            model.moveStop(stop, by: 1)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(index == model.stops.count - 1)
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
                }
            }
            if let stop {
                let details = model.waypointDetails(for: stop)
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
                .accessibilityIdentifier("waypoint-summary-\(id)")
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
        if model.chooseSearchResult(result, in: field) {
            focusedWaypoint = nil
            if fixturePOI == nil { focusMap(on: result) }
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

    private func openInMaps(_ stop: RoadStop) {
        let item = MapKitRouteService.mapItem(for: stop)
        if !launchMaps(item, [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]) {
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
    case close, open(RoadStop), openStageBudget(RoadStop), selectTrip(RoadTrip.ID), newTrip, showRoute
}

private final class WaypointEditorDraft: ObservableObject, Identifiable {
    var id: RoadStop.ID { stop.id }
    let stop: RoadStop
    let original: WaypointDetails
    let isStart: Bool
    let isDestination: Bool
    let isStageBudget: Bool
    @Published var details: WaypointDetails
    @Published var stay: String
    @Published var budget: String

    init(stop: RoadStop, details: WaypointDetails, isStart: Bool, isDestination: Bool, isStageBudget: Bool = false) {
        self.stop = stop
        self.original = details
        self.isStart = isStart
        self.isDestination = isDestination
        self.isStageBudget = isStageBudget
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

private struct TripEditorDraft: Identifiable {
    let id = UUID()
    let tripID: RoadTrip.ID?
    var name: String
    var notes: String
    var hasDepartureDate: Bool
    var departureDate: Date

    init(trip: RoadTrip? = nil) {
        tripID = trip?.id
        name = trip?.name ?? ""
        notes = trip?.notes ?? ""
        hasDepartureDate = trip?.departureDate != nil
        departureDate = trip?.departureDate ?? Date()
    }
}

private struct TripEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State var draft: TripEditorDraft
    let onSave: (String, String, Date?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.tripID == nil ? "Neue Reise" : "Reise bearbeiten")
                .font(.headline)
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("trip-name")
                .focused($nameIsFocused)
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
                    onSave(draft.name, draft.notes, draft.hasDepartureDate ? draft.departureDate : nil)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .defaultFocus($nameIsFocused, true)
        .padding()
        .frame(width: 400)
    }
}
