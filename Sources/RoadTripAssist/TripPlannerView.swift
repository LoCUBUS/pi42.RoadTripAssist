import MapKit
import SwiftUI

struct TripPlannerView: View {
    @StateObject private var model = TripPlannerViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showRoutingConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            tripSidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            Divider()
            mapView
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            routeSidebar
                .frame(minWidth: 320, idealWidth: 370, maxWidth: 440)
        }
        .frame(minWidth: 1000, minHeight: 650)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("RoadTripAssist")
                .font(.title2.bold())
            Label("Neue Reise", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
            Text("Phase-0-Prototyp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Diese technische Probe testet MapKit-Suche, Routing und die Kosten einer Zwischenstopp-Optimierung.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            ForEach(model.searchResults) { result in
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
            Text("Route planen")
                .font(.title2.bold())
            HStack {
                TextField("Ort oder POI suchen", text: $model.query)
                    .onSubmit(model.search)
                Button("Suchen", action: model.search)
                    .disabled(model.isSearching)
            }
            Text("Suche und Routing benötigen Internet und senden Suchtext bzw. Wegpunkt-Koordinaten an Apple.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.isSearching {
                ProgressView("Suche läuft …")
                    .controlSize(.small)
            }

            List {
                if !model.searchResults.isEmpty {
                    Section("Suchergebnisse") {
                        ForEach(model.searchResults) { result in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.name)
                                    .font(.headline)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack {
                                    Button("Start") {
                                        model.setStart(result)
                                        focusMap(on: result)
                                    }
                                    .disabled(!model.canUseAsStart(result))
                                    Button("+ Stopp") {
                                        model.addStop(result)
                                        focusMap(on: result)
                                    }
                                    .disabled(!model.hasEndpoints || model.orderedWaypoints.contains(result))
                                    Button("Ziel") {
                                        model.setDestination(result)
                                        focusMap(on: result)
                                    }
                                    .disabled(!model.canUseAsDestination(result))
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Wegpunkte") {
                    if let start = model.start {
                        Label("Start: \(start.name)", systemImage: "1.circle")
                    } else {
                        Text("Start nicht festgelegt")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { index, stop in
                        HStack {
                            Label("\(index + 1). \(stop.name)", systemImage: "mappin")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                model.removeStop(stop)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if let destination = model.destination {
                        Label("Ziel: \(destination.name)", systemImage: "flag")
                    } else {
                        Text("Ziel nicht festgelegt")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                if model.hasEndpoints {
                    if model.isProvisional {
                        Text("Vorläufige Reihenfolge nach Luftlinie")
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
                if model.isOptimizing {
                    if model.totalRequests > 0 {
                        ProgressView(value: Double(model.completedRequests), total: Double(model.totalRequests)) {
                            Text("MapKit: \(model.completedRequests) / \(model.totalRequests) neue Streckenabschnitte")
                        }
                    } else {
                        ProgressView("Route wird vorbereitet …")
                    }
                }
                if let error = model.routingError {
                    Text(error).foregroundStyle(.red)
                    Button("Erneut versuchen", action: model.enableAutomaticRouting)
                }
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
