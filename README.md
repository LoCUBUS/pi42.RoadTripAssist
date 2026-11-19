# RoadTripAssist

Native macOS Phase-0 prototype for evaluating MapKit place search, driving
directions, and fixed-endpoint waypoint ordering by estimated driving time.

## Run

Requires macOS 14 or newer and Xcode with the Swift toolchain installed.

```sh
swift run
```

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

- Search, map display, and driving directions use Apple MapKit and require an
  internet connection. Search text and route coordinates are sent to Apple.
- Select start and destination first, then add intermediate stops. The list
  initially orders them by straight-line distance (an insertion heuristic for
  more than ten stops).
- Opt into automatic routing to see the first street route in the provisional
  order, then review and accept a faster order when one is found. The app
  groups rapid edits, shows progress, and lets you pause requests.
- The optimizer reuses directed legs between unchanged waypoints in memory
  while the planner is open. A fresh five-stop plan needs six MapKit requests
  for its first street route and 30 for exact optimization. MapKit may throttle
  requests. Above 18 intermediate stops only the provisional street route is
  calculated.
- Trips are not persisted. Etappen, photos, navigation handoff, external
  routing-provider comparisons, and HTML export are not implemented yet.
