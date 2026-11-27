# RoadTripAssist

Native macOS road-trip planner with local trip management, MapKit place
search, fixed-endpoint waypoint ordering by estimated travel time, and
stage planning with overnight stops, round trips and time budgets.

## Run

Requires macOS 27 or newer and Xcode with the macOS 27 SDK and Swift toolchain.
The app no longer supports macOS 26 or earlier.

```sh
swift run
```

The app opens as a regular macOS application and appears in the Dock.

Run the Swift Package tests with:

```sh
swift test
```

## macOS UI tests

Run XCUITest from an active, unlocked macOS desktop session:

```sh
xcodebuild test -project RoadTripAssist.xcodeproj -scheme RoadTripAssist \
  -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath .build/ui-tests
```

The default tests use isolated temporary storage and fixed search and routing
data. They cover trip editing and persistence, waypoint reordering, distance,
ordinary and overnight POI insertion, stage splitting and merging, removal
confirmation, live updates to stage totals after editing stay times, and
handoff to the next pending Apple Maps destination, explicit route
optimization and acceptance, and showing and hiding alternative connections.
They also cover the inline waypoint and stage-budget editors, including
validation, persistence, default-budget inheritance and protection against
discarding unsaved edits; canceling, accepting, and reversing a budget
overrun; hiding and restoring the route inspector; and saving, reopening, and
clearing a waypoint category. They also verify that a route card displays and
edits a waypoint's category and stay duration, and that the saved values appear
in the stage list. Photo tests cover EXIF date/GPS parsing, geolocation-based
assignment suggestions, local copy and persistence, and persistent photo
rotation; a UI test opens the photo manager for a selected trip. The POI tests
use the real map view with fixed search results. The overnight-search test compares map screenshots at
the same zoom to check for a visible orange outline and an untinted interior.
Swift tests cover marker color and symbol precedence; the UI tests do not
visually verify every marker color or symbol.
The departure-date UI test enables a start date and time, reopens the trip,
and removes it again. Swift tests additionally check legacy data, per-trip
storage and selection, MapKit request construction, cache invalidation,
optimization, missing legs and parking checks. Photo tests also cover reuse of
an existing waypoint and restoration of media and metadata after a failed
save. Swift tests additionally cover separate lodging-tour routing and
totals, multiple tours per lodging, endpoint synchronization, legacy migration
and photo/transit assignments, including adding a photo location to a selected
tour instead of reusing a nearby main-journey waypoint. UI regression tests exercise deletion from the
photo map popover, round-trip creation, deletion and persistence, travel modes,
transit handoff, and changing the trip type. They also check choosing a main
journey or one of several tours for a map POI, preventing duplicates per
context, reopening the trip, editing tour waypoint details, and protecting
unsaved tour edits.
The latest full Swift run executed 107 tests with no failures; four optional
live MapKit tests were skipped. The latest full UI run executed 26 tests with
no failures; the optional Apple Maps smoke test was skipped.
An additional UI regression test verifies that combined-map tour markers remain
present before and after main-journey routing and after reopening; it passed
after the marker fix. The full UI suite above predates this additional test.
The system Photos and file pickers and every hover animation are not covered by
these automated tests.
The exchange and HTML save/open panels and the exchange privacy confirmation
have a separate UI test that opens and cancels them; choosing a file in those
system panels is not automated. The export menu is checked in the selected
trip row and its unsaved-edit safeguard is exercised. Swift tests cover exchange
roundtrips with photos and lodging tours, including preserving and correcting
unavailable photo assignments, import rollback and malformed or oversized
archives, plus local WebKit loading and photo metadata removal for HTML export.
On multi-monitor setups, screenshot tests move their test window to the main
display.
Default tests neither use real trips nor launch Apple Maps.
To also verify that Apple Maps opens with a public landmark as the requested
destination, prefix the command with `TEST_RUNNER_ROADTRIP_LIVE_MAPS=1`.
This smoke test checks that Maps comes to the foreground and opens a window,
not the directions rendered inside Maps.

