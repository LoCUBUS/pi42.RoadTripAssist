# RoadTripAssist – Implementierungsplan

**Aktueller Stand (20. November 2026):** Phasen 0–3 sind für den Prototyp funktional abgeschlossen. Die Nachbesserungen an Etappenplanung, Budgetanzeige, Übernachtungssuche und Bedienung gehören zum Stand von Phase 3. Die gezielten Swift- und macOS-UI-Tests sind bestanden; ein vollständiger Testlauf nach den letzten Änderungen steht noch aus.

**Als Nächstes:** Phase 4 – Fotoverwaltung. Der Google-/Mapbox-Livevergleich bleibt für Phase 7 vorgesehen. Vor Veröffentlichung bleibt die Prüfung der Apple-Vorgaben für alternative Routenanfragen und den Cache offen.

## 1. Bestätigte Anforderungen

- Native Anwendung ausschließlich für **macOS**.
- Apple Maps/MapKit ist der naheliegende Ausgangspunkt, aber Alternativen sollen vor Festlegung geprüft werden.
- Die Optimierung soll die **geschätzte Fahrzeit** minimieren und eine passende Reihenfolge der Zwischenstopps vorschlagen. Ein Fahrzeitvorschlag wird erst nach Bestätigung übernommen.
- **Start und Ziel bleiben fest**; optimiert wird die Reihenfolge der Zwischenstopps.
- Erste nutzbare Version: Reisen verwalten, Route und POIs planen, Karte anzeigen und ein Ziel an Apple Maps übergeben. Etappen, Tagebuch und Export folgen danach.
- Reisedaten zunächst lokal auf dem Mac.
- Google Routes API und Mapbox erst am Ende mit Beispieldaten praktisch vergleichen; über einen produktiven externen Routinganbieter und die Übertragung realer Wegpunktkoordinaten wird nicht vorher entschieden.
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

Der Prototyp verwendet **MapKit für Karte, Suche, POI-Auswahl und Fahrzeiten**. Die Optimierung berechnet die Reihenfolge lokal. In Phase 7 werden Google Routes und Mapbox mit denselben Beispieldaten verglichen; Routengüte, Anfragelimits, Preis, Datenschutz und Nutzungsbedingungen bestimmen die spätere Anbieterwahl.

**Wichtige Trennung:** „lokal“ beschreibt hier zunächst die Speicherung. Karten- und Routinganfragen benötigen Internet und übertragen Ortskoordinaten an den jeweiligen Anbieter. Falls auch Ortsdaten strikt auf dem Gerät bleiben müssen, ist das eine zusätzliche Anforderung und schränkt die praktikablen Routingoptionen ein.

### Referenzdokumentation

