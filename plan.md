# RoadTripAssist – Implementierungsplan v0.2

**Status:** Entwurf auf Basis der Nutzerentscheidungen; noch offen ist insbesondere, über welchen Dienst die automatische Fahrzeit-Optimierung berechnet wird.

## 1. Bestätigte Anforderungen

- Native Anwendung ausschließlich für **macOS**.
- Apple Maps/MapKit ist der naheliegende Ausgangspunkt, aber Alternativen sollen vor Festlegung geprüft werden.
- Die Optimierung soll die **Fahrzeit** minimieren und die Zwischenstopps automatisch in eine passende Reihenfolge bringen.
- **Start und Ziel bleiben fest**; optimiert wird die Reihenfolge der Zwischenstopps.
- Erste nutzbare Version: Reisen verwalten, Route und POIs planen, Karte anzeigen und ein Ziel an Apple Maps übergeben. Etappen, Tagebuch und Export folgen danach.
- Reisedaten zunächst lokal auf dem Mac.
- In Phase 0 Google Routes API und Mapbox mit Beispieldaten vergleichen; erst anschließend über einen produktiven externen Routinganbieter und die Übertragung realer Wegpunktkoordinaten entscheiden.
- Foto-GPS-Zuordnung wird vorgeschlagen, aber vom Nutzer bestätigt, nicht stillschweigend ausgeführt.
- Der Export muss offline funktionieren: Übersichtsseite, Unterseite je Etappe und separater Medienordner.

## 2. Karten- und Routingoptionen

Kartenanzeige, POI-Suche, Routenermittlung und Reihenfolgeoptimierung sind verwandte, aber getrennte Aufgaben. Es ist möglich, für Karte/Ortsdaten Apple zu verwenden und für die Optimierung einen externen Dienst einzusetzen; die Bedingungen und Darstellung der jeweiligen Anbieterdaten müssen dabei vorab geprüft werden.

| Option | Stärken | Einschränkungen / zu prüfen |
|---|---|---|
| **Apple MapKit + eigener Optimierer** | Native macOS-Karte, SwiftUI-Integration, Suche und direkte Übergabe an Apple Maps. `MKDirections` liefert Fahrtrouten und Fahrzeit. | `MKDirections` berechnet jeweils eine Anfrage mit Start und Ziel; keine dokumentierte Funktion zur Optimierung einer ganzen Zwischenstopp-Reihenfolge. Für eine gute Optimierung wären viele paarweise Routenanfragen nötig; Apple weist auf Drosselung bei zu vielen Anfragen hin. Bei vielen Stopps können Anfragezahl, Aktualität und Qualität problematisch werden. |
| **Google Maps Platform Routes API** | Unterstützt ausdrücklich das Umordnen von Zwischenstopps zur effizienteren Route, primär auf Fahrzeit ausgerichtet. Hält Start/Ziel fest; gibt optimierte Reihenfolge zurück. | Erfordert API-Key und aktivierte Abrechnung; Waypoint-Optimierung wird höher abgerechnet. Routenkoordinaten gehen an Google. Der Maps SDK, den die offizielle Dokumentation beschreibt, ist für iOS, nicht als native macOS-Kartenansicht. Eine Google-Karte in einer macOS-App wäre daher gesondert (z. B. Webansicht) zu evaluieren. |
| **Mapbox Optimization API** | Bietet eine auf Dauer optimierte Fahrroute; unterstützt Fahrprofile einschließlich Verkehr. Festen Start und Ziel kann man angeben. | Optimization v1 ist auf 12 Koordinaten pro Anfrage begrenzt. API-Aufruf, Token, Abrechnung und Übermittlung der Koordinaten an Mapbox erforderlich. Mapbox' dokumentiertes Maps SDK ist auf iOS ausgerichtet, nicht eine native macOS-Ansicht. |
| **OpenStreetMap-basierte Routingdienste** | Potenziell flexiblere Daten-/Hostingwahl; Dienste wie GraphHopper oder openrouteservice können als Routing-Alternativen evaluiert werden. | OpenStreetMap ist die Kartendatenbasis, kein einzelnes fertiges Routingprodukt. Kartenkacheln, Geocoding, Routing/Optimierung, Hosting, Aktualisierung und Lizenzpflichten müssen separat geklärt werden. Mehr Betriebs- und Integrationsaufwand. |

