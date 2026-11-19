# RoadTripAssist

Native macOS road-trip planner with local trip management, MapKit place
search and fixed-endpoint waypoint ordering by estimated driving time.

## Run

Requires macOS 14 or newer and Xcode with the Swift toolchain installed.

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
data. They verify editing, reordering, the displayed distance, persistence
after relaunch, the Apple Maps handoff payload, and finding and adding a POI
by clicking the map. They do not use real trips or launch Apple Maps by
default; the POI test uses the real map view with fixed search results.
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
  descriptions, ordered waypoints, and the manual-order setting are saved in
  `~/Library/Application Support/RoadTripAssist/trips.json`. Computed routes
  and the opt-in to automatic routing are not stored.
- Search, map display, and driving directions use Apple MapKit and require an
  internet connection. Search text, clicked map coordinates for nearby places, and
  route coordinates are sent to Apple.
- Zoom in and click a place on the standard Apple map. The original symbols
  remain visible. MapKit searches within a zoom-dependent radius of at most
  60 m and highlights the closest match, which may not be the clicked place.
  Check the name and available details, then use "Zur Route hinzufügen" to
  add it as an intermediate stop. With no match, nothing is added. Placement
  starts with straight-line distances. In manual mode the new stop goes
  into the gap with the smallest extra distance without reordering earlier stops.
  If automatic routing is enabled, a faster order can still be proposed.
- Type directly in the start and destination fields; results appear below
  the active field as you type. Once both are set, use the plus button to
  add an intermediate stop the same way. Existing stops can be edited in place.
  A waypoint changes only after you select a result (Return selects the first).
  Intermediate stops are initially ordered by straight-line distance
  (an insertion heuristic for more than ten stops). Use the up/down arrows
  to choose a manual order. New stops added through the plus button are
  appended in manual mode; map selections are inserted as described above.
  "Nach Luftlinie sortieren" switches back to automatic ordering.
  Routing can still suggest a faster order, which must be explicitly accepted.
- Use the map button beside a waypoint to open that individual destination
  in Apple Maps with driving directions. This does not transfer the entire trip
  or its intermediate stops; Apple Maps determines the route to that point.
- Opt into automatic routing to see the first street route in the current
  order, then review and accept a faster order when one is found. The app
  displays the road distance for the current route and for any proposal.
  The optimizer minimizes estimated driving time, not distance. The app
  groups rapid edits and shows the current step: calculating the street route,
  fetching travel times for alternative legs, or comparing stop orders. Each
  MapKit step shows its own request count, and you can pause the calculation.
- The optimizer reuses directed legs between unchanged waypoints in memory
  while the planner is open. A fresh five-stop plan needs six MapKit requests
  for its first street route and 30 for exact optimization. MapKit may throttle
  requests. Above 18 intermediate stops only the street route in the current order is
  calculated.
- The waypoint search and routing offer a retry after an error. For map
  lookup, click again to retry. Local trips can still be opened and edited
  offline; new place searches and road routes require a connection. A road
  preview already calculated for the current route remains visible if
  fetching alternative legs fails.
- The documentation-based external provider comparison and its deferred
  live tests are recorded in [plan.md](plan.md). Trip stages are next; photos
  and offline HTML export are not implemented yet.