- [Apple MapKit – MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections.md)
- [Apple MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui)
- [Google Routes API – Waypoint optimization](https://developers.google.com/maps/documentation/routes/opt-way)
- [Google Routes API – Usage and billing](https://developers.google.com/maps/documentation/routes/usage-and-billing)
- [Google Maps SDK for iOS – Setup](https://developers.google.com/maps/documentation/ios-sdk/config)
- [Mapbox Optimization API v1](https://docs.mapbox.com/api/navigation/optimization-v1/)
- [Mapbox Maps SDK for iOS](https://docs.mapbox.com/ios/maps/guides/)

### Dokumentationsvergleich (19. November 2026)

| Kriterium | MapKit + lokaler Optimierer | Google Routes API | Mapbox Optimization v1 |
|---|---|---|---|
| Reihenfolge | Exaktes Minimum der abgefragten, gerichteten Fahrzeitmatrix bis 18 frei sortierbare Stopps je Etappe; darüber nur Straßenroute in aktueller Reihenfolge. | `optimizeWaypointOrder` optimiert vorrangig Fahrzeit, berücksichtigt auch Entfernung und Abbiegungen. | Dauerbasierte Optimierung mit zusätzlichen Manöver-Strafwerten. |
| Feste Endpunkte | Start und Ziel sind im lokalen Optimierer fest. | Origin und Destination bleiben fest; Zwischenpunkte dürfen keine `via`-Punkte sein. `TRAFFIC_AWARE_OPTIMAL` ist bei Optimierung nicht erlaubt. | Möglich mit `source=first`, `destination=last`, `roundtrip=false`. |
| Umfang | Anzahl der MapKit-Anfragen wächst quadratisch; bei fünf/sechs Zwischenstopps 30/42 Anfragen für eine frische vollständige Berechnung. | Bis 25 Zwischenstopps je Anfrage; dokumentiertes Limit 3.000 Anfragen/Minute. | Bis 12 Koordinaten insgesamt, also maximal zehn Zwischenstopps; 300 Anfragen/Minute. |
| Abrechnung | Native MapKit-Nutzung; konkrete Nutzungsbedingungen und Skalierbarkeit für diesen Anwendungsfall prüfen. | API-Key und aktivierte Abrechnung erforderlich; Optimierung löst Compute Routes Pro aus, mehr als zehn Zwischenstopps können die Abrechnung beeinflussen. [Preise](https://developers.google.com/maps/billing-and-pricing/pricing#routes-pricing) prüfen. | Token erforderlich; Abrechnung pro Anfrage, einschließlich mehrerer Wegpunkte. [Preise und Freikontingente](https://www.mapbox.com/pricing/#optimization-api) prüfen. |
| Datenschutz und Darstellung | Suchanfragen und Koordinaten gehen an Apple; native Kartenintegration. | Koordinaten gehen an Google; [Routes-Richtlinien](https://developers.google.com/maps/documentation/routes/policies), Speicher- und Darstellungsvorgaben sowie gegebenenfalls EWR-Bedingungen prüfen. | Koordinaten gehen an Mapbox; Nutzungs-, Speicher- und Darstellungsvorgaben sowie gegebenenfalls erforderliche Attribution prüfen. |

Die beiden vorhandenen Beispiele Bayreuth–Oslo (fünf Zwischenstopps) und Bayreuth–Mailand (sechs) passen grundsätzlich in beide externen APIs. Eine Optimierung wäre dort jeweils mit einer Anfrage möglich; das ist **keine gemessene Laufzeit**. Der MapKit-Prototyp benötigte bei früheren Live-Läufen 30 bzw. 42 Anfragen. Google und Mapbox wurden mangels eingerichteter Zugangsdaten nicht live abgefragt; Reihenfolge, Fahrzeit, Laufzeit und tatsächlich entstehende Kosten sind daher noch nicht vergleichbar.

Für den praktischen Vergleich dieselben öffentlichen Stadtkoordinaten, festen Endpunkte und möglichst vergleichbare Fahrprofile verwenden; Ergebnisse und Messzeitpunkt dokumentieren. Vor einem produktiven Einsatz externe Kosten, Datenschutz und Vertragsbedingungen gesondert bewerten. Insbesondere weist [Apple bei MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections.md) darauf hin, Anfragen nur zu stellen, wenn die zugehörigen Routeninformationen angezeigt werden sollen. Die Zulässigkeit der derzeit für den Optimierungsvergleich abgefragten Alternativverbindungen ist deshalb vor einer Produktentscheidung zu prüfen.

**Prüfstand 19. November 2026:** Die App fragt alternative Teilstrecken ab, um eine Reihenfolge zu berechnen; nicht jede abgefragte Teilstrecke wird anschließend angezeigt. Apples Dokumentation klärt nicht eindeutig, ob dieser konkrete Einsatz unter den genannten Hinweis fällt. Das ist keine Freigabe: Vor einer Veröffentlichung bei Apple beziehungsweise anhand der für das Projekt geltenden Entwicklerbedingungen klären; auch die Wiederverwendung der Ergebnisse im Speicher prüfen. Google verlangt laut [Routes-Richtlinien](https://developers.google.com/maps/documentation/routes/policies) unter anderem Beachtung von Speicherbeschränkungen und Attribution; für eine Anzeige auf Apple-Karten sind die jeweils geltenden Bedingungen gesondert zu prüfen.

Ein erneuter MapKit-Lauf für die öffentliche Mailand-Testreise lieferte eine Vorschau nach etwa 6,2 Sekunden und ein Optimierungsergebnis nach etwa 58,9 Sekunden (7 bzw. 42 Anfragen); die übermittelten Streckenlängen waren positiv. Google- und Mapbox-Livetests bleiben ohne konfigurierte Zugangsdaten offen und können Kosten auslösen.

### Oberflächentests

- XCUITest deckt Reiseanlage, Ortssuche, manuelles Verschieben, Streckenanzeige, Wiederöffnen und Rückkehr zur Luftliniensortierung mit isolierten Testdaten ab.
- XCUITest prüft auch Treffer und Klicks ohne Treffer in der echten Kartenansicht mit simulierten Suchergebnissen, die Ortsdetails und das Einfügen erst nach Bestätigung. Ein separater MapKit-Livetest prüft, ob die Umgebungssuche Unbound Coffee in Innsbruck liefert.
- Die Übergabedaten für Zwischenziel und Ziel werden geprüft; der optionale Smoke-Test prüft zusätzlich, dass Apple Karten tatsächlich ein Fenster öffnet. Es wird nicht die gesamte Reise übergeben.
- Die Etappentests prüfen direktes Hinzufügen einer Übernachtung von der Karte, Teilen und Zusammenführen von Etappen, Abbrechen und Bestätigen beim Entfernen, aktualisierte Etappenzeit nach einer Verweilzeitänderung sowie Bestätigen und Widerrufen einer Budgetüberschreitung.
- Ein Screenshot-Vergleich bei gleichem Kartenausschnitt prüft, dass der Suchkreis eine sichtbare orangefarbene Kontur hat und die Karte innen nicht einfärbt. Ohne explizit transparenten Füllstil hat MapKit den Kreis trotz Kontur gefüllt; der Test erkennt diese Regression.
- Netzwerkfehler und Wiederholung sind mit simulierten Fehlern im Swift-Paket getestet. Die Verfügbarkeit von Kartenkacheln und das Verhalten bei tatsächlich unterbrochener Netzwerkverbindung werden nicht automatisiert geprüft.
- Startbefehle stehen in der [README](README.md).

## 3. MVP und Funktionsumfang

### MVP – durchgängige erste Nutzung
- Reisen mit Name und Beschreibung anlegen, auswählen, umbenennen und löschen.
- Start, Ziel und Zwischenstopps suchen und auswählen.
- Konkrete POIs über die Suche wählen oder per Kartenklick als Zwischenziel hinzufügen. Ein bestehender grober Wegpunkt lässt sich über sein Suchfeld ersetzen.
- Zwischenstopps für minimale **geschätzte Gesamtfahrzeit** sortieren; Start und Ziel bleiben fix.
- Die aktuelle Reihenfolge in Liste und Karte anzeigen; einen schnelleren Vorschlag in der Seitenleiste prüfen, übernehmen oder die Reihenfolge manuell korrigieren. Die Karte zeigt die Vorschlagsroute erst nach Übernahme.
- Geschätzte Fahrzeit und Strecke der berechneten Straßenroute anzeigen.
- Einen ausgewählten Wegpunkt an Apple Karten übergeben. Im Reiseverlauf wird seit Phase 3 auch das nächste offene Ziel angeboten.
- Reise lokal speichern und nach einem Neustart wieder öffnen.

### Nach dem MVP – in Phase 3 umgesetzt
- Etappen mit frei wählbarem Zeitbudget und Übernachtungs-POI.
- Reiseablauf mit Überspringen, Notizen und Bewertungen.

### Weitere Ausbaustufen – offen
- Fotoimport, GPS-Zuordnung mit Bestätigung und lokale Medienverwaltung.
- Offline-HTML-Reisetagebuch mit Übersichts- und Etappenseiten.

**Optimierungsregeln im Prototyp:** Ohne Übernachtungsanker sind alle Zwischenstopps frei umsortierbar. Markierte Übernachtungen bilden feste Etappengrenzen; die Optimierung sortiert nur zwischen diesen Ankern. Öffnungszeiten, Zeitfenster und Prioritäten fließen nicht ein. Das Zeitbudget ist ein Planungshinweis, keine Nebenbedingung des Optimierers. Vorschläge bleiben überprüfbar und manuell änderbar.

## 4. Bedienung und UX-Ziele

```text
┌────────────────────┬───────────────────────────────────┬──────────────────────────┐
│ Reisen             │                                   │ Reise / Route             │
│ + Neue Reise       │          Karte + Route             │ Start                     │
│                    │          Wegpunkte                 │   ↓                      │
│ Ausgewählte Reise  │                                   │ Stopps (optimierbar)      │
│                    │                                   │   ↓                      │
│                    │                                   │ Ziel                      │
│                    │                                   │                          │
│                    │                                   │ Fahrzeit / Vorschlag     │
└────────────────────┴───────────────────────────────────┴──────────────────────────┘
```

- Linke Spalte: Reisen und Reiseverwaltung.
- Mitte: Karte mit Straßenroute, Wegpunktmarkern und originalen Apple-Kartensymbolen. Ein Kartenklick sucht in einem Radius von höchstens 60 m; die Infobox zeigt den nächsten Treffer zur Bestätigung. Bei keinem Treffer bleibt die Route unverändert.
- Rechte Spalte: Start, Zwischenziele und Ziel mit direkter Ortssuche, Fortschritt, geschätzter Fahrzeit, Strecke und einem möglichen Vorschlag. Der Vorschlag überschreibt die Route nicht ohne Bestätigung.
- Der Umschalter „Route / Etappen“ wechselt zwischen Routen- und Etappenliste. Größere grüne Überschriften „Etappe n: …“ kennzeichnen die Teilrouten; kleine Symbolbuttons führen die Wegpunktaktionen aus. Nummerierte Kartenmarker, separat einstellbare Spaltenbreiten und einklappbare Seitenleisten bleiben UX-Ziele.

## 5. Umsetzungsphasen

### Phase 0 – MapKit- und Optimierungsprobe
- Kleine native SwiftUI-/MapKit-Mac-App: Karte, Suche, POI-Auswahl, Route, Apple-Maps-Übergabe.
- Testmenge von Beispielreisen mit wenigen und mehreren Zwischenstopps erstellen.
- MapKit-Paaranfragen samt benötigter Anfragezahl/Drosselung messen.
- Den dokumentationsbasierten Anbietervergleich festhalten; den praktischen Vergleich auf Phase 7 verschieben.

**Ergebnis:** MapKit-Prototyp und Messungen mit Beispieldaten; eine endgültige Anbieterentscheidung steht aus. Die Apple-Vorgaben zur Verwendung der Alternativanfragen sind vor Veröffentlichung zu klären.

### Phase 1 – macOS-App und lokale Reisen
- SwiftUI-Fenster und dreispaltige Navigation.
- Lokales Trip-/Waypoint-Datenmodell und Persistenz.
- Reiseverwaltung mit Neu, Umbenennen, Beschreibung und Löschen.

### Phase 2 – Route, Karte und Optimierung (MVP)
- MapKit-Karte, Orts-/POI-Suche, Start/Ziel und Zwischenstoppliste.
- Native Apple-Kartensymbole; ein Kartenklick sucht in der unmittelbaren Nähe nach einem POI und zeigt einen Treffer mit Ortsdetails zur Bestätigung vor der Übernahme als Zwischenziel.
- Routen- und Fahrzeitberechnung vorläufig über MapKit.
- Vorläufige Luftlinien-Sortierung bei festem Start und Ziel; Fahrzeitoptimierung nach Aktivierung als Vorschlag zur Übernahme. Karten-POIs werden bei manueller Reihenfolge so eingefügt, dass die zusätzliche Luftlinie möglichst klein bleibt, ohne bestehende Stopps umzusortieren.
- Ergebnisvorschau, manuelle Korrektur, Fehler-/Offlinezustände und Apple-Maps-Übergabe.

### Phase 3 – Etappenplanung und Durchführung (funktional abgeschlossen)

**Etappen und Wegpunktaktionen**
- Das Bett-Symbol markiert oder entmarkiert eine Übernachtung; ein ausgefülltes Bett zeigt die aktive Markierung. An einem Zwischenziel teilt dies die Route oder führt angrenzende Etappen zusammen. Die letzte Etappe endet immer am Reiseziel. Jede Etappe lässt sich einzeln auf der Karte anzeigen.
- In den Karten-Ortsdetails stehen „Zur Route hinzufügen“ und „Als Übernachtung hinzufügen“ zur Auswahl. Die zweite Aktion fügt den POI ein und markiert ihn direkt als Etappengrenze. Doppelte POIs werden nicht hinzugefügt. Die Einfügelücke für eine neue Übernachtung wird nach der kleinsten zusätzlichen Luftlinienentfernung gewählt.
- Das Info-Symbol öffnet Verweilzeit, Notizen, Bewertung und bei Zielen den Besuchsstatus. Das Kartensymbol ist derselbe Button wie in der Routenplanung. Das Minus-Symbol entfernt nur Zwischenziele und erst nach Bestätigung. Beim Entfernen einer Übernachtung nennt der Dialog ausdrücklich das Zusammenführen der angrenzenden Etappen.
- Luftlinien- und Fahrzeitoptimierung sortieren nur innerhalb der Etappengrenzen. Die manuelle Reihenfolge bleibt über die Routenansicht änderbar.

**Etappenzeit, Suchkreis und Budgetausnahme**
- Standardbudget, abweichendes Budget am Etappenziel und Verweilzeit im Wegpunktdialog verwenden `hh:mm`. Ein leeres Etappenbudget übernimmt das Standardbudget, ein leeres Standardbudget setzt keines. `00:00` ist für Verweilzeiten zulässig, nicht für ein gesetztes Budget.
- Die Etappenzeit addiert Fahr- und Verweilzeit, wobei ein gemeinsamer Übernachtungsort nur zur ankommenden Etappe zählt. Gespeicherte Verweilzeiten aktualisieren die Anzeige ohne erneute MapKit-Abfrage. Fehlt die Fahrzeit, erscheint z. B. „45 min + ausstehende Fahrzeit“. Das Budget bleibt beim Ändern der Verweilzeit unverändert.
- Der Budgetplatzhalter markiert bei einer Überschreitung die erste geschätzte Stelle, an der die Zeit aufgebraucht ist: am Wegpunkt während eines Aufenthalts oder näherungsweise entlang der Straßengeometrie. Ein Klick zoomt auf die orangefarbene Bettmarkierung mit einem ungefüllten Suchkreis von 5 km Durchmesser. Der Suchkreis ist eine Orientierungshilfe; die App sucht dort nicht automatisch nach Unterkünften und verschiebt keine Stopps.
- Wird die Übernachtung erst nach dem Budgetpunkt erreicht, zeigt die Etappe die geschätzte Überschreitung in Minuten vor Ankunft. „Budgetpunkt ausblenden“ blendet nach Bestätigung Platzhalter und Suchkreis aus; Warnung und Route bleiben erhalten. Die gespeicherte Bestätigung gilt für dieselbe Wegpunktfolge und dasselbe Budget, solange die Ankunft nicht später als bestätigt geschätzt wird. „Budgetpunkt wieder anzeigen“ widerruft sie. Wird das Budget erst am bereits als Übernachtung markierten Etappenziel erreicht, entfällt dort der Suchpunkt.

**Reiseverlauf**
- Das nächste offene oder ein beliebiges einzelnes Ziel lässt sich an Apple Karten übergeben. Besuchte und übersprungene Ziele bleiben im Plan und können wieder auf „Offen“ gesetzt werden. Der Status ändert weder Route noch Zeiten. Wegpunktdetails, Budgets, Bestätigungen und Fortschritt bleiben lokal gespeichert.

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

### Phase 7 – Praktischer Vergleich externer Routinganbieter
- Google Routes und Mapbox mit denselben öffentlichen Beispielreisen hinsichtlich Reihenfolge, Fahrzeit, Grenzen, Kostenmodell, Datenschutz und Kartenbedingungen vergleichen.
- Entscheidung über einen Routinganbieter oder MapKit plus externen Optimierungsdienst festhalten. Produktive Standortdaten erst nach gesonderter Bewertung an einen externen Anbieter übertragen.

## 6. Datenmodell

**Implementiert:** `RoadTrip` speichert ID, Name und Beschreibung. `TripWaypoints` enthält Start, geordnete Zwischenziele, Ziel, die manuelle Sortiereinstellung und das Standard-Zeitbudget. `RoadStop` speichert ID, Name, Untertitel und Koordinaten. Pro Wegpunkt-ID hält `WaypointDetails` Verweilzeit, Notiz, Bewertung, Besuchsstatus, Übernachtungskennzeichen, Etappenbudget und eine optionale Bestätigung der Budgetüberschreitung fest. Budgets und Verweilzeiten werden als Minuten gespeichert; eine Bestätigung enthält zusätzlich die geordneten Wegpunkt-IDs und die bestätigte Ankunftsminute. Etappen und Suchpunkte werden daraus und aus der aktuellen Straßenvorschau abgeleitet. Berechnete Routen und der MapKit-Opt-in werden nicht gespeichert. Ältere Reisen lassen sich ohne diese Felder laden.

**Entwurf für die weitere Entwicklung (keine Beschreibung des aktuellen JSON-Formats):**

- **Trip:** ID, Name, Beschreibung, Zeitstempel.
- **Waypoint:** ID, Trip-ID, eingegebene und ausgewählte Ortsdaten, Koordinate, Reihenfolge, Rolle, Verweilzeit, Notiz, Bewertung.
- **RoutePlan:** Trip-ID, optimierte Stoppreihenfolge, Zeitpunkt/Profil der Berechnung, geschätzte Fahrtzeit, Anbieter/Version; erlaubt Neuberechnung und Anzeige von veralteten Schätzungen.
- **Photo:** lokale App-Mediendatei, Aufnahmedatum, optionale GPS-Metadaten, Beschreibung.
- **PhotoAssignment:** Foto, Etappe, optionaler POI oder Streckenabschnitt, Zuordnungsstatus (Vorschlag/bestätigt).

## 7. Risiken und offene Entscheidungen

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
- Etappen lassen sich separat anzeigen, summieren Fahr- und Verweilzeit ohne Doppelzählung und behalten ihre Grenzen bei der Optimierung. Das nächste offene Ziel berücksichtigt besuchte und übersprungene Wegpunkte.
- Änderungen an Verweilzeiten aktualisieren die Etappenzeit direkt. Ein Budgetpunkt lässt sich bei späterer Übernachtungsankunft nach Bestätigung ausblenden und wieder einblenden, ohne Route oder Warnung zu verändern.
- **Phase 5 (offen):** Ein Export enthält Übersicht, Etappenseiten und Medien und lässt sich ohne Internetverbindung öffnen.
