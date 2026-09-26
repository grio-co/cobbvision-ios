import CoreLocation
import XCTest
@testable import CobbVisionCompanion

/// Covers the recording path: CLLocation samples arriving through the
/// CLLocationManagerDelegate callback are filtered and accumulated into the
/// current DriveSession, and stopRecording() finalises the session.
final class TrackRecordingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func location(lat: Double = 45.0,
                          lon: Double = -122.0,
                          accuracy: Double = 5,
                          speed: Double = 10,
                          altitude: Double = 100,
                          offset: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: altitude,
                   horizontalAccuracy: accuracy,
                   verticalAccuracy: 5,
                   course: 0,
                   speed: speed,
                   timestamp: t0.addingTimeInterval(offset))
    }

    /// A LocationManager placed directly into the recording state, bypassing
    /// the authorization prompt that startRecording() would trigger.
    private func recordingManager() -> LocationManager {
        let lm = LocationManager()
        lm.currentSession = DriveSession()
        lm.isRecording    = true
        return lm
    }

    private let dummyCLManager = CLLocationManager()

    // MARK: - TrackPoint mapping

    func testTrackPointCopiesLocationFields() {
        let loc = location(lat: 45.5231, lon: -122.6765, accuracy: 3.5,
                           speed: 12.34, altitude: 15.2, offset: 7)
        let pt  = TrackPoint(from: loc)

        XCTAssertEqual(pt.latitude,           45.5231)
        XCTAssertEqual(pt.longitude,          -122.6765)
        XCTAssertEqual(pt.altitude,           15.2)
        XCTAssertEqual(pt.speedMS,            12.34)
        XCTAssertEqual(pt.horizontalAccuracy, 3.5)
        XCTAssertEqual(pt.timestamp,          t0.addingTimeInterval(7))
    }

    func testDerivedSpeedsClampNegativeToZero() {
        let invalid = TrackPoint(from: location(speed: -1))
        XCTAssertEqual(invalid.speedKPH, 0)
        XCTAssertEqual(invalid.speedMPH, 0)

        let moving = TrackPoint(from: location(speed: 10))
        XCTAssertEqual(moving.speedKPH, 36,      accuracy: 0.001)
        XCTAssertEqual(moving.speedMPH, 22.3694, accuracy: 0.001)
    }

    // MARK: - Accumulation

    func testAccumulatesAcceptedLocationsInOrder() {
        let lm = recordingManager()
        let locs = [location(lat: 1, offset: 0),
                    location(lat: 2, offset: 1),
                    location(lat: 3, offset: 2)]

        lm.locationManager(dummyCLManager, didUpdateLocations: locs)

        let pts = lm.currentSession?.trackPoints ?? []
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts.map(\.latitude), [1, 2, 3])
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude, 3)
        XCTAssertEqual(lm.currentSession?.pointCount, 3)
    }

    func testAccumulatesAcrossMultipleCallbacks() {
        let lm = recordingManager()
        lm.locationManager(dummyCLManager, didUpdateLocations: [location(lat: 1)])
        lm.locationManager(dummyCLManager, didUpdateLocations: [location(lat: 2), location(lat: 3)])
        XCTAssertEqual(lm.currentSession?.trackPoints.map(\.latitude), [1, 2, 3])
    }

    func testRejectsFixesWithPoorOrInvalidAccuracy() {
        let lm = recordingManager()
        let locs = [location(lat: 1, accuracy: 30.01),   // just over the 30 m limit
                    location(lat: 2, accuracy: -1),      // invalid fix
                    location(lat: 3, accuracy: 30),      // boundary: accepted
                    location(lat: 4, accuracy: 0)]       // boundary: accepted

        lm.locationManager(dummyCLManager, didUpdateLocations: locs)

        XCTAssertEqual(lm.currentSession?.trackPoints.map(\.latitude), [3, 4])
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude, 4)
    }

    func testIgnoresLocationsWhenNotRecording() {
        let lm = LocationManager()
        lm.currentSession = DriveSession()
        lm.isRecording    = false

        lm.locationManager(dummyCLManager, didUpdateLocations: [location()])

        XCTAssertEqual(lm.currentSession?.trackPoints.count, 0)
        XCTAssertNil(lm.currentLocation)
    }

    func testIgnoresLocationsWithoutASession() {
        let lm = LocationManager()
        lm.isRecording = true
        lm.locationManager(dummyCLManager, didUpdateLocations: [location()])
        XCTAssertNil(lm.currentSession)
        XCTAssertNil(lm.currentLocation)
    }

    // MARK: - Stop / finalise

    func testStopRecordingFinalisesAndReturnsSession() {
        let lm = recordingManager()
        lm.locationManager(dummyCLManager, didUpdateLocations: [location(lat: 1), location(lat: 2)])

        let before   = Date()
        let finished = lm.stopRecording()

        XCTAssertNotNil(finished)
        XCTAssertEqual(finished?.trackPoints.count, 2)
        XCTAssertNotNil(finished?.endedAt)
        XCTAssertGreaterThanOrEqual(finished!.endedAt!, before)
        XCTAssertGreaterThanOrEqual(finished!.duration, 0)
        XCTAssertFalse(lm.isRecording)
        XCTAssertNil(lm.currentSession)
    }

    func testStopRecordingWithEmptyTrackReturnsEmptySession() {
        let lm = recordingManager()
        let finished = lm.stopRecording()
        XCTAssertEqual(finished?.pointCount, 0)
        XCTAssertNotNil(finished?.endedAt)
    }

    func testStopRecordingWithoutSessionReturnsNil() {
        let lm = LocationManager()
        XCTAssertNil(lm.stopRecording())
        XCTAssertFalse(lm.isRecording)
    }

    // MARK: - DriveSession model

    func testLatitudeRangeIsNilForEmptyTrackAndSpansPoints() {
        XCTAssertNil(DriveSession().latitudeRange)

        let single = DriveSession(trackPoints: [TrackPoint(from: location(lat: 4))])
        XCTAssertEqual(single.latitudeRange, 4...4)

        let multi = DriveSession(trackPoints: [TrackPoint(from: location(lat: 4)),
                                               TrackPoint(from: location(lat: -2)),
                                               TrackPoint(from: location(lat: 9))])
        XCTAssertEqual(multi.latitudeRange, -2...9)
    }

    func testDurationUsesEndedAtWhenSet() {
        let session = DriveSession(startedAt: t0, endedAt: t0.addingTimeInterval(90))
        XCTAssertEqual(session.duration, 90, accuracy: 0.0001)
    }

    func testDriveSessionRoundTripsThroughJSON() throws {
        var session = DriveSession(startedAt: t0,
                                   endedAt: t0.addingTimeInterval(10),
                                   trackPoints: [TrackPoint(from: location(lat: 1, offset: 1)),
                                                 TrackPoint(from: location(lat: 2, offset: 2))],
                                   vehicleId: "veh-1")
        session.uploaded = true

        let data    = try JSONEncoder().encode([session])
        let decoded = try JSONDecoder().decode([DriveSession].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, session.id)
        XCTAssertEqual(decoded[0].vehicleId, "veh-1")
        XCTAssertTrue(decoded[0].uploaded)
        XCTAssertEqual(decoded[0].trackPoints.map(\.latitude), [1, 2])
        XCTAssertEqual(decoded[0].startedAt.timeIntervalSince1970,
                       t0.timeIntervalSince1970, accuracy: 0.001)
    }
}
