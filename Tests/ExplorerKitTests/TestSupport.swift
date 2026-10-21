import Foundation
import XCTest

final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ rel: String, _ content: String = "x", date: Date? = nil) -> URL {
        let u = url.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: u)
        if let date { try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
        return u
    }

    @discardableResult
    func dir(_ rel: String) -> URL {
        let u = url.appendingPathComponent(rel, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(rel).path) }
    func read(_ rel: String) -> String? { try? String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8) }
}
