# cobbvision-ios

CobbVision Companion for iOS — a GPS track recorder for Cobb Accessport datalog sessions.

## What it does

The Cobb Accessport logs engine data (`datalog*.csv`) while you drive, but those logs
carry no position. This app runs on the phone in the car, records a GPS track for the
same drive, and uploads it to the CobbVision backend, which matches the track to the
Accessport datalog session (a "Trip") by time so logs can be viewed against location,
speed and route.

The app does **not** read Accessport datalog files itself. It only produces GPS data:

- **Records** `CLLocation` samples (latitude, longitude, altitude, speed, horizontal
  accuracy, timestamp) at the best navigation accuracy, with background location
  enabled so recording continues if you switch apps.
- **Filters** out fixes with a horizontal accuracy worse than 30 m (or negative/invalid).
- **Stores** completed sessions locally as JSON (`Documents/sessions.json`) so they can
  be uploaded later.
- **Exports** each session as a GPX 1.1 file (see [Export format](#export-format)).
- **Uploads** the GPX to `POST /api/v1/gps-track` on the CobbVision server as
  `multipart/form-data` with the fields `vehicle_id`, `device`, `source_type=device_app`
  and the `gpx` file part (`application/gpx+xml`). The server responds with
  `gps_track_id`, `point_count` and, when it could auto-correlate the track with a
  datalog, `trip_id` and `match_confidence`.
- **Lists vehicles** from `GET /api/v1/vehicles` (the response includes each vehicle's
  Accessport serial, `ap_serial`) so a track can be attached to the right car.

The server URL and API key are entered on the Settings screen (stored in `UserDefaults`
under `api_base_url` / `api_key`); the key comes from the Account page of the CobbVision
web app.

## Source layout

```
Sources/CobbVisionCompanion/
  App.swift                      SwiftUI entry point
  Models/TrackPoint.swift        TrackPoint and DriveSession models (Codable)
  Services/LocationManager.swift CLLocationManager wrapper: start/stop recording, accuracy filter
  Services/SessionStore.swift    Local persistence + upload queue
  Services/GPXExporter.swift     DriveSession -> GPX 1.1 string / temp file
  Services/APIClient.swift       CobbVision REST client (vehicles, GPS track upload)
  Views/                         Session, History, Upload, Settings screens
Resources/                       Info.plist, entitlements
Tests/CobbVisionCompanionTests/  XCTest unit tests
project.yml                      XcodeGen project spec
```

## Building

The Xcode project is not committed; it is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

- Xcode 15 or newer (`project.yml` targets Xcode 15; CI uses Xcode 16.4)
- Swift 5.9, iOS 16.0 deployment target
- No third-party dependencies: there is no `Package.swift` or `Podfile`; the app uses
  only SwiftUI, CoreLocation, Combine and Foundation.

```sh
brew install xcodegen
xcodegen generate
open CobbVisionCompanion.xcodeproj
```

Scheme: `CobbVisionCompanion`. To build for the simulator without signing:

```sh
xcodebuild build \
  -project CobbVisionCompanion.xcodeproj \
  -scheme CobbVisionCompanion \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest" \
  CODE_SIGNING_ALLOWED=NO
```

To run on a device, set `DEVELOPMENT_TEAM` in `project.yml` to your Apple Team ID and
regenerate the project. CI (`.github/workflows/build.yml`) generates the project,
builds for the simulator, runs the unit tests and runs SwiftLint (non-blocking).

### Tests

```sh
xcodebuild test \
  -project CobbVisionCompanion.xcodeproj \
  -scheme CobbVisionCompanion \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=latest" \
  CODE_SIGNING_ALLOWED=NO
```

The `CobbVisionCompanionTests` target covers track recording (accumulating
`CLLocation` samples into a `DriveSession`, accuracy filtering, stop/finalise) and GPX
export (structure, field formatting, escaping, empty and single-point tracks).

## Permissions

Declared in `Resources/Info.plist`:

| Key | Purpose |
| --- | --- |
| `NSLocationWhenInUseUsageDescription` | Record the GPS track during a drive session. |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Keep recording in the background if you switch apps. |
| `NSLocationAlwaysUsageDescription` | Same, for older iOS versions. |
| `UIBackgroundModes` = `location`, `fetch` | Background location updates; background fetch for uploads. |
| `UIRequiredDeviceCapabilities` = `gps`, `armv7` | Requires a device with GPS. |

The app requests *Always* authorization (`requestAlwaysAuthorization`) and shows the
background location indicator while recording.

`Resources/CobbVisionCompanion.entitlements` declares an empty
`com.apple.security.application-groups` array; no other entitlements are needed. Network
access (upload) needs no entitlement on iOS.

## Export format

`GPXExporter` produces a GPX 1.1 document. Speed is written with the Garmin
`TrackPointExtension` v2 schema so it is understood by common tools.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="CobbVision Companion/1.0"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2" ...>
  <metadata>
    <name>CobbVision 2026-09-26 14:05</name>
    <time>2026-09-26T21:05:00.000Z</time>
  </metadata>
  <trk>
    <name>CobbVision 2026-09-26 14:05</name>
    <trkseg>
      <trkpt lat="45.5231" lon="-122.6765">
        <ele>15.20</ele>
        <time>2026-09-26T21:05:01.000Z</time>
        <extensions>
          <gpxtpx:TrackPointExtension>
            <gpxtpx:speed>12.3400</gpxtpx:speed>
          </gpxtpx:TrackPointExtension>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
```

Fields:

| Element | Source | Format |
| --- | --- | --- |
| `metadata/name`, `trk/name` | session start (local time) | `CobbVision yyyy-MM-dd HH:mm` |
| `metadata/time` | `DriveSession.startedAt` | ISO 8601 UTC with fractional seconds |
| `trkpt@lat`, `trkpt@lon` | `TrackPoint.latitude/longitude` | degrees, full `Double` precision |
| `ele` | `TrackPoint.altitude` | metres, 2 decimals |
| `time` | `TrackPoint.timestamp` | ISO 8601 UTC with fractional seconds |
| `gpxtpx:speed` | `TrackPoint.speedMS` | m/s, 4 decimals, clamped to ≥ 0 |

One `<trk>` with a single `<trkseg>` per session; an empty session yields a valid GPX
file with an empty `<trkseg>`. Horizontal accuracy is used for filtering but is not
written to the file. The export file name is `cobbvision_<unix start seconds>.gpx`, written
to the temporary directory before upload.

The same format is produced by the Android companion app, so the backend accepts either.

## CobbVision family

- [cobbvision-ios](https://github.com/grioghar/cobbvision-ios) — this repo: iOS companion app (GPS track recorder).
- [cobbvision-android](https://github.com/grioghar/cobbvision-android) — Android companion app; records the same GPX track format.
- [APi](https://github.com/grioghar/APi) — AccessPort Investigator: ingesting, processing, plotting and diagnostics for the Accessport `datalog*.csv` files themselves.