The Xcode project uses the same app sources as the Swift package.
After adding or removing app or UI test source files, regenerate it with
`xcodegen generate` using `project.yml`.

## Live MapKit checks

The optional live benchmarks send public city-center coordinates to Apple and
report the time to the first street route and to the optimized result. Run them
individually:

```sh
ROADTRIP_LIVE_MAPKIT=1 swift test --filter testLiveBayreuthOsloProgress
ROADTRIP_LIVE_MAPKIT=1 swift test --filter testLiveBayreuthMilanProgress
ROADTRIP_LIVE_MAPKIT=1 swift test --filter testLiveWalkingRoundTripInBerlin
```

The Bayreuth–Milan benchmark visits Prague, Innsbruck, Salzburg, Passau,
Garmisch-Partenkirchen, and Bolzano before reaching Milan.
The walking check requests a round trip around Berlin landmarks, both without
a departure date and with a future date.

To verify that the nearby-place search returns Unbound Coffee in Innsbruck:

```sh
ROADTRIP_LIVE_POI=1 swift test --filter testLiveNearbyPOIsIncludeUnboundCoffee
```

## Prototype scope and limitations

- Use the left sidebar to create, select, edit, and delete trips. Trip names,
  descriptions, optional departure dates, waypoints, categories, stage settings and visit progress are
  saved in `~/Library/Application Support/RoadTripAssist/trips.json`. Computed
  routes and the opt-in to automatic routing are not stored. The app reopens
  the last selected trip; that selection is saved separately in
  `selected-trip.json`.
- Search, map display, walking and driving directions, and transit estimates
  use Apple MapKit and require an internet connection. Search text, clicked map coordinates for nearby places,
  route coordinates and any selected departure date are sent to Apple.
- When creating a trip or using "Bearbeiten", enable "Reisestart festlegen"
  to choose a start date and time; disable it to remove the date. The sidebar
  shows the selected date in the Mac's current time zone. The stored value is
  an absolute point in time, so its displayed local time can change when the
  time zone changes. Existing trips have no departure date until one is set.
  Without one, MapKit receives no departure date and uses its own defaults.
- MapKit receives the same trip departure date and time for every current and
  alternative connection, including transit estimates and parking-access
  checks. This is a planning approximation: travel times, waypoint stays and overnight stops do
  not advance the departure time of later legs. Changing or removing the date
  clears cached legs and route suggestions and recalculates the current route
  if automatic routing is enabled; optimization must be started again.
  MapKit may use the date to adjust its estimates, but does not guarantee a
  route or ignore current road closures. Check actual conditions before travel.
- Choose "Start–Ziel" or "Rundtour" when creating or editing a trip. A standalone
  round trip returns to its start and has exactly one stage. In "Etappen",
  mark a stop or destination as an overnight stop and use "Rundtour hinzufügen"
  to attach one or more independent tours to it. Their inline cards appear
  under the lodging in the route and stage views. Each tour has its own
  waypoints, travel mode, budget, transit markings, routing controls and
  diagnostics. Tour waypoint cards use the same editable place, category and
  stay-duration presentation as the main journey. Click a waypoint heading to
  focus it on the map; change the place by editing the name and selecting a
  search result. Calculate and optimize the main journey and each tour separately.
  The combined total is displayed only when every route is complete; it includes
  main-journey stays and intermediate tour stays without counting the lodging
  stay a second time. A selected map POI can be added to the main journey or
  to a chosen tour, regardless of which route is displayed; each route prevents
  its own duplicates. The same place can therefore occur in different routes.
  Use the tour's map button to show it alone, or "Hauptreise und Rundtouren"
  to return to the combined map, which draws each route separately.
  Tour waypoint markers remain visible in the combined map before, during and
  after main-journey routing, including after reopening without cached routes.
  Photo assignment and photo waypoint insertion also distinguish the main
  journey from each tour.
  Changing the lodging moves its tours' endpoints after confirmation; remove
  its tours before deleting it. A tour cannot contain another overnight
  boundary. Photos remain when a tour is removed, but assignments to removed
  points may no longer resolve. Removing a tour waypoint is immediate unless
  transit markings require confirmation; deleting the whole tour requires
  confirmation.
