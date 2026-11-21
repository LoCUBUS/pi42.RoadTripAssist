# RoadTripAssist – Implementierungsplan

**Aktueller Stand (21. November 2026):** Phasen 0–3 sind für den Prototyp funktional abgeschlossen. Etappen, Budget- und Übernachtungssuche, Wegpunktkategorien, einklappbare Wegpunkt- und Etappenbudget-Editoren sowie die UI-Zwischenphase sind umgesetzt. Die Routenberechnung aktualisiert die aktuelle Reihenfolge inkrementell; Optimierung und Anzeige alternativer Verbindungen werden separat ausgelöst. Zuletzt bestanden 31 gezielte Swift-Tests (drei optionale Livetests übersprungen) und gezielte macOS-UI-Tests für Etappenbudget, Wegpunkteditor und Etappenteilung. Ein vollständiger Testlauf nach den jüngsten Änderungen sowie eine separate Sichtprüfung der aktuellen Darstellung stehen noch aus.

**Als Nächstes:** Phase 4 – Fotoverwaltung. Der Google-/Mapbox-Livevergleich bleibt für Phase 7 vorgesehen; die Untersuchung und eine mögliche Google-Implementierung folgen am Ende in Phase PI. Vor Veröffentlichung bleibt die Prüfung der Apple-Vorgaben für alternative Routenanfragen und den Cache offen.

**UI-Zwischenphase:** Die Mindestversion ist auf macOS 27 angehoben. Die App
verwendet ein natives Split-View-Fenster mit größenveränderlicher Reiseseitenleiste
und ein- bzw. ausblendbarem Routeninspektor. Die schwebenden POI-Details verwenden
Liquid Glass; die native Karte und die bestehenden Wegpunktfunktionen bleiben erhalten.
Hell-/Dunkelmodus, reduzierte Transparenz, erhöhter Kontrast und kleine Fenster
sind für die überarbeitete Oberfläche noch gesondert visuell zu prüfen.

## 1. Bestätigte Anforderungen

- Native Anwendung ausschließlich für **macOS**, ab Version **27**.
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

