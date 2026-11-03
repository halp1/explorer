import XCTest
@testable import ExplorerKit

final class MTPAddressTests: XCTestCase {
    private func root(_ session: String = "connection-1") -> MTPAddress {
        MTPAddress(deviceID: "serial / ? # 日本語", sessionID: session, deviceName: "Phone")
    }

    func testNavigationEncodingAndIdentity() throws {
        let device = root()
        var storage = device
        storage.storageID = 0x10001
        storage.storageName = "Internal storage"
        let folder = storage.appending(id: 24, name: "Photos / display-only")
        let file = folder.appending(id: 42, name: "image.jpg")
        for address in [device, storage, folder, file] {
            XCTAssertFalse(address.url.isFileURL)
            XCTAssertEqual(MTPAddress(url: address.url), address)
            XCTAssertEqual(address.url, address.url)
            let location = Location.mtp(address)
            let decoded = try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(location))
            XCTAssertEqual(decoded, location)
            XCTAssertNil(location.url)
            XCTAssertFalse(location.isFileSystem)
            XCTAssertEqual(location.parent, address.parent.map(Location.mtp))
        }
        XCTAssertNil(device.parent)
        XCTAssertEqual(storage.parent, device)
        XCTAssertEqual(folder.parent, storage)
        XCTAssertEqual(file.parent, folder)

        var renamed = file
        renamed.components[1].name = "renamed.jpg"
        XCTAssertEqual(file.id, renamed.id)
        XCTAssertNotEqual(file.id, folder.appending(id: 43, name: "image.jpg").id)
        var otherStorage = file
        otherStorage.storageID = 0x20001
        XCTAssertNotEqual(file.id, otherStorage.id)
        var otherSession = file
        otherSession.sessionID = "connection-2"
        XCTAssertNotEqual(file.id, otherSession.id)
        let item = FileItem(url: file.url, mtpAddress: file, name: "image.jpg", isDirectory: false)
        let renamedItem = FileItem(url: renamed.url, mtpAddress: renamed, name: "renamed.jpg", isDirectory: false)
        XCTAssertEqual(item.id, renamedItem.id)
        XCTAssertFalse(item.isLocalFile)
        let afc = Location.device(udid: "phone", path: "/Photos")
        XCTAssertEqual(try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(afc)), afc)
    }

    func testRejectsMalformedOrAmbiguousURLsAndLocalAdmission() throws {
        var malformed = root().appending(id: 7, name: "without storage")
        XCTAssertNil(MTPAddress(url: malformed.url))
        malformed.storageID = 1
        malformed.components = [MTPComponent(id: 0, name: "root alias")]
        XCTAssertNil(MTPAddress(url: malformed.url))
        malformed.components = [MTPComponent(id: UInt32.max, name: "root alias")]
        XCTAssertNil(MTPAddress(url: malformed.url))
        malformed.components = Array(repeating: MTPComponent(id: 1, name: "deep"), count: 257)
        XCTAssertNil(MTPAddress(url: malformed.url))
        for text in ["mtp://device/invalid", "mtp://other/invalid", "mtp://device/", root().url.absoluteString + "?x=1", root().url.absoluteString + "#fragment"] {
            XCTAssertNil(MTPAddress(url: try XCTUnwrap(URL(string: text))))
        }
        for url in [root().url, URL(string: "https://example.com/file")!,
                    URL(fileURLWithPath: "/.explorer-device/phone/DCIM"),
                    URL(fileURLWithPath: "/tmp/../.explorer-device/phone"),
                    URL(fileURLWithPath: "/.explorer-mtp/phone") ] {
            XCTAssertFalse(LocalFileBoundary.accepts(url))
            XCTAssertThrowsError(try LocalFileBoundary.require([url]))
            XCTAssertNil(FileItemLoader.load(url))
            XCTAssertThrowsError(try FileItemLoader.list(url, includeHidden: true))
        }
        let local = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertTrue(LocalFileBoundary.accepts(local))
        XCTAssertNoThrow(try LocalFileBoundary.require([local]))
        XCTAssertTrue(FileItem(url: local, name: "a.txt", isDirectory: false).isLocalFile)
        XCTAssertFalse(FileItem(url: local, archivePath: "a.txt", name: "a.txt", isDirectory: false).isLocalFile)
    }
}
