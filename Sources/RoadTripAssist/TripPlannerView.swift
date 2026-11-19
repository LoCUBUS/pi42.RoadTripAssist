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
            showMap = fixturePOI != nil
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
    }
}

private struct TripWorkspaceView: View {
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
    @State private var showMapsError = false
    @State private var editor: TripEditorDraft?
    @State private var tripToDelete: RoadTrip?

    var body: some View {
        HStack(spacing: 0) {
            tripSidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            Divider()
            Group {
                if showMap { mapView }
                else { Color.clear }
            }
            .overlay(alignment: .topTrailing) {
                if let selectedPOI { poiDetails(selectedPOI).padding(12) }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Group {
                if library.selectedID != nil {
                    routeSidebar
                } else {
                    ContentUnavailableView("Keine Reise ausgewählt", systemImage: "map",
                                           description: Text("Lege links eine Reise an, um eine Route zu planen."))
                }
            }
            .frame(minWidth: 320, idealWidth: 370, maxWidth: 440)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .onChange(of: library.selectedID) { _, _ in
            focusedWaypoint = nil
            clearMapPOI()
            if fixturePOI == nil { cameraPosition = .automatic }
        }
        .onChange(of: focusedWaypoint) { _, field in
            if let field { model.beginSearch(in: field) }
        }
        .sheet(item: $editor) { draft in
            TripEditorView(draft: draft) { name, notes in
                library.updateTrip(id: draft.tripID, name: name, notes: notes)
                editor = nil
            }
        }
        .alert("Reise löschen?", isPresented: Binding(
            get: { tripToDelete != nil },
            set: { if !$0 { tripToDelete = nil } }
        ), presenting: tripToDelete) { trip in
            Button("Löschen", role: .destructive) { library.delete(trip.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { trip in
            Text("„\(trip.name)“ und ihre Wegpunkte werden von diesem Mac gelöscht.")
        }
        .alert("Fahrzeit mit Apple MapKit berechnen?", isPresented: $showRoutingConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren") {
                model.enableAutomaticRouting()
            }
        } message: {
            Text("Nach Änderungen an den Wegpunkten berechnet MapKit automatisch eine Straßenroute und prüft andere Reihenfolgen. Dabei werden Koordinaten an Apple gesendet. Du kannst die Berechnung jederzeit pausieren.")
        }
        .alert("Apple Karten konnte nicht geöffnet werden", isPresented: $showMapsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Das Ziel konnte nicht an Apple Karten übergeben werden.")
        }
    }

    private var tripSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reisen")
                .font(.title2.bold())
            Button {
                editor = TripEditorDraft()
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
                    set: { if let id = $0 { library.select(id) } }
                )) {
                    ForEach(library.trips) { trip in
                        Text(trip.name).tag(trip.id)
                    }
                }
                .listStyle(.sidebar)
            }

            if let trip = library.selectedTrip {
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
            }
            if let error = library.saveError {
                Text("Änderungen sind noch nicht gespeichert: \(error)")
                    .foregroundStyle(.red)
                Button("Erneut speichern", action: library.save)
            }
            if library.trips.isEmpty { Spacer() }
        }
        .padding()
    }

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let route = model.roadPreview {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(.blue, lineWidth: 4)
                }
                ForEach(model.orderedWaypoints) { stop in
                    Marker(stop.name, coordinate: stop.coordinate)
                }
                ForEach(model.searchResults.prefix(5)) { result in
                    Marker(result.name, coordinate: result.coordinate)
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
        VStack(alignment: .leading, spacing: 8) {
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
            Button("Zur Route hinzufügen", systemImage: "plus.circle") { model.addMapPOI(poi.stop) }
                .accessibilityIdentifier("add-map-poi")
                .disabled(library.selectedID == nil || !model.hasEndpoints || model.hasMapPlace(poi.stop))
            if model.hasMapPlace(poi.stop) {
                Text("Bereits in der Route").foregroundStyle(.secondary)
            } else if library.selectedID == nil || !model.hasEndpoints {
                Text("Wähle eine Reise mit Start und Ziel.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 255, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }

    private var routeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Route planen")
                    .font(.title2.bold())
                Text("Ortssuche und Routing benötigen Internet. Suchtext, angeklickte Kartenpositionen und Wegpunkt-Koordinaten werden an Apple gesendet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            List {
                Section("Wegpunkte") {
                    waypointSearch(.start, title: "Start", icon: "1.circle", id: "start")
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
                    waypointSearch(.destination, title: "Ziel", icon: "flag", id: "destination")
                    if model.manualOrder {
                        Button("Nach Luftlinie sortieren", action: model.useProvisionalOrder)
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)

            VStack(alignment: .leading, spacing: 8) {
                if model.hasEndpoints {
                    if model.manualOrder {
                        Text("Manuelle Reihenfolge")
                    }
                    if model.isProvisional {
                        Text("Noch nicht nach Fahrzeit bestätigt")
                    }

                    if let preview = model.roadPreview {
                        Text("Geschätzte Fahrzeit: \(formatDuration(preview.duration))")
                        Text("Strecke: \(formatDistance(preview.distance))")
                            .accessibilityIdentifier("route-distance")
                    }
                    if let proposal = model.suggestion {
                        Text("Vorschlag: \(proposal.orderedStops.map(\.name).joined(separator: " → "))")
                        if let preview = model.roadPreview {
                            Text("Ca. \(formatDuration(preview.duration - proposal.duration)) weniger Fahrzeit")
                        } else {
                            Text("Geschätzte Fahrzeit: \(formatDuration(proposal.duration))")
                        }
                        Text("Strecke des Vorschlags: \(formatDistance(proposal.distance))")
                        Button("Vorschlag übernehmen", action: model.acceptSuggestion)
                    }
                } else {
                    Text("Zuerst Start und Ziel wählen, dann Zwischenstädte hinzufügen.")
                }
                routeCalculationStatus
                if model.automaticRouting {
                    Button("Automatische Berechnung pausieren", action: model.pauseRouting)
                } else {
                    Button("Automatische Berechnung aktivieren") {
                        showRoutingConfirmation = true
                    }
                    .disabled(!model.hasEndpoints)
                }
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding(.top)
    }

    @ViewBuilder
    private var routeCalculationStatus: some View {
        switch model.routeStatus {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("Routenberechnung wird vorbereitet …")
        case let .running(.streetRoute(done, total)):
            routeStepProgress("Straßenroute in aktueller Reihenfolge berechnen", done: done, total: total)
        case let .running(.alternativeLegs(done, total)):
            routeStepProgress("Fahrzeiten für alternative Verbindungen ermitteln", done: done, total: total)
        case .running(.comparingOrders):
            ProgressView("Reihenfolgen nach Fahrzeit vergleichen …")
        case .finished:
            if model.suggestion != nil {
                Label("Neue Reihenfolge zur Übernahme bereit", systemImage: "checkmark.circle")
            } else if model.stops.isEmpty {
                Label("Straßenroute berechnet", systemImage: "checkmark.circle")
            } else {
                Label("Reihenfolge nach Fahrzeit geprüft", systemImage: "checkmark.circle")
            }
        case .paused:
            Label("Berechnung pausiert", systemImage: "pause.circle")
        case .failed:
            Text(model.roadPreview == nil
                 ? "Straßenroute nicht verfügbar. Berechnung fehlgeschlagen."
                 : "Straßenroute verfügbar. Optimierung nicht abgeschlossen.")
                .fontWeight(.semibold)
            if let error = model.routingError {
                Text(error).foregroundStyle(.red)
            }
            Button("Erneut versuchen", action: model.enableAutomaticRouting)
        }
    }

    private func routeStepProgress(_ title: LocalizedStringKey, done: Int, total: Int) -> some View {
        ProgressView(value: Double(done), total: Double(total)) {
            Text(title).fontWeight(.semibold)
        } currentValueLabel: {
            Text("\(done) von \(total) neuen MapKit-Abfragen")
                .foregroundStyle(.secondary)
        }
    }

    private func waypointSearch(_ field: WaypointField, title: String, icon: String, id: String,
                                remove: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
                    Button("In Apple Karten öffnen", systemImage: "map") {
                        openInMaps(stop)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("open-maps-\(id)")
                }
                if let remove {
                    Button("Zwischenziel entfernen", systemImage: "minus.circle", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
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

    private func openInMaps(_ stop: RoadStop) {
        let item = MapKitRouteService.mapItem(for: stop)
        if !launchMaps(item, [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]) {
            showMapsError = true
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
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

private struct TripEditorDraft: Identifiable {
    let id = UUID()
    let tripID: RoadTrip.ID?
    var name: String
    var notes: String

    init(trip: RoadTrip? = nil) {
        tripID = trip?.id
        name = trip?.name ?? ""
        notes = trip?.notes ?? ""
    }
}

private struct TripEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State var draft: TripEditorDraft
    let onSave: (String, String) -> Void

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

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { onSave(draft.name, draft.notes) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .defaultFocus($nameIsFocused, true)
        .padding()
        .frame(width: 400)
    }
}