- After confirmation, converting a start–destination trip to a standalone
  round trip combines the main journey and all lodging-tour waypoints in their
  existing order. The previous destination becomes a stop; all intermediate
  overnight boundaries are removed, the first stage's mode is used, explicitly
  set budgets are added, and old budget-overrun confirmations are reset.
  Transit markings for still-adjacent directed pairs are kept, but are inactive
  in driving mode. Converting back removes the return to the start and makes
  the last stop the destination. Assignments and transit markings on a removed
  return leg may no longer be valid. If tour-start details cannot be merged
  safely, conversion fails without modifying the saved trip.
- On loading older trips, embedded lodging tours are extracted and standalone
  round trips with multiple stages are merged. Only explicit budgets are
  added, and the first stage's mode is used; a notice identifies missing budgets
  and reset confirmations.
  Confirmed and suggested photo assignments are migrated where unambiguous;
  unresolved assignments remain intact and are reported for review. Migration
  is written atomically, and ambiguous or invalid legacy data is not overwritten.
- Choose "Fahren" or "Zu Fuß" for each stage in "Routeneinstellungen" or
  "Etappen". Older trips default to driving. In a walking stage, mark an
  individual directed connection as ÖPNV. MapKit only provides a transit
  time and distance estimate; the dotted line is straight-line guidance, not
  a transit route. Opening the destination in Apple Maps requests transit
  directions, where the actual itinerary must be checked. Availability
  depends on Apple's regional data. Missing estimates are reported as missing
  connections; other successful legs remain visible, without a complete total.
  Transit estimates use the same trip start time for all legs and are not a
  coordinated timetable. Changing to driving temporarily disables transit
  markings; changing back restores them if the points remain adjacent.
  Reordering, inserting or deleting points removes markings for pairs that are
  no longer adjacent. The app warns before a change and before accepting an
  optimization that removes markings. Optimization uses transit only for
  marked directed pairs. A budget cutoff inside a transit leg cannot be
  located on the map, and photo suggestions do not treat its dotted line as
  the actual route.
- The native split view contains the trip sidebar and map. The route and stage
  planner is shown in a resizable inspector; use the toolbar button to hide
  or reopen it. The selected place's floating details use Liquid Glass.
- Zoom in and click a place on the standard Apple map. The original symbols
  remain visible. MapKit searches within a zoom-dependent radius of at most
  60 m and highlights the closest match, which may not be the clicked place.
  Check the name and available details, then use "Zur Route hinzufügen" to
  add it as an intermediate stop. If lodging tours exist, choose "Zur Hauptreise
  hinzufügen" or "Zur Rundtour hinzufügen"; the latter offers a tour selection
  when there is more than one. "Als Übernachtung hinzufügen" adds it
  to the main journey as a stop and ends a stage there in one step; when tours
  exist the button explicitly names the main journey. Duplicate detection is
  per route: a matching name (ignoring case and accents) within 50 m is
  considered the same place. With no match, nothing is added. In manual mode, when the
  route already has overnight boundaries, or when adding a new overnight
  stop, the insertion gap is chosen by the smallest extra straight-line
  distance. This determines which stage gets the POI. Automatic ordering
  can still reorder movable stops within each stage.
- Type directly in the start and destination fields; results appear below
  the active field as you type. Once both are set, use the plus button to
  add an intermediate stop the same way. Existing stops can be edited in place.
  Clicking the heading above an existing waypoint centers the map with
  approximately 10 km around it; names in the stage list and unavailable
  connections work too.
  A waypoint changes only after you select a result (Return selects the first).
  Intermediate stops are initially ordered by straight-line distance
  (an insertion heuristic for more than ten stops). Use the up/down arrows
  to choose a manual order. New stops added through the plus button are
  appended in manual mode; map selections are inserted as described above.
  "Nach Luftlinie sortieren" switches back to automatic ordering. When stages
  exist, a stop added by text search goes into the final stage.
  Use the lock button ("Aktuelle Reihenfolge fixieren") to keep the current
  order on later edits. Accepting a faster suggestion also fixes it and persists
  that choice. Hover over the routing symbols for their descriptions.
