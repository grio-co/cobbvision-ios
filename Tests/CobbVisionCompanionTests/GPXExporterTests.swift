import XCTest
@testable import CobbVisionCompanion

/// Covers GPXExporter: a fixed DriveSession must serialise to the documented
/// GPX 1.1 layout (Garmin TrackPointExtension v2 speed), including the empty
/// and single-point edge cases.
final class GPXExporterTests: XCTestCase {

    // 2023-11-14T22:13:20Z
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(lat: Double, lon: Double, alt: Double, speed: Double,
                       offset: TimeInterval) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, altitude: alt, speedMS: speed,
                   horizontalAccuracy: 5, timestamp: start.addingTimeInterval(offset))
    }

    private var fixedSession: DriveSession {
        DriveSession(startedAt: start,
                     endedAt: start.addingTimeInterval(120),
                     trackPoints: [
                        point(lat: 45.5231, lon: -122.6765, alt: 15.2,   speed: 12.34, offset: 1.5),
                        point(lat: 45.5240, lon: -122.6770, alt: 16.256, speed: 13,    offset: 2.5),
                     ])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func assertWellFormedXML(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), "GPX is not well-formed XML: \(String(describing: parser.parserError))",
                      file: file, line: line)
    }

    // MARK: - Document structure

    func testHeaderMetadataAndNamespaces() {
        let gpx = GPXExporter.gpxString(for: fixedSession)

        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(gpx.contains("creator=\"CobbVision Companion/1.0\""))
        XCTAssertTrue(gpx.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        XCTAssertTrue(gpx.contains("xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v2\""))
        XCTAssertTrue(gpx.contains("<time>2023-11-14T22:13:20.000Z</time>"))
        XCTAssertEqual(occurrences(of: "<name>CobbVision ", in: gpx), 2)  // metadata + trk
        XCTAssertEqual(occurrences(of: "<trk>", in: gpx), 1)
        XCTAssertEqual(occurrences(of: "<trkseg>", in: gpx), 1)
        XCTAssertTrue(gpx.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</gpx>"))
        assertWellFormedXML(gpx)
    }

    // MARK: - Track points

    func testTrackPointsAreSerialisedWithDocumentedFormatting() {
        let gpx = GPXExporter.gpxString(for: fixedSession)

        XCTAssertEqual(occurrences(of: "<trkpt ", in: gpx), 2)

        XCTAssertTrue(gpx.contains("<trkpt lat=\"45.5231\" lon=\"-122.6765\">"))
        XCTAssertTrue(gpx.contains("<ele>15.20</ele>"))
        XCTAssertTrue(gpx.contains("<time>2023-11-14T22:13:21.500Z</time>"))
        XCTAssertTrue(gpx.contains("<gpxtpx:speed>12.3400</gpxtpx:speed>"))

        XCTAssertTrue(gpx.contains("<trkpt lat=\"45.524\" lon=\"-122.677\">"))
        XCTAssertTrue(gpx.contains("<ele>16.26</ele>"))          // 2 decimals, rounded
        XCTAssertTrue(gpx.contains("<time>2023-11-14T22:13:22.500Z</time>"))
        XCTAssertTrue(gpx.contains("<gpxtpx:speed>13.0000</gpxtpx:speed>"))

        XCTAssertEqual(occurrences(of: "<gpxtpx:TrackPointExtension>", in: gpx), 2)
    }

    func testTrackPointOrderIsPreserved() {
        let gpx = GPXExporter.gpxString(for: fixedSession)
        let first  = gpx.range(of: "lat=\"45.5231\"")!.lowerBound
        let second = gpx.range(of: "lat=\"45.524\"")!.lowerBound
        XCTAssertLessThan(first, second)
    }

    func testNegativeSpeedIsClampedToZero() {
        let session = DriveSession(startedAt: start, trackPoints: [
            point(lat: 1, lon: 2, alt: 3, speed: -1, offset: 0),
        ])
        let gpx = GPXExporter.gpxString(for: session)
        XCTAssertTrue(gpx.contains("<gpxtpx:speed>0.0000</gpxtpx:speed>"))
    }

    // MARK: - Edge cases

    func testEmptyTrackProducesValidDocumentWithNoPoints() {
        let gpx = GPXExporter.gpxString(for: DriveSession(startedAt: start))

        XCTAssertEqual(occurrences(of: "<trkpt", in: gpx), 0)
        XCTAssertTrue(gpx.contains("<trkseg>"))
        XCTAssertTrue(gpx.contains("</trkseg>"))
        XCTAssertTrue(gpx.contains("<time>2023-11-14T22:13:20.000Z</time>"))
        assertWellFormedXML(gpx)
    }

    func testSinglePointTrack() {
        let session = DriveSession(startedAt: start, trackPoints: [
            point(lat: 51.5, lon: -0.12, alt: 35, speed: 0, offset: 0.25),
        ])
        let gpx = GPXExporter.gpxString(for: session)

        XCTAssertEqual(occurrences(of: "<trkpt ", in: gpx), 1)
        XCTAssertTrue(gpx.contains("<trkpt lat=\"51.5\" lon=\"-0.12\">"))
        XCTAssertTrue(gpx.contains("<ele>35.00</ele>"))
        XCTAssertTrue(gpx.contains("<time>2023-11-14T22:13:20.250Z</time>"))
        XCTAssertTrue(gpx.contains("<gpxtpx:speed>0.0000</gpxtpx:speed>"))
        assertWellFormedXML(gpx)
    }

    func testOutputIsDeterministicForTheSameSession() {
        let session = fixedSession
        XCTAssertEqual(GPXExporter.gpxString(for: session), GPXExporter.gpxString(for: session))
    }

    // MARK: - File export

    func testExportWritesGPXFileNamedAfterSessionStart() throws {
        let session = fixedSession
        let url = try GPXExporter.export(session: session)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "cobbvision_1700000000.gpx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, GPXExporter.gpxString(for: session))
    }
}
