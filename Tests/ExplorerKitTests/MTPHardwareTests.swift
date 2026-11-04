import XCTest
import Combine
@testable import ExplorerKit

/// Opt in with EXPLORER_MTP_HARDWARE_TEST=1. Never mutates device content.
final class MTPHardwareTests: XCTestCase {
    func testConnectedDeviceStorageAndFolderBrowsing() throws {
        guard ProcessInfo.processInfo.environment["EXPLORER_MTP_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Requires an unlocked USB MTP device and optional libmtp.")
        }
        let service = MTPService()
        XCTAssertTrue(service.isAvailable)
        guard service.isAvailable else { return }
        let discovered = expectation(description: "Connected MTP device")
        var device: MTPDevice?
        let subscription = service.$devices.filter { !$0.isEmpty }.first().sink { devices in
            device = devices.first
            discovered.fulfill()
        }
        defer { subscription.cancel() }
        wait(for: [discovered], timeout: 20)
        let connected = try XCTUnwrap(device)
        XCTAssertNil(connected.errorMessage)
        XCTAssertFalse(connected.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let browsed = expectation(description: "Storage and nested folders are readable")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { browsed.fulfill() }
            do {
                let storages = try service.list(connected.address)
                XCTAssertFalse(storages.isEmpty)
                let storage = try XCTUnwrap(storages.first?.mtpAddress)
                let children = try service.list(storage)
                XCTAssertTrue(children.allSatisfy { $0.mtpAddress?.storageID == storage.storageID && !$0.url.isFileURL })
                if let folder = children.first(where: { $0.isDirectory })?.mtpAddress {
                    let nested = try service.list(folder)
                    XCTAssertTrue(nested.allSatisfy { $0.mtpAddress?.parent?.id == folder.id })
                    print("MTP hardware check: \(connected.name), \(storages.count) storage(s), \(children.count) root items, nested folder listing succeeded")
                } else {
                    print("MTP hardware check: \(connected.name), \(storages.count) storage(s), \(children.count) root items")
                }
            } catch {
                XCTFail("Native MTP browsing failed: \(error.localizedDescription)")
            }
        }
        wait(for: [browsed], timeout: 60)
    }
}
