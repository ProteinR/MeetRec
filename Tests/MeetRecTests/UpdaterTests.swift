import XCTest
@testable import MeetRec

final class UpdaterTests: XCTestCase {
    func testVersionsComparePartByPart() {
        XCTAssertTrue(Updater.isNewer("0.11.0", than: "0.10.1"))
        XCTAssertTrue(Updater.isNewer("0.10.10", than: "0.10.9"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.99"))
        XCTAssertTrue(Updater.isNewer("v0.10.2", than: "0.10.1"))
        XCTAssertFalse(Updater.isNewer("0.10.1", than: "0.10.1"))
        XCTAssertFalse(Updater.isNewer("0.10", than: "0.10.0"))
        XCTAssertFalse(Updater.isNewer("0.9.9", than: "0.10.0"))
    }

    func testReleasePicksTheVersionedZip() throws {
        let json = """
        {"tag_name": "v0.11.0", "html_url": "https://github.com/o/r/releases/tag/v0.11.0", "draft": false,
         "prerelease": false, "assets": [
          {"name": "MeetRec-0.11.0.dmg", "browser_download_url": "https://example.com/a.dmg"},
          {"name": "Other.zip", "browser_download_url": "https://example.com/other.zip"},
          {"name": "MeetRec-0.11.0.zip", "browser_download_url": "https://example.com/a.zip"}]}
        """
        let release = try XCTUnwrap(Updater.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.11.0")
        XCTAssertEqual(release.archive.absoluteString, "https://example.com/a.zip")
    }

    func testReleaseWithoutZipOrPrereleaseIsIgnored() {
        let noZip = #"{"tag_name": "v1.0.0", "html_url": "https://x", "assets": [{"name": "a.dmg", "browser_download_url": "https://x/a.dmg"}]}"#
        XCTAssertNil(Updater.parseRelease(Data(noZip.utf8)))
        let pre = #"{"tag_name": "v1.0.0", "html_url": "https://x", "prerelease": true, "assets": [{"name": "MeetRec-1.0.0.zip", "browser_download_url": "https://x/a.zip"}]}"#
        XCTAssertNil(Updater.parseRelease(Data(pre.utf8)))
    }

    func testLocationsThatCannotBeReplaced() {
        let writable: (String) -> Bool = { _ in true }
        XCTAssertFalse(Updater.locationBlocks(URL(fileURLWithPath: "/Applications/MeetRec.app"), writable: writable))
        XCTAssertTrue(Updater.locationBlocks(URL(fileURLWithPath: "/Volumes/MeetRec 0.11.0/MeetRec.app"), writable: writable))
        XCTAssertTrue(Updater.locationBlocks(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/MeetRec.app"), writable: writable))
        XCTAssertTrue(Updater.locationBlocks(URL(fileURLWithPath: "/Applications/MeetRec.app"), writable: { _ in false }))
    }
}