- Use the map button beside a waypoint to open that individual destination
  in Apple Maps with the incoming leg's mode. This does not transfer the entire trip
  or its intermediate stops; Apple Maps determines the route to that point.
- Waypoints without a category use red map markers; categorized waypoints use
  green, except photo waypoints, which are purple until they have a stay
  duration and then turn green. Overnight stops use blue even if they have no
  category. The Route
  cards show each selected waypoint's category and stay duration; expand the
  details there or in "Etappen" to edit them. Categories include Sight Seeing
  (binoculars), View Point (mountains), Pause (cup), Wanderung (hiker), and
  Nav-Hilfspunkt (navigation arrow), and Foto (photo). The same color and symbol appear in the
  route and stage lists. Start and destination use departure and finish symbols
  instead of category symbols, but keep the category color.
  An overnight bed symbol takes precedence over both category and endpoint
  symbols; removing the overnight designation restores the applicable symbol
  and color without deleting the category. A temporarily selected map POI is
  also highlighted in blue until it is added; orange markers represent search
  results or the overnight budget point, not saved waypoint categories.
  An ordinary POI added without a category becomes a red waypoint; an added
  overnight POI is blue.
- Open "Fotos verwalten" for the selected trip to import multiple images from
  the Photos library or Files. The app keeps local copies and does not change
  the source images. It reads EXIF capture time and GPS data when available;
  geotagged photos appear as small thumbnails on the route map and in the photo
  manager. Clicking a thumbnail on either map opens a larger photo popup.
  Icon-only rotate controls appear in the photo's upper corners while hovering;
  the popup also has the saved description, a waypoint action and a delete
  action with confirmation. Selecting one in the manager also centers its map
  on that location. Rotation
  is stored with the trip without changing the local image copy. With a route
  start and destination set, a photo location can be added as a waypoint and
  assigned to that waypoint. In the photo manager, choose the main journey or
  a specific tour when tours exist. A photo popup on an individually selected
  tour adds to that tour. Only waypoints in the chosen context are considered
  for reuse: an existing waypoint within 50 m is reused without changing its
  details.
  GPS suggests a nearby waypoint (within 2 km), route segment (within 2 km), or
  stage (within 20 km of a waypoint). Suggestions are never applied
  automatically: confirm one or assign the photo manually. Captions and
  assignments are saved with the trip. Photo files and metadata are stored
  locally. If a photo location is added as a waypoint and routing is enabled,
  its coordinates are sent to Apple as part of the routing request. Map display
  also uses Apple MapKit.
- Use the export icon beside the selected trip → "Reisedatei …" to save it as a `.roadtrip` file;
  "Reise importieren …" adds it to the local library as a new independent copy.
  Export again to transfer subsequent changes. Existing trips are not replaced
  or synchronized, and opening the file directly in Finder is not supported.
  The ZIP-based version 1 format contains the complete trip and original photo
  copies, including any GPS/EXIF metadata. It is not encrypted. It may therefore
  expose private locations, notes and photos to anyone with the file.
  Calculated routes and routing consent are not included. Photo assignments to
  removed waypoints, stages or segments remain unchanged, are marked as no
  longer available in the photo manager, and can be reassigned there. Missing
  photos, unsupported versions and invalid archives
  are reported rather than silently imported. The limits are 10,000 photos, 100 MiB
  per photo, 10 MiB for the manifest and 1 GiB of uncompressed data in total.
