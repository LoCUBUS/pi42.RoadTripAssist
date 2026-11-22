# RoadTripAssist

Native macOS road-trip planner with local trip management, MapKit place
search, fixed-endpoint waypoint ordering by estimated driving time, and
stage planning with overnight stops and time budgets.

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
clearing a waypoint category. The POI tests use the real map view with fixed
search results. The overnight-search test compares map screenshots at the same
zoom to check for a visible orange outline and an untinted interior. Swift
tests cover marker color and symbol precedence; the UI tests do not visually
verify every marker color or symbol.
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
```

The Bayreuth–Milan benchmark visits Prague, Innsbruck, Salzburg, Passau,
Garmisch-Partenkirchen, and Bolzano before reaching Milan.

To verify that the nearby-place search returns Unbound Coffee in Innsbruck:

```sh
ROADTRIP_LIVE_POI=1 swift test --filter testLiveNearbyPOIsIncludeUnboundCoffee
```

## Prototype scope and limitations

- Use the left sidebar to create, select, edit, and delete trips. Trip names,
  descriptions, waypoints, categories, stage settings and visit progress are
  saved in `~/Library/Application Support/RoadTripAssist/trips.json`. Computed
  routes and the opt-in to automatic routing are not stored.
- Search, map display, and driving directions use Apple MapKit and require an
  internet connection. Search text, clicked map coordinates for nearby places, and
  route coordinates are sent to Apple.
- The native split view contains the trip sidebar and map. The route and stage
  planner is shown in a resizable inspector; use the toolbar button to hide
  or reopen it. The selected place's floating details use Liquid Glass.
- Zoom in and click a place on the standard Apple map. The original symbols
  remain visible. MapKit searches within a zoom-dependent radius of at most
  60 m and highlights the closest match, which may not be the clicked place.
  Check the name and available details, then use "Zur Route hinzufügen" to
  add it as an intermediate stop. "Als Übernachtung hinzufügen" adds it
  as a stop and ends a stage there in one step. Neither button adds a
  duplicate. With no match, nothing is added. In manual mode, when the
  route already has overnight boundaries, or when adding a new overnight
  stop, the insertion gap is chosen by the smallest extra straight-line
  distance. This determines which stage gets the POI. Automatic ordering
  can still reorder movable stops within each stage.
- Type directly in the start and destination fields; results appear below
  the active field as you type. Once both are set, use the plus button to
  add an intermediate stop the same way. Existing stops can be edited in place.
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
  in Apple Maps with driving directions. This does not transfer the entire trip
  or its intermediate stops; Apple Maps determines the route to that point.
- Waypoints without a category use red map markers; categorized waypoints use
  green, and overnight stops use blue even if they have no category. In
  "Etappen", expand a waypoint row to assign or clear an optional category:
  Sight Seeing (binoculars), View Point (mountains), Pause (cup), Wanderung
  (hiker), or Nav-Hilfspunkt (navigation arrow). The same color and symbol
  appear in the route and stage lists. Start and destination use departure and
  finish symbols instead of category symbols, but keep the category color.
  An overnight bed symbol takes precedence over both category and endpoint
  symbols; removing the overnight designation restores the applicable symbol
  and color without deleting the category. A temporarily selected map POI is
  also highlighted in blue until it is added; orange markers represent search
  results or the overnight budget point, not saved waypoint categories.
  An ordinary POI added without a category becomes a red waypoint; an added
  overnight POI is blue.
- Opt into automatic routing to calculate the street route in the current
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
  The optimizer minimizes estimated driving time, not distance. The app
  groups rapid edits and shows the current step: calculating the street route,
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
- Routing reuses directed legs between unchanged waypoints in memory while the
  planner is open. Inserting a waypoint into a fixed route needs only the two
  new adjoining legs if the remaining legs are cached. A separate optimization
  may require additional connections. Without overnight anchors, a fresh
  five-stop plan needs six MapKit requests for its street route and up to 30
  in total for exact optimization. MapKit may throttle requests. If any stage
  has more than 18 movable stops, optimization reports an error; the current
  street route remains available. Cached legs have no expiry and may become
  stale; they and the routing opt-in are not saved across app launches.
  Apple's conditions for optimization requests and in-memory reuse remain
  unresolved and must be checked before release; showing a proposal or
  requesting optimization explicitly does not establish compliance.
- The waypoint search and routing offer a retry after an error. For map
  lookup, click again to retry. Local trips can still be opened and edited
  offline; new place searches and road routes require a connection. A road
  preview already calculated for the current route remains visible if
  fetching alternative legs fails.
- The documentation-based external provider comparison and its deferred
  live tests are recorded in [plan.md](plan.md). Photos and offline HTML
  export are not implemented yet.

## Plan and follow stages

1. **Set overnight stops.** In "Etappen", the larger green headings show
   each stage number and destination. Use the bed icon beside a waypoint
   to mark or unmark it as an overnight stop; a filled icon means it is
   marked. At an intermediate stop this splits or merges stages. The last
   stage always ends at the trip destination. Use "Etappe auf der Karte zeigen"
   for that stage alone or "Gesamtroute auf der Karte" to return to the whole
   trip. Straight-line and driving-time optimization keep overnight
   boundaries fixed and reorder only within stages.
2. **Enter details and budgets.** Click a waypoint row or its chevron to expand
   the inline editor for category, stay time, notes and rating, plus overnight
   and visit status for non-start points. Only one waypoint or stage-budget
   editor is open at a time. Save or explicitly cancel the changes; collapsing
   an editor, opening another, changing views or selecting or creating a trip
   asks before discarding unsaved edits. Removing the edited waypoint or
   deleting its trip warns that unsaved edits will be lost.

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
   adds driving and stay times without
   counting a shared overnight stop twice: its stay belongs to the stage
   that arrives there. Saved stay edits immediately update the stage time,
   without refetching driving directions. If driving time is not yet available,
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
   "Übernachtung … min nach Budget bestätigen". In the dialog, choose
   "Budgetpunkt ausblenden" to hide both the placeholder and the circle,
   or cancel to leave them visible. The warning and route stay unchanged.
   The choice is saved locally, can be reversed with "Budgetpunkt wieder
   anzeigen", and applies only if the stage still has the same ordered
   waypoints and budget and arrives no later than the confirmed minute.
   A cutoff reached only at the already marked overnight stop itself
   does not need a search point.
5. **Manage stops and progress.** The minus icon removes an intermediate stop
   from the route only after confirmation; start and destination are protected.
   Removing an overnight stop merges the adjoining stages. The map icon
   opens just that destination in Apple Maps, using the same button as in
   route planning. In "Reiseverlauf", you can open the next pending destination
   or mark it visited or skipped. Reset its status to "Offen" in the inline
   waypoint details if needed. While those details are open, edit that
   waypoint's status there instead of using the next-destination buttons.
   Status changes do not change the route or its times.
   Deleting or replacing a waypoint also removes its saved details and any
   attached overnight boundary.
