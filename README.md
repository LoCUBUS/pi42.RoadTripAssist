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

## Prototype scope and limitations

- Search, map display, and driving directions use Apple MapKit and require an
  internet connection. Search text and route coordinates are sent to Apple.
- Before calculating a route, the app shows how many individual directions
  requests it will make. Requests are sequential; MapKit may throttle them.
- Intermediate stops are ordered using an exact dynamic-programming optimizer,
  with start and destination fixed. The prototype solver supports up to 18
  intermediate stops, but the MapKit request count grows quadratically and may
  become impractical much earlier.
- Trips are not persisted. Etappen, photos, navigation handoff, external
  routing-provider comparisons, and HTML export are not implemented yet.