**Prüfstand:** Die App fragt alternative Teilstrecken ab, um eine Reihenfolge zu berechnen. Erfolgreich ermittelte Verbindungen lassen sich inzwischen einblenden, werden aber nicht zwangsläufig alle angezeigt. Apples Dokumentation klärt nicht eindeutig, ob dieser konkrete Einsatz unter den genannten Hinweis fällt. Das ist keine Freigabe: Vor einer Veröffentlichung bei Apple beziehungsweise anhand der für das Projekt geltenden Entwicklerbedingungen klären; auch die Wiederverwendung der Ergebnisse im Speicher prüfen. Google verlangt laut [Routes-Richtlinien](https://developers.google.com/maps/documentation/routes/policies) unter anderem Beachtung von Speicherbeschränkungen und Attribution; für eine Anzeige auf Apple-Karten sind die jeweils geltenden Bedingungen gesondert zu prüfen.

Ein erneuter MapKit-Lauf für die öffentliche Mailand-Testreise lieferte eine Vorschau nach etwa 6,2 Sekunden und ein Optimierungsergebnis nach etwa 58,9 Sekunden (7 bzw. 42 Anfragen); die übermittelten Streckenlängen waren positiv. Google- und Mapbox-Livetests bleiben ohne konfigurierte Zugangsdaten offen und können Kosten auslösen.

### Oberflächentests

- XCUITest deckt Reiseanlage, Ortssuche, manuelles Verschieben, Streckenanzeige, Wiederöffnen und Rückkehr zur Luftliniensortierung mit isolierten Testdaten ab.
- XCUITest prüft auch Treffer und Klicks ohne Treffer in der echten Kartenansicht mit simulierten Suchergebnissen, die Ortsdetails und das Einfügen erst nach Bestätigung. Ein separater MapKit-Livetest prüft, ob die Umgebungssuche Unbound Coffee in Innsbruck liefert.
- Die Übergabedaten für Zwischenziel und Ziel werden geprüft; der optionale Smoke-Test prüft zusätzlich, dass Apple Karten tatsächlich ein Fenster öffnet. Es wird nicht die gesamte Reise übergeben.
- Die Etappentests prüfen direktes Hinzufügen einer Übernachtung von der Karte, Teilen und Zusammenführen von Etappen, Abbrechen und Bestätigen beim Entfernen, aktualisierte Etappenzeit nach einer Verweilzeitänderung sowie Bestätigen und Widerrufen einer Budgetüberschreitung.
- Gezielt geprüft werden das Aufklappen und Speichern von Wegpunktdetails und Etappenbudget, die Warnung vor dem Verwerfen ungespeicherter Änderungen, ungültige Budgets, die Übernahme des Standardbudgets, das Wiederöffnen gespeicherter Werte und die Zuordnung eines Budgets bei geteilten Etappen. Die Routensteuerung wird auf kompakte Höhe sowie Vorschlagsdetails und das Ein- und Ausblenden alternativer Verbindungen geprüft.
- Weitere gezielte Tests prüfen das Aus- und Einblenden des Routeninspektors, das Speichern, Wiederöffnen und Entfernen einer Wegpunktkategorie sowie die Farb- und Symbolpriorität einschließlich Start, Ziel und Übernachtung. Letztere wird in der Darstellungslogik geprüft; eine visuelle Prüfung sämtlicher Kartenmarker ist nicht automatisiert.
- Ein Screenshot-Vergleich bei gleichem Kartenausschnitt prüft, dass der Suchkreis eine sichtbare orangefarbene Kontur hat und die Karte innen nicht einfärbt. Ohne explizit transparenten Füllstil hat MapKit den Kreis trotz Kontur gefüllt; der Test erkennt diese Regression.
- Netzwerkfehler und Wiederholung sind mit simulierten Fehlern im Swift-Paket getestet. Die Verfügbarkeit von Kartenkacheln und das Verhalten bei tatsächlich unterbrochener Netzwerkverbindung werden nicht automatisiert geprüft.
- Startbefehle stehen in der [README](README.md).

## 3. MVP und Funktionsumfang

### MVP – durchgängige erste Nutzung
- Reisen mit Name und Beschreibung anlegen, auswählen, umbenennen und löschen.
- Start, Ziel und Zwischenstopps suchen und auswählen.
- Konkrete POIs über die Suche wählen oder per Kartenklick als Zwischenziel hinzufügen. Ein bestehender grober Wegpunkt lässt sich über sein Suchfeld ersetzen.
- Zwischenstopps für minimale **geschätzte Gesamtfahrzeit** sortieren; Start und Ziel bleiben fix.
- Die aktuelle Reihenfolge in Liste und Karte anzeigen; auf ausdrückliche Anforderung einen schnelleren Vorschlag in der Seitenleiste prüfen, vorübergehend auf der Karte anzeigen, übernehmen oder die Reihenfolge manuell korrigieren.
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

**Inkrementelles Routing und feste Auswahl:** Nach Zustimmung berechnet die automatische Aktualisierung nur die Straßenroute der aktuellen Reihenfolge. Die Optimierung weiterer Reihenfolgen wird separat gestartet und liefert höchstens einen schnelleren Vorschlag; sie zeigt nicht alle möglichen Reihenfolgen oder mehrere Straßenalternativen pro Teilstrecke. Die aktuelle Route bleibt bis zur Übernahme ausgewählt. Eine übernommene oder ausdrücklich fixierte Reihenfolge wird als manuelle Reihenfolge gespeichert und bei späteren Änderungen nicht automatisch umsortiert. Text-Zwischenziele werden dann am Ende ergänzt, Karten-POIs in die Luftlinien-Lücke mit dem geringsten Umweg eingefügt. „Nach Luftlinie sortieren“ hebt die Fixierung ausdrücklich auf.

Die Routensteuerung verwendet platzsparende Symbolbuttons mit Hilfetexten. Ein Info-Popover zeigt die vollständige vorgeschlagene Reihenfolge und Fahrzeitersparnis; der Vorschlag kann vor der Übernahme auf der Karte angezeigt und wieder auf die aktuelle Route zurückgeschaltet werden. Eine einzelne ausgewählte Etappe zeigt stets die aktuelle Route. Bei der Optimierung erfolgreich ermittelte oder aus dem Cache übernommene Verbindungen, die nicht zur aktuellen Reihenfolge gehören, lassen sich über ein weiteres Popover lila gestrichelt ein- und ausblenden. Eine scrollbare Auswahl zeigt entweder alle oder eine gerichtete Verbindung mit Fahrzeit und Entfernung; bei gewählter Etappe nur deren Verbindungen. Bereits ermittelte Verbindungen bleiben auch bei einem Optimierungsfehler sichtbar, werden bei Wegpunkt- oder Ankeränderungen aber verworfen. Es sind einzelne Verbindungen, keine vollständigen alternativen Reisen oder mehrere Straßenvarianten derselben Verbindung.

Der gerichtete Teilstrecken-Cache lebt nur im Speicher und hat keine Ablaufzeit; alte Fahrzeiten können daher unaktuell werden. Beim Einfügen in eine feste Route müssen bei vorhandenem Cache lediglich die beiden angrenzenden Verbindungen neu abgefragt werden. Explizite Optimierung kann weitere Paaranfragen benötigen; Start, Ziel und Übernachtungsanker bleiben dabei fest. Nach Fehlern können Anfragen wiederholt werden; eine verfügbare Vorschau bleibt bei Optimierungsfehlern sichtbar. Cache und Zustimmungsentscheidung werden nicht gespeichert. Die offene Prüfung der Apple-Vorgaben für Alternativanfragen und Cache bleibt auch nach dieser Änderung Voraussetzung für die Veröffentlichung; die optionale Anzeige allein ist keine Freigabe.

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
- Der Umschalter „Route / Etappen“ wechselt zwischen Routen- und Etappenliste. Größere grüne Überschriften „Etappe n: …“ kennzeichnen die Teilrouten; kleine Symbolbuttons führen die Wegpunktaktionen aus. Reiseseitenleiste und Routeninspektor sind systemeigene, größenveränderliche Bereiche; der Inspektor lässt sich über die Symbolleiste aus- und wieder einblenden. Nummerierte Kartenmarker bleiben ein UX-Ziel.
- Wegpunkte ohne Kategorie tragen rote, kategorisierte Wegpunkte grüne und Übernachtungen blaue Kartenmarker. In der Wegpunktinfo kann optional Sight Seeing (Fernglas), View Point (Berge), Pause (Tasse), Wanderung (Wanderer) oder Nav-Hilfspunkt (Navigationspfeil) gewählt werden. Karte sowie Routen- und Etappenliste zeigen die Kennzeichnung. Start und Ziel tragen eigene Symbole statt des Kategoriesymbols, behalten aber die Kategoriefarbe. Bei Übernachtungen hat das Bettsymbol samt blauer Farbe Vorrang, ohne die Kategorie zu löschen. Ein noch nicht übernommener Karten-POI wird ebenfalls blau hervorgehoben; Suchtreffer und Budgetpunkt sind orange.

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
- Vorläufige Luftlinien-Sortierung bei festem Start und Ziel; automatische Berechnung der aktuellen Route nach Aktivierung und separate Fahrzeitoptimierung als Vorschlag zur Übernahme. Karten-POIs werden bei fixierter Reihenfolge so eingefügt, dass die zusätzliche Luftlinie möglichst klein bleibt, ohne bestehende Stopps umzusortieren.
- Ergebnisvorschau, manuelle Korrektur, Fehler-/Offlinezustände und Apple-Maps-Übergabe.

### Phase 3 – Etappenplanung und Durchführung (funktional abgeschlossen)

**Etappen und Wegpunktaktionen**
- Das Bett-Symbol markiert oder entmarkiert eine Übernachtung; ein ausgefülltes Bett zeigt die aktive Markierung. An einem Zwischenziel teilt dies die Route oder führt angrenzende Etappen zusammen. Die letzte Etappe endet immer am Reiseziel. Jede Etappe lässt sich einzeln auf der Karte anzeigen.
- In den Karten-Ortsdetails stehen „Zur Route hinzufügen“ und „Als Übernachtung hinzufügen“ zur Auswahl. Die zweite Aktion fügt den POI ein und markiert ihn direkt als Etappengrenze. Ein normal hinzugefügter POI ohne Kategorie wird wie andere kategorielose Wegpunkte rot dargestellt, ein Übernachtungs-POI blau. Doppelte POIs werden nicht hinzugefügt. Die Einfügelücke für eine neue Übernachtung wird nach der kleinsten zusätzlichen Luftlinienentfernung gewählt.
- Ein Klick auf die Wegpunktzeile oder den Pfeil klappt Kategorie, Verweilzeit, Notizen, Bewertung und außer beim Start Übernachtung und Besuchsstatus direkt in der Etappenliste auf. Es ist jeweils nur ein Wegpunkt- oder Etappenbudget-Editor geöffnet. Änderungen werden gespeichert oder ausdrücklich abgebrochen; beim Einklappen, Öffnen eines anderen Editors, Wechseln der Ansicht oder Auswählen beziehungsweise Anlegen einer Reise wird vor dem Verwerfen ungespeicherter Änderungen gefragt. Beim Entfernen des bearbeiteten Wegpunkts oder Löschen seiner Reise warnt der jeweilige Bestätigungsdialog vor dem Verlust. Während ein Editor für den Punkt offen ist, ist dessen Bett-Button gesperrt; der Besuchsstatus eines gerade bearbeiteten Wegpunkts wird in dessen Details geändert. Eine Kategorie kann auch wieder entfernt werden; alle Angaben bleiben am Wegpunkt gespeichert. Das Kartensymbol ist derselbe Button wie in der Routenplanung. Das Minus-Symbol entfernt nur Zwischenziele und erst nach Bestätigung. Beim Entfernen einer Übernachtung nennt der Dialog ausdrücklich das Zusammenführen der angrenzenden Etappen.
- Luftlinien- und Fahrzeitoptimierung sortieren nur innerhalb der Etappengrenzen. Die manuelle Reihenfolge bleibt über die Routenansicht änderbar.

**Etappenzeit, Suchkreis und Budgetausnahme**
- Standardbudget, abweichendes Budget am Etappenziel und Verweilzeit in den Wegpunktdetails verwenden `hh:mm`. Das Standardbudget wird im eigenen Dialog bearbeitet; ein Klick auf die Etappenüberschrift klappt den Editor für das individuelle Budget auf. Derselbe Wert ist auch in den Wegpunktdetails des Etappenziels bearbeitbar. Das Budget ist am Zielwegpunkt gespeichert; wird eine Zwischenübernachtung aufgehoben, entfällt deren individuelles Budget beim Zusammenführen. Ein leeres Etappenbudget übernimmt das Standardbudget, ein leeres Standardbudget setzt keines. `00:00` ist für Verweilzeiten zulässig, nicht für ein gesetztes Budget; Minuten müssen zwischen `00` und `59` liegen.
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
- Die modernisierte Oberfläche einschließlich Marker, Liquid Glass, Hell-/Dunkelmodus, Bedienungshilfen und kleiner Fenster visuell prüfen.

### Phase 7 – Praktischer Vergleich externer Routinganbieter
- Google Routes und Mapbox mit denselben öffentlichen Beispielreisen hinsichtlich Reihenfolge, Fahrzeit, Grenzen, Kostenmodell, Datenschutz und Kartenbedingungen vergleichen.
- Ergebnis und Empfehlung für einen Routinganbieter oder MapKit plus externen Optimierungsdienst festhalten. Produktive Standortdaten erst nach gesonderter Bewertung an einen externen Anbieter übertragen.

### Phase PI – Untersuchung und mögliche Google-Implementierung

**Ziel und Grenzen:** Nach Phase 7 dokumentationsbasiert untersuchen, wie ein späterer Umschalter Karte, Orts- und POI-Suche sowie Routing gemeinsam zwischen Apple und Google wechseln könnte. Apple bleibt ohne Google-Konfiguration nutzbar. Bestehende Reisen sollen erhalten bleiben; Anbieterinhalte müssen dabei regelkonform behandelt und gegebenenfalls erneut zugeordnet werden. Die Untersuchung selbst implementiert keine App-Funktion und umfasst weder Live-Prototyp noch kostenpflichtige API-Anfragen oder die Übermittlung von Reisedaten. Eine mögliche Umsetzung folgt erst nach Untersuchung, Anbietervergleich und gesonderter Entscheidung.

**Ausgangslage**
- Die Kartenansicht und Klickumrechnung verwenden direkt SwiftUI `Map` und `MapReader`. Ein Klick startet eine MapKit-Umgebungssuche mit höchstens 60 m Radius; der nächstgelegene Treffer wird zur Bestätigung gezeigt, nicht zwingend das tatsächlich angeklickte Kartensymbol. Die Ansicht zeigt Route oder ausgewählte Etappe, Wegpunkt- und Suchmarker sowie den ungefüllten 5-km-Übernachtungssuchkreis.
- `MapKitRouteService` bündelt Orts- und POI-Suche, Straßenrouting und den gerichteten Teilstrecken-Cache. Das ViewModel hängt konkret davon ab; auch die Berechnung des Budgetpunkts verwendet MapKit-Geometrie. Apple-Karten-Übergabe, Testfixtures und Projektkonfiguration sind bei einem Providerwechsel mit zu berücksichtigen.
- Google bietet eine [Maps JavaScript API](https://developers.google.com/maps/documentation/javascript/overview) für interaktive Webkarten. Eine Einbettung in `WKWebView` ist für die native Mac-App eine zu bewertende Option, keine bereits verifizierte Zusage. Googles dokumentiertes natives Maps SDK ist für iOS; daraus folgt keine native macOS-SDK-Zusage. SwiftPM- und Xcode-Ressourcen, Netz, Sandbox, Karteninitialisierung, WebView-Lebenszyklus und Barrierefreiheit sind gesondert zu prüfen.

**POIs und Bedienung**
- Das bestehende Bedienkonzept – Ort prüfen und erst danach als normalen oder Übernachtungsstopp übernehmen – soll erhalten bleiben; die providerabhängige Implementierung muss jedoch überarbeitet werden. Google zeigt in seinem [POI-Klickbeispiel](https://developers.google.com/maps/documentation/javascript/examples/event-poi), dass ein Klick auf ein unterstütztes Basiskarten-POI eine `placeId` liefern kann; passende Details lassen sich anschließend gezielt laden. Nicht jeder Kartenklick liefert eine ID. Eine Umgebungssuche als möglicher Fallback ist hinsichtlich Trefferqualität, Radius, Ergebnisgrenzen, Typen und Kosten zu prüfen; bei keinem Treffer darf die Route unverändert bleiben.
- Textsuche und Autocomplete, Ortsdetails und ihre Feldanforderungen separat bewerten. Googles [Autocomplete-Dokumentation](https://developers.google.com/maps/documentation/javascript/place-autocomplete-data) beschreibt Session-Tokens für die Abrechnung; [Nearby Search](https://developers.google.com/maps/documentation/javascript/nearby-search) berechnet Kosten abhängig von angeforderten Feldern. Einfügen, Übernachtungsmarkierung, Kategorien und bestehende manuelle Reihenfolge bleiben fachliche Invarianten.
- Identitäten sind an Anbieter gebunden. Die heutige Dublettenheuristik aus Name und Abstand unter 50 m ist bei abweichenden Namen, Sprachen und Koordinaten kein sicherer Identitätsnachweis. Anbieterübergreifende Treffer nicht stillschweigend zusammenführen; bei Unsicherheit Nutzerentscheidung vorsehen.

**Karte, Architektur und Umschaltung**
- Eine nachvollziehbare Trennung von Kartenansicht, Orts-/POI-Dienst und Routingadapter entwerfen, ohne die konkrete Implementierung vorwegzunehmen. Google und Apple werden im Zielbild gemeinsam umgeschaltet; Mischbetrieb ist keine vorausgesetzte Funktion. Native Navigation und Etappenbedienung bleiben erhalten.
- Für eine mögliche WebView-Brücke validierte, klar begrenzte Nachrichten und Request-IDs, kontrollierte Navigation und Links, Ladezustände und explizite Fehler vorsehen. Späte Antworten dürfen nach neuem Klick, Reise- oder Providerwechsel nicht alte Auswahlen überschreiben. Laden, Reload und Fehler sollen die lokale Reise nicht beschädigen.
- Darstellungsparität für Start/Ziel, Kategorien, rote/grüne/blaue Marker, Übernachtungsbett, Suchergebnisse, Routenpolylinien, Etappenauswahl, Kamera und ungefüllten 5-km-Kreis prüfen. Googles [Advanced Markers](https://developers.google.com/maps/documentation/javascript/advanced-markers/overview) unterstützen eigene Farben und Symbole, benötigen aber eine Map ID; SF Symbols stehen nicht automatisch als Web-Symbole bereit. Sichtbarkeit der vorgeschriebenen Attribution, Tastatur- und VoiceOver-Bedienung sowie Hell-/Dunkelmodus prüfen.
- Beim späteren Umschalten laufende Suchen und Berechnungen abbrechen oder deren Ergebnisse verwerfen. Providereigene Karten-/Routenvorschau, Optimierungsvorschlag und Cache invalidieren; Reise, Reihenfolge, Kategorien, Übernachtungen, Fortschritt und Budgets nicht verlieren. Neue Anfragen erst nach transparenter Zustimmung zur jeweiligen Datenübertragung; kein stiller Fallback auf den anderen Anbieter.

**Persistenz, Nutzungsbedingungen und Datenschutz**
- Googles [Places-Richtlinien](https://developers.google.com/maps/documentation/places/web-service/policies) beschränken die Speicherung und Weiterverwendung von Anbieterinhalten; Place IDs sind dort als Ausnahme beschrieben, Koordinaten bei bestimmten Diensten nur zeitlich begrenzt cachebar. Die jeweils geltenden Bedingungen und Ausnahmen, einschließlich der [EWR-spezifischen Bedingungen](https://cloud.google.com/terms/maps-platform/eea/maps-service-terms), müssen für den konkreten Vertrag und Anwendungsfall geprüft werden. Dies ist keine rechtliche Freigabe.
- `RoadStop` speichert heute Name, Untertitel und Koordinaten dauerhaft. Die bisherige Persistenz kann deshalb nicht ungeprüft für Google-Daten übernommen werden; eine Nutzerbestätigung allein begründet keine Speichererlaubnis. Datenherkunft pro Feld, zulässige Speicherdauer und Aktualisierung, Anzeige auf dem jeweils anderen Anbieter und späteren Offline-Export klären. Eigene Notizen, Kategorie, Fortschritt und Budgets von Anbieterinhalten trennen.
- Für eine spätere Migration Sicherung, stabile interne IDs und Beziehungen, fehlende oder veraltete Place IDs, verschwundene Orte, unvollständige Treffer und Offline-Zugriff berücksichtigen. Falls Daten nicht übernommen oder angezeigt werden dürfen, eine sichtbare erneute Zuordnung ermöglichen statt Reisen zu löschen oder Daten stillschweigend zu übertragen. Ob vollständige Reiseportabilität möglich ist, bleibt bis zur Klärung offen.
- Herkunft und notwendige Google-Attribution für Karte und separat angezeigte Details sichtbar halten. Übertragung von Suchtexten, Klickkoordinaten und Wegpunkten sowie Speicherung und externe Links dokumentieren. Auch die separat offene Apple-Prüfung zu alternativen Routenanfragen und Cache bleibt Voraussetzung vor Veröffentlichung.

**Routing, Etappen und Kosten**
- [Google-Wegpunktoptimierung](https://developers.google.com/maps/documentation/routes/opt-way) mit dem bestehenden lokalen Optimierer über eine Google-Fahrzeitmatrix vergleichen: Google berücksichtigt neben Fahrzeit auch Entfernung und Abbiegungen; das entspricht nicht automatisch dem exakten Minimum der bisher abgefragten Fahrzeitmatrix. Festen Start und Ziel sowie Übernachtungsanker bewahren, gegebenenfalls je Etappe rechnen und Vorschläge nur nach Bestätigung übernehmen. Zulässige Nutzung und Wiederverwendung der Daten jeweils prüfen.
- Untersuchen, wie aktuelle Reihenfolge, Routenpolyline, Strecke und Dauer je Teilstrecke für Etappenzeiten und den interpolierten Budgetpunkt bereitgestellt werden. Eine reine Matrix liefert keine dargestellte Routenpolyline. Umgang mit gescheiterten Teilstrecken, API-Limits, zeitabhängigen Fahrzeiten, Fortschritt, Wiederholung und Abbruch festlegen; Verweilzeit- und Budgetlogik nicht unbemerkt verändern.
- Kosten anhand aktueller SKUs, Feldmasken und Quoten für Kartenaufrufe, POI-/Detail- und Textsuche sowie Routing modellieren. Laut [Routes-Abrechnung](https://developers.google.com/maps/documentation/routes/usage-and-billing) wird Compute Routes pro Anfrage und eine Routenmatrix pro Element abgerechnet; Wegpunktoptimierung ist höher bepreist. Budgetwarnungen sind nicht automatisch harte Kostengrenzen. Ohne Google-Schlüssel bleibt Apple verfügbar; fehlende oder ungültige Konfiguration, Netzwerkfehler und Quotenüberschreitungen müssen sichtbar behandelt werden.

**Zugang, Übergabe und Ergebnis**
- Für spätere Tests und Produktion getrennte Konfiguration, API-Beschränkungen, Quoten und Schlüsselrotation bewerten; keine Schlüssel im Repository. Googles [Sicherheitshinweise](https://developers.google.com/maps/api-security-best-practices) nennen HTTP(S)-Referrer für Website-Einschränkungen und weisen darauf hin, dass andere Schemes nicht zuverlässig einen Referer senden. Origin und praktikable Einschränkung einer lokalen `WKWebView` sind deshalb zu klären; ein im Client verwendeter Schlüssel ist kein verborgenes Servergeheimnis.
- Den vorhandenen Button „In Apple Karten öffnen“ nicht stillschweigend umdefinieren. Eine zusätzliche Google-Maps-Übergabe oder providerabhängige Wahl ist gesondert zu entscheiden. [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started) öffnen auf anderen Plattformen Google Maps im Browser und benötigen keinen API-Schlüssel.
- Ergebnis ist eine belegte Entscheidungsvorlage mit Machbarkeitsvergleich, offenen rechtlichen und technischen Fragen, Kosten-/Quotenmodell, Migrations- und Sicherheitsoptionen sowie Go/No-Go und einem möglichen späteren Implementierungszuschnitt. Kriterien für Fake-Provider-Tests, Wechsel während laufender Anfragen, Erhalt von Reisedaten, fehlende Konfiguration, Fehler/Offline und visuellen UI-/Accessibility-Vergleich festhalten. Ein späterer Live-Test mit öffentlichen Daten erfordert eigene Freigabe und gehört nicht zur dokumentationsbasierten Untersuchung.

**Mögliche Umsetzung:** Falls die Untersuchung und der Anbietervergleich dafür sprechen und die Umsetzung gesondert beschlossen wird, folgt hier die Integration des umschaltbaren Providers einschließlich der geprüften Migration, Fehlerbehandlung und Tests. Bis dahin bleibt MapKit unverändert.

## 6. Datenmodell

**Implementiert:** `RoadTrip` speichert ID, Name und Beschreibung. `TripWaypoints` enthält Start, geordnete Zwischenziele, Ziel, die manuelle Sortiereinstellung und das Standard-Zeitbudget. `RoadStop` speichert ID, Name, Untertitel und Koordinaten. Pro Wegpunkt-ID hält `WaypointDetails` die optionale Kategorie, Verweilzeit, Notiz, Bewertung, Besuchsstatus, Übernachtungskennzeichen, Etappenbudget und eine optionale Bestätigung der Budgetüberschreitung fest. Budgets und Verweilzeiten werden als Minuten gespeichert; eine Bestätigung enthält die geordneten Wegpunkt-IDs, das Budget und die bestätigte Ankunftsminute. Etappen und Suchpunkte werden daraus und aus der aktuellen Straßenvorschau abgeleitet. Berechnete Routen und der MapKit-Opt-in werden nicht gespeichert. Ältere Reisen ohne Kategorie bleiben lesbar und erhalten zunächst keine Kategorie.

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
