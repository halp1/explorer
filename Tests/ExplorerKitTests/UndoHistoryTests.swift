import XCTest
@testable import ExplorerKit

final class UndoHistoryTests: XCTestCase {
    func testFailedRestoreKeepsHistoryAndDoesNotPartiallyRestoreOrOverwrite() throws {
        let t = TempDir()
        let first = t.file("first.txt", "first")
        let second = t.file("second.txt", "second")
        let trash = Trasher(privateTrashRoot: t.dir("trash"))
        let firstTrash = try trash.privateTrash(first)
        let secondTrash = try trash.privateTrash(second)
        let history = UndoHistory()
        history.record("Delete", .trashed([
            MovePair(from: first, to: firstTrash), MovePair(from: second, to: secondTrash),
        ]))
        t.file("first.txt", "unrelated")

        XCTAssertThrowsError(try history.undo(trash: trash))
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
        XCTAssertEqual(t.read("first.txt"), "unrelated")
        XCTAssertFalse(t.exists("second.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTrash.path))

        try FileManager.default.removeItem(at: first)
        try history.undo(trash: trash)
        XCTAssertEqual(t.read("first.txt"), "first")
        XCTAssertEqual(t.read("second.txt"), "second")
        XCTAssertTrue(history.undoStack.isEmpty)
        XCTAssertEqual(history.redoStack.count, 1)
    }

    func testFailedRedoRetainsEntryAndCanRetryAfterConflictIsRemoved() throws {
        let t = TempDir()
        let original = t.url.appendingPathComponent("original.txt")
        let moved = t.file("moved.txt", "payload")
        let history = UndoHistory()
        history.record("Move", .moved([MovePair(from: original, to: moved)]))
        try history.undo()
        t.file("moved.txt", "unrelated")

        XCTAssertThrowsError(try history.redo())
        XCTAssertTrue(history.undoStack.isEmpty)
        XCTAssertEqual(history.redoStack.count, 1)
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertEqual(t.read("moved.txt"), "unrelated")

        try FileManager.default.removeItem(at: moved)
        try history.redo()
        XCTAssertFalse(t.exists("original.txt"))
        XCTAssertEqual(t.read("moved.txt"), "payload")
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
    }

    func testMoveFailureRollsBackStagedAndAlreadyRestoredItemsBeforeRetry() throws {
        let t = TempDir()
        let blockedParent = t.file("blocked", "not a directory")
        let blockedOriginal = blockedParent.appendingPathComponent("original.txt")
        let original = t.url.appendingPathComponent("original.txt")
        let movedBlocked = t.file("moved-blocked.txt", "blocked payload")
        let moved = t.file("moved.txt", "payload")
        let history = UndoHistory()
        history.record("Move", .moved([
            MovePair(from: blockedOriginal, to: movedBlocked), MovePair(from: original, to: moved),
        ]))

        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
        XCTAssertEqual(t.read("moved.txt"), "payload")
        XCTAssertEqual(t.read("moved-blocked.txt"), "blocked payload")
        XCTAssertFalse(t.exists("original.txt"))
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".explorer-undo-") })

