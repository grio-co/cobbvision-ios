import CoreLocation
import Foundation

/// A single GPS sample recorded during a drive session.
struct TrackPoint: Codable {
    let latitude:           Double
    let longitude:          Double
    let altitude:           Double   // metres
    let speedMS:            Double   // m/s  (negative = invalid, treat as 0)
    let horizontalAccuracy: Double   // metres
    let timestamp:          Date

    /// Speed in km/h, clamped to ≥ 0.
    var speedKPH: Double { max(0, speedMS) * 3.6 }

    /// Speed in mph, clamped to ≥ 0.
    var speedMPH: Double { max(0, speedMS) * 2.23694 }

    init(latitude: Double,
         longitude: Double,
         altitude: Double,
         speedMS: Double,
         horizontalAccuracy: Double,
         timestamp: Date) {
        self.latitude           = latitude
        self.longitude          = longitude
        self.altitude           = altitude
        self.speedMS            = speedMS
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp          = timestamp
    }

    init(from location: CLLocation) {
        latitude           = location.coordinate.latitude
        longitude          = location.coordinate.longitude
        altitude           = location.altitude
        speedMS            = location.speed
        horizontalAccuracy = location.horizontalAccuracy
        timestamp          = location.timestamp
    }
}

// MARK: - Session model

/// A complete recorded drive session ready for upload.
struct DriveSession: Identifiable, Codable {
    let id:         UUID
    let startedAt:  Date
    var endedAt:    Date?
    var trackPoints: [TrackPoint]
    var vehicleId:  String?   // set by user before upload
    var uploaded:   Bool = false

    /// `DriveSession()` starts a new, empty session now; the parameters exist so
    /// a session can be rebuilt with fixed values (tests, migrations).
    init(id: UUID = UUID(),
         startedAt: Date = Date(),
         endedAt: Date? = nil,
         trackPoints: [TrackPoint] = [],
         vehicleId: String? = nil,
         uploaded: Bool = false) {
        self.id          = id
        self.startedAt   = startedAt
        self.endedAt     = endedAt
        self.trackPoints = trackPoints
        self.vehicleId   = vehicleId
        self.uploaded    = uploaded
    }

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var pointCount: Int        { trackPoints.count }

    /// Bounding box for quick map display.
    var latitudeRange:  ClosedRange<Double>? {
        guard !trackPoints.isEmpty else { return nil }
        let lats = trackPoints.map(\.latitude)
        return lats.min()! ... lats.max()!
    }
}