- Use the export icon → "HTML-Reisetagebuch …" to create a new folder containing
  `index.html`, stage and lodging-tour pages, a stylesheet and a `media` folder.
  Open the overview in a browser; no network resources are required. The route
  is a static schematic, not a street or city map. Calculated road geometry is included
  when available; missing routes and transit legs appear as dashed straight
  lines. Before distributing this feature, the applicable Apple Maps terms
  must be reviewed for the exported route geometry, location data and any future map
  imagery. HTML photos are converted to PNG with a maximum dimension of 4096
  pixels and without original GPS/EXIF metadata; a missing photo is noted.
  The HTML still contains trip locations and notes and is not an import format.
- Opt into automatic routing to calculate connections in the current
  order after waypoint changes. For a selected trip, the "Reihenfolge
  optimieren" symbol remains visible next to the automatic-routing control;
  it is enabled when start,
  destination and at least one intermediate stop are set, automatic routing is
  on, and no calculation is running. Use it separately to compare orders; the
  current route stays selected unless you accept the
  faster proposal. The app shows the duration and distance of both choices,
  and lets you switch the map between them before acceptance. The info symbol
  opens the full suggested order and time saving. It offers one
  best-order proposal, not multiple road alternatives for each leg.
  The optimizer minimizes estimated travel time, not distance. The app
  groups rapid edits and shows the current step: calculating the current route,
  fetching travel times for alternative legs, or comparing stop orders. Each
  MapKit step shows its own request count, and you can pause the calculation.
- During or after optimization, use the "Alternative Verbindungen" symbol to
  open a popover. Turn "Auf Karte anzeigen" on or off to overlay successfully
  calculated connections not in the current route as dashed purple lines. The list
  shows their direction, estimated time and distance and lets you display all
  or select one.
  The selected route remains blue and unchanged. These are individual
  connections considered for reordering, not complete alternative trips or
  multiple road options for the same connection. Selecting a stage limits the
  overlay to connections inside it. Waypoint or overnight-boundary changes
  clear the comparison; available results are kept if optimization fails.
- Routing reuses directed legs between unchanged waypoints, the same
  transport mode and departure date in memory while the
  planner is open. Inserting a waypoint into a fixed route needs only the two
  new adjoining legs if the remaining legs are cached. A separate optimization
  may require additional connections. Without overnight anchors, a fresh
  five-stop plan needs six MapKit requests for its current route and up to 30
  in total for exact optimization. MapKit may throttle requests. If any stage
  has more than 18 movable stops, optimization reports an error; the current
  route remains available. Cached legs have no expiry and may become
  stale; they and the routing opt-in are not saved across app launches.
  Apple's conditions for optimization requests and in-memory reuse remain
  unresolved and must be checked before release; showing a proposal or
  requesting optimization explicitly does not establish compliance.
- The waypoint search and routing offer a retry after an error. For map
  lookup, click again to retry. Local trips can still be opened and edited
  offline; new place searches and road routes require a connection. A road
  preview already calculated for the current route remains visible if
  fetching alternative legs fails. When MapKit finds no driving route for a
  current connection, both endpoint names are shown. MapKit does not identify
  which point or cause is responsible: check access to both locations and
  consider a nearby parking place and walking the remaining distance. Click
  the concise failure message for a local diagnostic popover with affected
  connections, coordinates, available error domains, codes and underlying
  errors. While a calculation is running or paused, "Diagnose anzeigen" opens
  the same popover: it updates with completed errors, the current request,
  transport mode and elapsed time. A pending request may not yet have an error
  to report. A missing MapKit explanation is explicitly identified; network errors
  and the app's timeout are distinguished when possible. Available current connections
  remain visible individually on the map even when other connections fail;
  no complete trip total is shown for an incomplete route. For an unavailable
  connection, search on demand for parking near either endpoint: the app checks
  up to five nearby candidates within 2 km against the adjacent driving legs
  if used as a replacement. Results can be located on the map, but do not
  change the original waypoint; walking routes and access are not verified.
- The documentation-based external provider comparison and its deferred
  live tests are recorded in [plan.md](plan.md).