### Vorläufige Empfehlung

Für eine native macOS-App zuerst **MapKit für Karte, Suche und POI-Auswahl prototypisieren**. Die Fahrzeit-Optimierung nicht vorab als „Apple kann das schon“ einplanen: im Machbarkeitsschritt mit realistischen Stopps vergleichen:

1. MapKit-Routenzeit zwischen Stopppaaren abrufen und die Reihenfolge lokal berechnen.
2. Google Routes API und Mapbox Optimization API mit denselben Beispieldaten vergleichen.

Danach anhand von Routengüte, Anfragelimits, Preis, Datenschutz und Nutzungsbedingungen entscheiden. Google ist derzeit die klarste dokumentierte Option für automatisches Sortieren von Wegpunkten; das macht es aber nicht automatisch zur passenden Gesamt-Kartenlösung.

**Wichtige Trennung:** „lokal“ beschreibt hier zunächst die Speicherung. Karten- und Routinganfragen benötigen Internet und übertragen Ortskoordinaten an den jeweiligen Anbieter. Falls auch Ortsdaten strikt auf dem Gerät bleiben müssen, ist das eine zusätzliche Anforderung und schränkt die praktikablen Routingoptionen ein.

### Referenzdokumentation

- [Apple MapKit – MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections.md)
- [Apple MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui)
- [Google Routes API – Waypoint optimization](https://developers.google.com/maps/documentation/routes/opt-way)
- [Google Routes API – Usage and billing](https://developers.google.com/maps/documentation/routes/usage-and-billing)
- [Google Maps SDK for iOS – Setup](https://developers.google.com/maps/documentation/ios-sdk/config)
- [Mapbox Optimization API v1](https://docs.mapbox.com/api/navigation/optimization-v1/)
- [Mapbox Maps SDK for iOS](https://docs.mapbox.com/ios/maps/guides/)

## 3. MVP und Funktionsumfang

### MVP – durchgängige erste Nutzung
- Reisen mit Name und Beschreibung anlegen, auswählen, umbenennen und löschen.
- Start, Ziel und Zwischenstopps suchen und auswählen.
- Ungefähre Orte in konkrete POIs umwandeln.
- Zwischenstopps für minimale **geschätzte Gesamtfahrzeit** sortieren; Start und Ziel bleiben fix.
- Die optimierte Reihenfolge in Liste und Karte darstellen; Nutzer kann sie übernehmen oder manuell korrigieren.
- Fahrtzeit/Distanz anzeigen und als Schätzung kennzeichnen.
- Ein ausgewähltes oder nächstes Ziel an Apple Maps übergeben.
- Reise lokal speichern und nach einem Neustart wieder öffnen.

### Nach dem MVP
- Etappen mit frei wählbarem Zeitbudget und Übernachtungs-POI.
- Reiseablauf mit Überspringen, Notizen und Bewertungen.
- Fotoimport, GPS-Zuordnung mit Bestätigung und lokale Medienverwaltung.
- Offline-HTML-Reisetagebuch mit Übersichts- und Etappenseiten.

**Optimierungsannahme für den Start:** Alle Zwischenstopps sind zunächst frei umsortierbar; keine Öffnungszeiten, Zeitfenster, Prioritäten oder Übernachtungszwänge. Wenn Etappen und feste Übernachtungsorte später hinzukommen, werden diese als feste Anker behandelt und nur Stopps innerhalb der jeweiligen Etappe optimiert. Optimierungsergebnisse bleiben überprüfbar und manuell änderbar.

## 4. UX-Entwurf

```text
┌────────────────────┬───────────────────────────────────┬──────────────────────────┐
│ Reisen             │                                   │ Reise / Route             │
│ + Neue Reise       │          Karte + Route             │ Start                     │
│                    │        nummerierte POIs             │   ↓                      │
│ Ausgewählte Reise  │                                   │ Stopps (optimierbar)      │
│                    │                                   │   ↓                      │
│                    │                                   │ Ziel                      │
│                    │                                   │                          │
│                    │                                   │ [Optimieren] [Übernehmen] │
└────────────────────┴───────────────────────────────────┴──────────────────────────┘
```

- Linke Spalte: Reisen und Reiseverwaltung.
- Mitte: größte Spalte, Karte, Routengeometrie und nummerierte Wegpunkte.
- Rechte Spalte: chronologische Route, POI-Details, Verweilzeit, Optimierungsvorschau und Etappen.
- Optimierung zeigt Vorher/Nachher-Reihenfolge und geänderte geschätzte Fahrtzeit. Sie überschreibt Nutzereingaben nicht ohne Bestätigung.
- Spaltenbreiten sind anpassbar; bei schmalen Fenstern lassen sich Seitenleisten einklappen.

## 5. Umsetzungsphasen

### Phase 0 – Anbieter- und Optimierungsprobe
- Kleine native SwiftUI-/MapKit-Mac-App: Karte, Suche, POI-Auswahl, Route, Apple-Maps-Übergabe.
- Testmenge von Beispielreisen mit wenigen und mehreren Zwischenstopps erstellen.
- MapKit-Paaranfragen samt benötigter Anfragezahl/Drosselung messen.
- Google Routes und Mapbox für dieselben Zwischenstopps hinsichtlich Reihenfolge, Fahrzeit, Grenzen, Kostenmodell, Datenschutz und Kartenbedingungen vergleichen.
- Entscheidung festhalten: ein Routinganbieter oder MapKit plus externer Optimierungsdienst.

**Ergebnis:** Vergleich und technischer Anbieterentscheid auf Basis von Beispieldaten; produktive Standortdaten werden erst nach separater Bewertung von Routengüte, Kosten, Datenschutz und Nutzungsbedingungen an einen externen Anbieter übertragen. Bestätigte MVP-Grenzen, bevor die Persistenz-/App-Architektur darauf festgelegt wird.

### Phase 1 – macOS-App und lokale Reisen
- SwiftUI-Fenster und dreispaltige Navigation.
- Lokales Trip-/Waypoint-Datenmodell und Persistenz.
- Reiseverwaltung mit Neu, Umbenennen, Beschreibung und Löschen.

### Phase 2 – Route, Karte und Optimierung (MVP)
- MapKit-Karte, Orts-/POI-Suche, Start/Ziel und Zwischenstoppliste.
- Routen- und Fahrzeitberechnung über den in Phase 0 gewählten Weg.
- Fahrzeit-Optimierung bei festem Start/Ziel und automatisches Sortieren der Zwischenstopps.
- Ergebnisvorschau, manuelle Korrektur, Fehler-/Offlinezustände und Apple-Maps-Übergabe.

### Phase 3 – Etappenplanung und Durchführung
- Etappen bilden und Zielzeit je Etappe optional festlegen.
- Fahr- und Verweilzeit summieren; Übernachtungs-POI pro Etappe festlegen.
- Etappenabschnitte zwischen festen Ankern optimieren.
- Jeweils nächstes POI an Apple Maps übergeben; Stopps überspringen.
- POI-Notizen und Bewertungen.

### Phase 4 – Fotoverwaltung
- Fotos über Systemdialog aus Fotos-Mediathek oder Dateien auswählen.
- Vorschlag: Originale unangetastet lassen und App-eigene Kopien in lokaler Medienverwaltung anlegen, damit Zuordnung und Export nicht durch verschobene Originaldateien brechen.
- GPS- und Zeitinformationen auslesen, passende Etappe/POI/Strecke vorschlagen und Bestätigung verlangen.
- Manuelle Zuordnung und Bildbeschreibung unterstützen; GPS-Daten bei Export nicht ungewollt offenlegen.

### Phase 5 – Offline-HTML-Export
- Exportstruktur erzeugen: `index.html` als Reiseübersicht, Unterseite je Etappe sowie lokaler `media/`-Ordner.
- CSS, JavaScript, Bilder und Kartenansicht lokal ausliefern; keine externen Schrift-, Kartenkachel-, Skript- oder Bild-URLs.
- Für Offline-Karte eine statische lokale Routendarstellung (z. B. generierte SVG/PNG-Karte) verwenden; keine interaktive Karte voraussetzen, die online Tiles nachlädt.
- Export im Finder/Browser ohne Netz testen und auf fehlende Medien verweisen.

### Phase 6 – Qualitäts- und Datenschutzrunde
- Tests für Trip-Persistenz, Stoppreihenfolge, Optimierungsintegration, Zeitrechnung, Medienzuordnung und Offline-Export.
- Providerfehler, API-Limits, leere Suchergebnisse und fehlende Berechtigungen sichtbar und handhabbar machen.
- Hinweise/Dokumentation zu Netzwerkübertragung von Such- und Routendaten, lokaler Fotokopie und Exportmetadaten.

## 6. Datenmodell (Startvorschlag)

- **Trip:** ID, Name, Beschreibung, Zeitstempel.
- **Waypoint:** ID, Trip-ID, eingegebene und ausgewählte Ortsdaten, Koordinate, Reihenfolge, Rolle, Verweilzeit, Notiz, Bewertung.
- **RoutePlan:** Trip-ID, optimierte Stoppreihenfolge, Zeitpunkt/Profil der Berechnung, geschätzte Fahrtzeit, Anbieter/Version; erlaubt Neuberechnung und Anzeige von veralteten Schätzungen.
- **Leg:** Etappenreihenfolge, Start-/End-Waypoint, optionales Zeitbudget und Übernachtungsort.
- **Photo:** lokale App-Mediendatei, Aufnahmedatum, optionale GPS-Metadaten, Beschreibung.
- **PhotoAssignment:** Foto, Etappe, optionaler POI oder Streckenabschnitt, Zuordnungsstatus (Vorschlag/bestätigt).

## 7. Risiken / Entscheidungen vor Implementierungsstart

- Ein Fahrzeit-Optimum hängt vom Routingmodell, Abfahrtszeit und Verkehr ab; es ist ein Anbieterergebnis, kein absolutes Optimum über alle denkbaren Routen.
- Eine API-Optimierung kann Standortdaten an Dritte übertragen und Kosten erzeugen; Speicherung „lokal“ verhindert das nicht.
- MapKit ist für eine native macOS-Karte besonders passend, aber die dokumentierte Directions-Schnittstelle bietet keine Gesamtoptimierung und kann Anfragen drosseln.
- Ein Anbieter für Optimierung und ein anderer für Kartenanzeige können hinsichtlich Lizenz, Darstellung und Abweichungen problematisch sein.
- Foto-GPS-Daten und offline exportierte Medien sind private Reiseinformationen; Export soll keine unnötigen EXIF-Koordinaten enthalten.
- Vollständig offline nutzbarer Export ist realistisch; Offline-Kartenrouting innerhalb der App ist **nicht** Teil dieses Plans.

## 8. Erfolgskriterien

- Eine Reise mit Start, Ziel und mehreren Zwischenstopps lässt sich dauerhaft lokal speichern.
- Die App berechnet eine Fahrtzeit-basierte Zwischenstopp-Reihenfolge, hält Start/Ziel fest und erläutert, dass es eine Schätzung ist.
- Nutzer kann die vorgeschlagene Reihenfolge ansehen, übernehmen, manuell ändern und erneut berechnen.
- Karte, Routenliste und an Apple Maps übergebenes Ziel sind konsistent.
- Ein Export enthält Übersicht, Etappenseiten und Medien und lässt sich ohne Internetverbindung öffnen.
