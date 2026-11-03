import XCTest
@testable import ExplorerKit

final class LocalOperationBoundaryTests: XCTestCase {
    func testMixedRemoteSourcesFailBeforeAnyLocalMutation() {
        let kinds: [FileOperationKind] = [.copy, .move, .duplicate, .trash, .delete, .link, .alias]
        let address = MTPAddress(deviceID: "device", sessionID: "session", deviceName: "Phone", storageID: 1)
            .appending(id: 42, name: "remote.txt")
        let remoteURLs = [address.url, URL(fileURLWithPath: "/.explorer-device/device/Documents/file.txt")]
        for kind in kinds {
            for remote in remoteURLs {
                let temp = TempDir()
                let source = temp.file("source.txt", "original")
                let destination = temp.dir("destination")
                let operation = FileOperation(kind: kind, sources: [source, remote], destination: destination)
                operation.trasher = Trasher(allowPrivateTrash: true, privateTrashRoot: temp.dir("private-trash"))
                operation.resolver = { _ in
                    XCTFail("Remote references must fail before conflict resolution")
                    return ConflictAnswer(.cancel)
                }
                finish(operation)
                guard case .failed = operation.state else {
                    XCTFail("Expected refusal for \(kind) with \(remote)")
                    continue
                }
                XCTAssertEqual(temp.read("source.txt"), "original")
                XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: destination.path), [])
                XCTAssertTrue(operation.results.isEmpty)
                XCTAssertNil(operation.undo)
            }
        }
    }

    func testNonfileDestinationCannotBeReinterpretedAsLocalPath() {
        for kind in [FileOperationKind.copy, .move, .link, .alias] {
            let temp = TempDir()
            let source = temp.file("source.txt", "original")
            let destination = temp.dir("destination")
            // The URL's path is a real writable local directory, but its scheme is not file.
            var components = URLComponents()
            components.scheme = "mtp"
            components.host = "invalid"
            components.path = destination.path
            let operation = FileOperation(kind: kind, sources: [source], destination: components.url!)
            finish(operation)
            guard case .failed = operation.state else {
                XCTFail("Expected refusal for nonfile destination")
                continue
            }
            XCTAssertEqual(temp.read("source.txt"), "original")
            XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: destination.path), [])
            XCTAssertTrue(operation.results.isEmpty)
            XCTAssertNil(operation.undo)
        }
    }

    private func finish(_ operation: FileOperation) {
        let finished = expectation(description: "Boundary refusal")
        operation.onFinish = { _ in finished.fulfill() }
        operation.start()
        wait(for: [finished], timeout: 5)
    }
}