        try FileManager.default.removeItem(at: blockedParent)
        try history.undo()
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertEqual(t.read("blocked/original.txt"), "blocked payload")
        try history.redo()
        XCTAssertEqual(t.read("moved.txt"), "payload")
        XCTAssertEqual(t.read("moved-blocked.txt"), "blocked payload")
    }

    func testMissingMoveSourceDoesNotStrandOtherItemsInStaging() throws {
        let t = TempDir()
        let existing = t.file("existing.txt", "payload")
        let history = UndoHistory()
        history.record("Move", .moved([
            MovePair(from: t.url.appendingPathComponent("missing-original.txt"), to: t.url.appendingPathComponent("missing.txt")),
            MovePair(from: t.url.appendingPathComponent("original.txt"), to: existing),
        ]))
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertEqual(t.read("existing.txt"), "payload")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: t.url.path), ["existing.txt"])
    }

    func testLateRestoreFailureReturnsEarlierItemsToTrashAndCanRetry() throws {
        let t = TempDir()
        let first = t.file("blocked/first.txt", "first")
        let second = t.file("second.txt", "second")
        let trash = Trasher(privateTrashRoot: t.dir("trash"))
        let firstTrash = try trash.privateTrash(first)
        let secondTrash = try trash.privateTrash(second)
        let blockedParent = t.url.appendingPathComponent("blocked")
        try FileManager.default.removeItem(at: blockedParent)
        t.file("blocked", "not a directory")
        let history = UndoHistory()
        history.record("Delete", .trashed([
            MovePair(from: first, to: firstTrash), MovePair(from: second, to: secondTrash),
        ]))

        XCTAssertThrowsError(try history.undo(trash: trash))
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
        XCTAssertFalse(t.exists("second.txt"))
        XCTAssertEqual(try String(contentsOf: firstTrash), "first")
        XCTAssertEqual(try String(contentsOf: secondTrash), "second")
        try FileManager.default.removeItem(at: blockedParent)
        try history.undo(trash: trash)
        XCTAssertEqual(t.read("blocked/first.txt"), "first")
        XCTAssertEqual(t.read("second.txt"), "second")
    }

    func testCompositeFailureReturnsRestoredItemsToTheirExactTrashPaths() throws {
        let t = TempDir()
        let original = t.file("original.txt", "payload")
        let trash = Trasher(privateTrashRoot: t.dir("trash"))
        let trashed = try trash.privateTrash(original)
        var fail = true
        let history = UndoHistory()
        history.record("Replace", .composite([
            .custom(name: "Fail once", undo: {
                if fail { throw OpError.cancelled }
                return .created([])
            }),
            .trashed([MovePair(from: original, to: trashed)]),
        ]))

        XCTAssertThrowsError(try history.undo(trash: trash))
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertFalse(t.exists("original.txt"))
        XCTAssertEqual(try String(contentsOf: trashed), "payload")
        fail = false
        try history.undo(trash: trash)
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertTrue(history.undoStack.isEmpty)
        XCTAssertEqual(history.redoStack.count, 1)
    }

    func testRollbackConflictKeepsRecoverableHistoryWithoutAddingRedoWork() throws {
        let t = TempDir()
        let original = t.url.appendingPathComponent("original.txt")
        let moved = t.file("moved.txt", "payload")
        var fail = true
        let history = UndoHistory()
        history.record("Move", .composite([
            .custom(name: "Concurrent conflict", undo: {
                if fail {
                    // Simulate another process occupying the destination during rollback.
                    t.file("moved.txt", "unrelated")
                    throw OpError.cancelled
                }
                return .created([])
            }),
            .moved([MovePair(from: original, to: moved)]),
        ]))

        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertEqual(t.read("moved.txt"), "unrelated")
        XCTAssertEqual(Set(try XCTUnwrap(history.undoStack.last).action.affectedURLs), Set([original, moved]))
        // A retry while the rollback is still blocked must preserve both files and the entry.
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertTrue(history.redoStack.isEmpty)
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertEqual(t.read("moved.txt"), "unrelated")
        fail = false
        try FileManager.default.removeItem(at: moved)
        try history.undo()
        XCTAssertEqual(t.read("original.txt"), "payload")
        XCTAssertFalse(t.exists("moved.txt"))
        try history.redo()
        XCTAssertFalse(t.exists("original.txt"))
        XCTAssertEqual(t.read("moved.txt"), "payload")
    }

    func testUndoRedoPreserveMoveCycles() throws {
        let t = TempDir()
        let first = t.file("first.txt", "second payload")
        let second = t.file("second.txt", "first payload")
        let history = UndoHistory()
        history.record("Swap", .moved([
            MovePair(from: first, to: second), MovePair(from: second, to: first),
        ]))
        try history.undo()
        XCTAssertEqual(t.read("first.txt"), "first payload")
        XCTAssertEqual(t.read("second.txt"), "second payload")
        try history.redo()
        XCTAssertEqual(t.read("first.txt"), "second payload")
        XCTAssertEqual(t.read("second.txt"), "first payload")
    }
}
