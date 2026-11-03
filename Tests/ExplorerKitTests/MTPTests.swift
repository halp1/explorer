import XCTest
import Foundation
import Darwin
@testable import ExplorerKit

private final class TestMTPTransport: MTPTransport {
    var isAvailable = true
    var connections = [MTPConnection(id: "phone", session: "session-1", name: "Phone", storages: [MTPStorage(id: 1, name: "Internal", writable: true)])]
    var objects: [UInt32: [MTPObject]] = [:]
    var bytes: [UInt32: Data] = [:]
    var removed: [UInt32] = []
    var uploads: [String] = []
    var nextID: UInt32 = 100
    var failDownload: UInt32?
    var failUpload = false
    var listError = false
    var listingStarted: DispatchSemaphore?
    var listingRelease: DispatchSemaphore?

    func discover() throws -> [MTPConnection] { connections }
    func list(_ device: String, storage: UInt32, parent: UInt32) throws -> [MTPObject] {
        listingStarted?.signal()
        listingRelease?.wait()
        if listError { throw OpError.message("fixture error") }
        return objects[parent] ?? []
    }
    func download(_ device: String, id: UInt32, fd: Int32, progress: @escaping (UInt64, UInt64) -> Bool) throws {
        let data = bytes[id] ?? Data()
        let midpoint = data.count / 2
        let first = data.prefix(midpoint)
        _ = first.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard progress(UInt64(midpoint), UInt64(data.count)) else { throw OpError.cancelled }
        if failDownload == id { throw OpError.message("fixture partial read") }
        _ = data.dropFirst(midpoint).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard progress(UInt64(data.count), UInt64(data.count)) else { throw OpError.cancelled }
    }
    func upload(_ device: String, fd: Int32, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                created: (UInt32) -> Void, progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        let id = nextID
        nextID += 1
        uploads.append(name)
        objects[parent == 0 ? UInt32.max : parent, default: []].append(MTPObject(id: id, parent: parent, storage: storage, name: name, size: size, folder: false))
        created(id)
        guard progress(size / 2, size) else { throw OpError.cancelled }
        if failUpload { throw OpError.message("fixture partial upload") }
        return id
    }
    func mkdir(_ device: String, name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let id = nextID
        nextID += 1
        objects[parent == 0 ? UInt32.max : parent, default: []].append(MTPObject(id: id, parent: parent, storage: storage, name: name, folder: true))
        return id
    }
    func rename(_ device: String, id: UInt32, name: String) throws {
        for key in objects.keys {
            if let index = objects[key]?.firstIndex(where: { $0.id == id }) { objects[key]![index].name = name }
        }
    }
    func remove(_ device: String, id: UInt32) throws {
        removed.append(id)
        for key in Array(objects.keys) { objects[key]?.removeAll { $0.id == id } }
        objects.removeValue(forKey: id)
    }
}