## Plan and follow stages

1. **Set overnight stops.** In "Etappen", the larger green headings show
   each stage number and destination. Use the bed icon beside a waypoint
   to mark or unmark it as an overnight stop; a filled icon means it is
   marked. At an intermediate stop this splits or merges stages. The last
   stage always ends at the trip destination. Use "Etappe auf der Karte zeigen"
   for that stage alone or "Gesamtroute auf der Karte" to return to the whole
   trip. Straight-line and travel-time optimization keep overnight
   boundaries fixed and reorder only within stages.
2. **Enter details and budgets.** Click a waypoint row or its chevron to expand
   the inline editor for category, stay time, notes and rating, plus overnight
   and visit status for non-start points. Only one waypoint or stage-budget
   editor is open at a time. Save or explicitly cancel the changes. When an
   action would discard unsaved edits, such as opening another editor, switching
   from stages to the route view, or selecting or creating a trip, the app asks
   first. Switching from route to stages retains the draft. Removing an edited
   main-journey waypoint or deleting its trip warns that unsaved edits will be
   lost; tour waypoint controls are disabled while a tour editor is open.

   Enter durations as `hh:mm`: `00:45` means 45 minutes and `00:00` means
   no stay. Set the optional default time budget for all stages (e.g. `06:30`)
   in the standard-budget dialog. Click a stage heading to expand its
   individual budget editor; the same override is also available in the
   details of the stage's final waypoint. Leave an override blank to inherit
   the default, or leave the default blank to set no default budget. A set
   budget must be greater than `00:00`, with minutes from `00` to `59`.
   The override belongs to the stage's final waypoint; removing an intermediate
   overnight designation clears its override when the stages merge.
   The bed button is disabled for the waypoint currently being edited; change
   its overnight status in its details or close the editor first. "Etappenzeit"
   adds travel and stay times without
   counting a shared overnight stop twice: its stay belongs to the stage
   that arrives there. Saved stay edits immediately update the stage time,
   without refetching directions. If driving time is not yet available,
   the display reads e.g. "45 min + ausstehende Fahrzeit". The budget itself
   does not change.
3. **Find an overnight stop near the budget point.** With a calculated road
   route, an over-budget stage can show "Zeitbudget erreicht · Übernachtung
   suchen" at the first estimated cutoff. During a stay, that point is at
   the waypoint; during a drive, it is estimated along the road geometry.
   Click the placeholder to zoom to the orange bed marker and unfilled
   **5 km diameter** circle. Use the normal map POI selection and
   "Als Übernachtung hinzufügen" to add a place yourself. The placeholder
   does not search for hotels or change the route.
4. **Accept a later overnight arrival if needed.** If the stage reaches the
   planned overnight stop after the budget runs out, its summary offers
   "Übernachtung hh:mm nach Budget bestätigen". Overruns use hours and minutes
   (e.g. `01:15` for 75 minutes). In the dialog, choose
   "Budgetpunkt ausblenden" to hide both the placeholder and the circle,
   or cancel to leave them visible. The warning and route stay unchanged.
   The choice is saved locally, can be reversed with "Budgetpunkt wieder
   anzeigen", and applies only if the stage still has the same ordered
   waypoints and budget and arrives no later than the confirmed minute.
   A cutoff reached only at the already marked overnight stop itself
   does not need a search point.
5. **Manage stops and progress.** In the main journey, the minus icon removes
   an intermediate stop only after confirmation; start and destination are protected.
   Removing an overnight stop merges the adjoining stages. The map icon
   opens just that destination in Apple Maps, using the same button as in
   route planning. In "Reiseverlauf", you can open the next pending destination
   or mark it visited or skipped. Reset its status to "Offen" in the inline
   waypoint details if needed. While those details are open, edit that
   waypoint's status there instead of using the next-destination buttons.
   Status changes do not change the route or its times.
   Deleting or replacing a waypoint also removes its saved details and any
   attached overnight boundary.
