import AppKit
import ExplorerKit
import XCTest
@testable import Explorer

/// Cut via Trash, internal cut and the clipboard-replaced warning, end to end through FileOps with a
/// private pasteboard, a private trash and preferences in their own suite. Nothing touches the user's
/// clipboard, Trash or settings.
final class CutViaTrashTests: XCTestCase {
    private var fixture: URL!
    private var pasteboard: NSPasteboard!
    private var suite: String!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-cut-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("dest"), withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
        suite = "explorer-tests-" + UUID().uuidString
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: fixture)
    }

    private func ops(cutViaTrash: Bool) throws -> FileOps {
        let prefs = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        prefs.cutViaTrash = cutViaTrash
        let trash = Trasher(privateTrashRoot: fixture.appendingPathComponent("trash", isDirectory: true), useSystemTrash: false)
        return FileOps(preferences: prefs, trasher: trash, pasteboard: pasteboard)
    }

    private func file(_ name: String) throws -> URL {
        let u = fixture.appendingPathComponent(name)
        try Data(name.utf8).write(to: u)
        return u
    }

    /// Runs `body` and waits until every operation FileOps started has finished.
    private func settle(_ ops: FileOps, _ body: () -> Void) {
        body()
        let deadline = Date().addingTimeInterval(5)
        while !ops.running.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(ops.running.isEmpty, "operation did not finish")
    }

    func testCutViaTrashThenPasteMovesTheItemOutOfTrash() throws {
        let ops = try ops(cutViaTrash: true)
        let a = try file("a.txt")
        settle(ops) { ops.cut([a], window: nil) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "cut via Trash moves the item at once")
        let inTrash = try XCTUnwrap(ops.clipboardURLs.first)
        XCTAssertTrue(inTrash.path.hasPrefix(fixture.appendingPathComponent("trash").path), "the clipboard points into Trash for other apps")

        let dest = fixture.appendingPathComponent("dest")
        settle(ops) { ops.paste(into: dest, window: nil) }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.txt")), "a.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inTrash.path), "paste is a move, not a copy")
        XCTAssertTrue(ops.clipboardURLs.isEmpty)
    }

    func testReplacedClipboardWarnsOnceAndLeavesTheItemInTrash() throws {
        let ops = try ops(cutViaTrash: true)
        var notices = 0
        ops.clipboardReplacedNotice = { _ in notices += 1 }
        let b = try file("b.txt")
        settle(ops) { ops.cut([b], window: nil) }
        let inTrash = try XCTUnwrap(ops.clipboardURLs.first)

        ops.checkClipboardReplaced(window: nil)
        XCTAssertEqual(notices, 0, "nothing changed yet")

        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        ops.checkClipboardReplaced(window: nil)
        ops.checkClipboardReplaced(window: nil)
        XCTAssertEqual(notices, 1, "warn once, not on every window activation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path))

        // Copying the trashed item by hand and pasting must copy, not consume a stale cut.
        let other = try file("other.txt")
        ops.copy([other])
        let dest = fixture.appendingPathComponent("dest")
        settle(ops) { ops.paste(into: dest, window: nil) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("other.txt").path))
    }

    func testInternalCutMovesOnPasteOnlyForTheSameItems() throws {
        let ops = try ops(cutViaTrash: false)
        let c = try file("c.txt")
        let d = try file("d.txt")
        ops.cut([c], window: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path), "internal cut leaves the item until paste")
        XCTAssertEqual(ops.internalCut, [c])

        let dest = fixture.appendingPathComponent("dest")
        settle(ops) { ops.paste(into: dest, window: nil) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("c.txt").path))

        // A later copy replaces the pending cut, so pasting copies.
        ops.cut([d], window: nil)
        ops.copy([d])
        XCTAssertTrue(ops.internalCut.isEmpty)
        settle(ops) { ops.paste(into: dest, window: nil) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
    }
}
