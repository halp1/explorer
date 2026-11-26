import XCTest
@testable import ExplorerKit

final class PathCompletionTests: XCTestCase {
    func testGoToFolderCompletions() throws {
        let t = TempDir()
        for d in ["Photos", "photo 10", "photo 2", "Projects", ".private", "Écoles"] { t.dir(d) }
        t.file("photo.txt")
        try FileManager.default.createSymbolicLink(at: t.url.appendingPathComponent("photo-link"), withDestinationURL: t.url.appendingPathComponent("Photos"))
        let root = t.url.path

        // Prefix match is case-insensitive, folders only (symlinks to folders count), Finder-numeric order.
        XCTAssertEqual(PathCompletion.candidates(for: root + "/pho"),
                       ["photo 2", "photo 10", "photo-link", "Photos"].map { root + "/" + $0 + "/" })
        // A trailing slash lists the folder's own visible subfolders.
        XCTAssertEqual(PathCompletion.candidates(for: root + "/").count, 6)
        XCTAssertFalse(PathCompletion.candidates(for: root + "/").contains(root + "/.private/"))
        XCTAssertEqual(PathCompletion.candidates(for: root + "/é"), [root + "/Écoles/"])
        XCTAssertEqual(PathCompletion.candidates(for: root + "/", limit: 2).count, 2)
        XCTAssertEqual(PathCompletion.candidates(for: root + "/missing/x"), [])
        XCTAssertTrue(PathCompletion.candidates(for: "~/").allSatisfy { $0.hasPrefix(NSHomeDirectory() + "/") })
    }
}
