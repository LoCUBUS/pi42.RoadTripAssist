import MapKit
import SwiftUI

struct TripPlannerView: View {
    @StateObject private var library = TripLibrary()

    var body: some View {
        TripWorkspaceView(library: library, model: library.planner)
    }
}

private struct TripWorkspaceView: View {
    @ObservedObject var library: TripLibrary
    @ObservedObject var model: TripPlannerViewModel
    @FocusState private var focusedWaypoint: WaypointField?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showRoutingConfirmation = false
    @State private var editor: TripEditorDraft?
    @State private var tripToDelete: RoadTrip?

    var body: some View {
        HStack(spacing: 0) {
            tripSidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            Divider()
            mapView
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
            cameraPosition = .automatic
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
        }
        .mapStyle(.standard(elevation: .realistic))
        .onChange(of: model.roadPreview != nil) { _, hasPreview in
            if hasPreview { cameraPosition = .automatic }
        }
    }

    private var routeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Route planen")
                    .font(.title2.bold())
                Text("Suche und Routing benötigen Internet und senden Suchtext bzw. Wegpunkt-Koordinaten an Apple.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            List {
                Section("Wegpunkte") {
                    waypointSearch(.start, title: "Start", icon: "1.circle")
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { index, stop in
                        waypointSearch(.stop(stop.id), title: "Zwischenziel \(index + 1)", icon: "mappin") {
                            if focusedWaypoint == .stop(stop.id) { focusedWaypoint = nil }
                            model.removeStop(stop)
                        }
                    }
                    if model.searchField == .newStop {
                        waypointSearch(.newStop, title: "Neues Zwischenziel", icon: "mappin")
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
                    waypointSearch(.destination, title: "Ziel", icon: "flag")
                }
            }
            .listStyle(.inset)

            VStack(alignment: .leading, spacing: 8) {
                if model.hasEndpoints {
                    if model.isProvisional {
                        Text("Noch nicht nach Fahrzeit bestätigt")
                    }

                    if let preview = model.roadPreview {
                        Text("Geschätzte Fahrzeit: \(formatDuration(preview.duration))")
                    }
                    if let proposal = model.suggestion {
                        Text("Vorschlag: \(proposal.orderedStops.map(\.name).joined(separator: " → "))")
                        if let preview = model.roadPreview {
                            Text("Ca. \(formatDuration(preview.duration - proposal.duration)) weniger Fahrzeit")
                        } else {
                            Text("Geschätzte Fahrzeit: \(formatDuration(proposal.duration))")
                        }
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

    private func waypointSearch(_ field: WaypointField, title: String, icon: String,
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
                } else if model.searchFinished && model.searchResults.isEmpty {
                    Text("Keine passenden Orte gefunden.").foregroundStyle(.secondary)
                }
                ForEach(model.searchResults.prefix(5)) { result in
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
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func choose(_ result: RoadStop, in field: WaypointField) {
        if model.chooseSearchResult(result, in: field) {
            focusedWaypoint = nil
            focusMap(on: result)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        guard totalMinutes >= 60 else { return "\(totalMinutes) min" }
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
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
