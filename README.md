# RoadTripAssist

Native macOS road-trip planner with local trip management, MapKit place
search and fixed-endpoint waypoint ordering by estimated driving time.

## Run

Requires macOS 14 or newer and Xcode with the Swift toolchain installed.

```sh
swift run
```

The app opens as a regular macOS application and appears in the Dock.

Run the optimizer tests with:

```sh
swift test
```

The optional live benchmarks send public city-center coordinates to Apple and
report the time to the first street route and to the optimized result. Run them
individually:

```sh
ROADTRIP_LIVE_MAPKIT=1 swift test --filter testLiveBayreuthOsloProgress
ROADTRIP_LIVE_MAPKIT=1 swift test --filter testLiveBayreuthMilanProgress
```

The Bayreuth–Milan benchmark visits Prague, Innsbruck, Salzburg, Passau,
Garmisch-Partenkirchen, and Bolzano before reaching Milan.

## Prototype scope and limitations

- Use the left sidebar to create, select, edit, and delete trips. Trip names,
  descriptions, and ordered waypoints are saved automatically in
  `~/Library/Application Support/RoadTripAssist/trips.json`. Computed routes
  and the opt-in to automatic routing are not stored.
- Search, map display, and driving directions use Apple MapKit and require an
  internet connection. Search text and route coordinates are sent to Apple.
- Type directly in the start and destination fields; results appear below
  the active field as you type. Once both are set, use the plus button to
  add an intermediate stop the same way. Existing stops can be edited in place.
  A waypoint changes only after you select a result (Return selects the first).
  Intermediate stops are initially ordered by straight-line distance
  (an insertion heuristic for more than ten stops).
- Opt into automatic routing to see the first street route in the provisional
  order, then review and accept a faster order when one is found. The app
  groups rapid edits and shows the current step: calculating the street route,
  fetching travel times for alternative legs, or comparing stop orders. Each
  MapKit step shows its own request count, and you can pause the calculation.
- The optimizer reuses directed legs between unchanged waypoints in memory
  while the planner is open. A fresh five-stop plan needs six MapKit requests
  for its first street route and 30 for exact optimization. MapKit may throttle
  requests. Above 18 intermediate stops only the provisional street route is
  calculated.
- Etappen, photos, navigation handoff, external routing-provider comparisons,
  and HTML export are not implemented yet.