final class MTPTests: XCTestCase {
    private var root: MTPAddress {
        MTPAddress(deviceID: "phone", sessionID: "session-1", deviceName: "Phone", storageID: 1, storageName: "Internal")
    }
    private func file(_ id: UInt32, _ name: String, parent: UInt32 = UInt32.max, size: UInt64 = 4, folder: Bool = false) -> MTPObject {
        MTPObject(id: id, parent: parent, storage: 1, name: name, size: size, folder: folder)
    }
    private func assertCancelled(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case OpError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)", file: file, line: line) }
        }
    }

    func testListingIdentityAndSessionInvalidation() throws {
        let transport = TestMTPTransport()
        transport.objects[UInt32.max] = [file(8, "same.txt"), file(9, "other.txt")]
        let service = MTPService(transport: transport)
        let deviceRoot = root.parent!
        let storages = try service.list(deviceRoot)
        XCTAssertEqual(storages.map(\.mtpAddress), [root])
        let first = try service.list(root)
        XCTAssertEqual(first.map { $0.mtpAddress!.objectID! }, [8, 9])
        XCTAssertNotEqual(first[0].id, first[1].id)
        XCTAssertEqual(try service.list(root), first)
        XCTAssertTrue(service.canWrite(root))
        transport.connections = []
        service.refreshDiscovery()
        XCTAssertFalse(service.canWrite(root))
        XCTAssertThrowsError(try service.list(root))
        transport.connections = [MTPConnection(id: "phone", session: "session-2", name: "Phone", storages: [MTPStorage(id: 1, name: "Internal", writable: true)])]
        service.refreshDiscovery()
        XCTAssertThrowsError(try service.list(first[0].mtpAddress!))
        var current = root
        current.sessionID = "session-2"
        XCTAssertNotEqual(try service.list(current)[0].id, first[0].id)
        XCTAssertTrue(service.canWrite(current))
        transport.listError = true
        XCTAssertThrowsError(try service.list(current))
        transport.listError = false
        transport.objects = [:]
        XCTAssertEqual(try service.list(current), [])
    }

    func testCanWriteDoesNotWaitForBusyTransport() throws {
        let transport = TestMTPTransport()
        let service = MTPService(transport: transport)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        transport.listingStarted = started
        transport.listingRelease = release
        let done = expectation(description: "worker list finished")
        let address = root
        DispatchQueue.global().async {
            _ = try? service.list(address)
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(service.canWrite(root))
        release.signal()
        wait(for: [done], timeout: 2)
    }

    func testMalformedNamesCyclesAndReadOnlyNeverMutate() throws {
        let transport = TestMTPTransport()
        let service = MTPService(transport: transport)
        for name in ["", ".", "..", "a/b", "a\0b"] {
            transport.objects[UInt32.max] = [file(1, name)]
            XCTAssertThrowsError(try service.list(root))
            XCTAssertThrowsError(try service.rename(root.appending(id: 1, name: name), to: "safe"))
        }
        transport.objects[UInt32.max] = [file(1, "folder", folder: true)]
        transport.objects[1] = [file(1, "cycle", parent: 1, folder: true)]
        let temp = TempDir()
        XCTAssertThrowsError(try service.download([root.appending(id: 1, name: "folder")], to: temp.url) { _, _ in true })
        XCTAssertThrowsError(try service.remove([root.appending(id: 1, name: "folder")]) { _, _ in true })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), [])
        XCTAssertTrue(transport.removed.isEmpty)
        XCTAssertThrowsError(try service.remove([root]) { _, _ in true })
        XCTAssertThrowsError(try service.rename(root, to: "new"))
        transport.connections[0].storages[0].writable = false
        service.refreshDiscovery()
        XCTAssertFalse(service.canWrite(root))
        XCTAssertThrowsError(try service.makeDirectory("New", in: root))
        XCTAssertThrowsError(try service.upload([temp.file("local")], to: root) { _, _ in true })
        XCTAssertTrue(transport.uploads.isEmpty)
    }

    func testDownloadsKeepBothAndPublishOnlyCompleteSelection() throws {
        let transport = TestMTPTransport()
        transport.objects[UInt32.max] = [file(1, "report.txt"), file(2, "REPORT.txt")]
        transport.bytes = [1: Data("good".utf8), 2: Data("next".utf8)]
        let service = MTPService(transport: transport)
        let temp = TempDir()
        temp.file("Report.txt", "original")
        transport.failDownload = 2
        let selected = try service.list(root).map { $0.mtpAddress! }
        XCTAssertThrowsError(try service.download(selected, to: temp.url) { _, _ in true })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), ["Report.txt"])
        XCTAssertEqual(temp.read("Report.txt"), "original")
        transport.failDownload = nil
        let results = try service.download(selected, to: temp.url) { _, _ in true }
        XCTAssertEqual(results.map(\.lastPathComponent), ["report (2).txt", "REPORT (3).txt"])
        XCTAssertEqual(try String(contentsOf: results[0]), "good")
        XCTAssertEqual(try String(contentsOf: results[1]), "next")
        XCTAssertTrue(transport.removed.isEmpty)
    }

    func testDownloadCancellationSizeMismatchAndSymlinkCollision() throws {
        let transport = TestMTPTransport()
        transport.objects[UInt32.max] = [file(1, "outside")]
        transport.bytes[1] = Data("good".utf8)
        let service = MTPService(transport: transport)
        let temp = TempDir()
        let other = TempDir()
        let sentinel = other.file("target", "original")
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("outside"), withDestinationURL: sentinel)
        let address = root.appending(id: 1, name: "outside")
        assertCancelled {
            _ = try service.download([address], to: temp.url) { fraction, _ in fraction < 0.4 }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path), ["outside"])
        transport.bytes[1] = Data("bad".utf8)
        XCTAssertThrowsError(try service.download([address], to: temp.url) { _, _ in true })
        XCTAssertEqual(try String(contentsOf: sentinel), "original")
        transport.bytes[1] = Data("good".utf8)
        let result = try service.download([address], to: temp.url) { _, _ in true }
        XCTAssertEqual(result.first?.lastPathComponent, "outside (2)")
        XCTAssertEqual(try String(contentsOf: sentinel), "original")
    }

    func testRecursiveUploadRollbackAndSymlinkPreflight() throws {
        let transport = TestMTPTransport()
        transport.objects[UInt32.max] = [file(5, "SOURCE", folder: true)]
        let service = MTPService(transport: transport)
        let temp = TempDir()
        let source = temp.dir("source")
        let local = temp.file("source/file.txt", "source bytes")
        transport.failUpload = true
        XCTAssertThrowsError(try service.upload([source], to: root) { _, _ in true })
        XCTAssertEqual(transport.removed, [101, 100])
        XCTAssertEqual(try String(contentsOf: local), "source bytes")
        XCTAssertEqual(transport.objects[UInt32.max]?.map(\.id), [5])
        transport.failUpload = false
        try service.upload([source], to: root) { _, _ in true }
        XCTAssertEqual(transport.objects[UInt32.max]?.map(\.name), ["SOURCE", "source (2)"])
        XCTAssertEqual(try String(contentsOf: local), "source bytes")
        let before = transport.uploads.count
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: local)
        XCTAssertThrowsError(try service.upload([source], to: root) { _, _ in true })
        XCTAssertEqual(transport.uploads.count, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testNativeTransferCancellationRollsBackKnownCreatedIDsOnly() throws {
        let transport = TestMTPTransport()
        transport.objects[UInt32.max] = [file(7, "existing")]
        let service = MTPService(transport: transport)
        let temp = TempDir()
        let source = temp.file("new", "abcdef")
        assertCancelled { try service.upload([source], to: root) { fraction, _ in fraction < 0.25 } }
        XCTAssertEqual(transport.removed, [100])
        XCTAssertEqual(transport.objects[UInt32.max]?.map(\.id), [7])
        XCTAssertEqual(temp.read("new"), "abcdef")
        transport.removed = []
        assertCancelled { try service.remove([root.appending(id: 7, name: "existing")]) { _, _ in false } }
        XCTAssertTrue(transport.removed.isEmpty)
    }
}
