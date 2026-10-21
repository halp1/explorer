import XCTest
@testable import ExplorerKit

final class FileOperationTests: XCTestCase {
    func trasher(_ t: TempDir) -> Trasher {
        // Always use a private trash under the temp dir so tests never touch the user's Trash.
        Trasher(allowPrivateTrash: true, privateTrashRoot: t.dir(".ptrash"))
    }

    func run(_ op: FileOperation) -> FileOperation {
        let exp = expectation(description: "op")
        op.onFinish = { _ in exp.fulfill() }
        op.start()
        wait(for: [exp], timeout: 20)
        return op
    }

    func testCopyAndUndo() throws {
        let t = TempDir()
        let a = t.file("src/a.txt", "hello")
        t.dir("src/sub"); t.file("src/sub/b.txt", "b")
        let dest = t.dir("dest")
        let op = FileOperation(kind: .copy, sources: [a, t.url.appendingPathComponent("src/sub")], destination: dest)
        op.trasher = trasher(t)
        _ = run(op)
        XCTAssertEqual(op.state, .done)
        XCTAssertEqual(t.read("dest/a.txt"), "hello")
        XCTAssertEqual(t.read("dest/sub/b.txt"), "b")
        XCTAssertEqual(op.results.count, 2)
        _ = try op.undo!.perform(trash: trasher(t))
        XCTAssertFalse(t.exists("dest/a.txt"))
        XCTAssertFalse(t.exists("dest/sub"))
        XCTAssertTrue(t.exists("src/a.txt"))
    }

    func testMoveAndUndoRedo() throws {
        let t = TempDir()
        let a = t.file("a.txt", "A")
        let dest = t.dir("d")
        let op = FileOperation(kind: .move, sources: [a], destination: dest)
        op.trasher = trasher(t)
        _ = run(op)
        XCTAssertTrue(t.exists("d/a.txt")); XCTAssertFalse(t.exists("a.txt"))
        let h = UndoHistory()
        h.record("Move", op.undo)
        try h.undo(trash: trasher(t))
        XCTAssertTrue(t.exists("a.txt")); XCTAssertFalse(t.exists("d/a.txt"))
        try h.redo(trash: trasher(t))
        XCTAssertTrue(t.exists("d/a.txt")); XCTAssertFalse(t.exists("a.txt"))
    }

    func testCopyIntoSameFolderMakesUniqueName() {
        let t = TempDir()
        let a = t.file("a.txt")
        let op = FileOperation(kind: .copy, sources: [a], destination: t.url)
        _ = run(op)
        XCTAssertTrue(t.exists("a 2.txt"))
    }

    func testConflictSkipKeepBothReplace() {
        for (decision, check) in [(ConflictDecision.skip, "old"), (.replace, "new")] {
            let t = TempDir()
            let src = t.file("s/f.txt", "new")
            t.file("d/f.txt", "old")
            let op = FileOperation(kind: .copy, sources: [src], destination: t.url.appendingPathComponent("d"))
            op.trasher = trasher(t)
            op.resolver = { _ in ConflictAnswer(decision) }
            _ = run(op)
            XCTAssertEqual(t.read("d/f.txt"), check, "\(decision)")
        }
        let t = TempDir()
        let src = t.file("s/f.txt", "new")
        t.file("d/f.txt", "old")
        let op = FileOperation(kind: .copy, sources: [src], destination: t.url.appendingPathComponent("d"))
        op.resolver = { _ in ConflictAnswer(.keepBoth) }
        _ = run(op)
        XCTAssertEqual(t.read("d/f.txt"), "old")
        XCTAssertEqual(t.read("d/f 2.txt"), "new")
    }

    func testReplaceOlderOnlyReplacesWhenExistingIsOlder() {
        let t = TempDir()
        let now = Date()
        let src1 = t.file("s/newer.txt", "incoming", date: now)
        t.file("d/newer.txt", "existing", date: now.addingTimeInterval(-3600))
        let src2 = t.file("s/older.txt", "incoming", date: now.addingTimeInterval(-7200))
        t.file("d/older.txt", "existing", date: now)
        let op = FileOperation(kind: .copy, sources: [src1, src2], destination: t.url.appendingPathComponent("d"))
        op.trasher = trasher(t)
        op.resolver = { _ in ConflictAnswer(.replaceOlder) }
        _ = run(op)
        XCTAssertEqual(t.read("d/newer.txt"), "incoming")
        XCTAssertEqual(t.read("d/older.txt"), "existing")
    }

    func testMergeFolders() {
        let t = TempDir()
        t.file("s/F/a.txt", "a"); t.file("s/F/b.txt", "new-b")
        t.file("d/F/b.txt", "old-b"); t.file("d/F/c.txt", "c")
        var asked: [Bool] = []
        let op = FileOperation(kind: .copy, sources: [t.url.appendingPathComponent("s/F")], destination: t.url.appendingPathComponent("d"))
        op.trasher = trasher(t)
        op.resolver = { c in asked.append(c.isFolder); return ConflictAnswer(c.isFolder ? .merge : .skip) }
        _ = run(op)
        XCTAssertEqual(asked, [true, false])
        XCTAssertEqual(t.read("d/F/a.txt"), "a")
        XCTAssertEqual(t.read("d/F/b.txt"), "old-b")
        XCTAssertEqual(t.read("d/F/c.txt"), "c")
    }

    func testApplyToAllIsSticky() {
        let t = TempDir()
        let s1 = t.file("s/1.txt", "n"), s2 = t.file("s/2.txt", "n")
        t.file("d/1.txt", "o"); t.file("d/2.txt", "o")
        var count = 0
        let op = FileOperation(kind: .copy, sources: [s1, s2], destination: t.url.appendingPathComponent("d"))
        op.resolver = { _ in count += 1; return ConflictAnswer(.skip, applyToAll: true) }
        _ = run(op)
        XCTAssertEqual(count, 1)
    }

    func testCannotCopyIntoItself() {
        let t = TempDir()
        let d = t.dir("F")
        let op = FileOperation(kind: .copy, sources: [d], destination: d.appendingPathComponent("inner"))
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("inner"), withIntermediateDirectories: true)
        _ = run(op)
        XCTAssertFalse(op.errors.isEmpty)
    }

    func testDuplicateNaming() {
        let t = TempDir()
        let a = t.file("a.txt")
        let op = FileOperation(kind: .duplicate, sources: [a], destination: nil)
        _ = run(op)
        XCTAssertTrue(t.exists("a copy.txt"))
        let op2 = FileOperation(kind: .duplicate, sources: [a], destination: nil)
        _ = run(op2)
        XCTAssertTrue(t.exists("a copy 2.txt"))
    }

    func testTrashToPrivateTrashAndUndo() throws {
        let t = TempDir()
        let a = t.file("a.txt", "A")
        let tr = Trasher(allowPrivateTrash: true, privateTrashRoot: t.dir(".ptrash"))
        let moved = try tr.privateTrash(a)
        XCTAssertFalse(t.exists("a.txt"))
        XCTAssertTrue(tr.isInPrivateTrash(moved))
        _ = try UndoAction.trashed([MovePair(from: a, to: moved)]).perform(trash: tr)
        XCTAssertEqual(t.read("a.txt"), "A")
    }

    func testSymlinkAndAliasCreation() {
        let t = TempDir()
        let a = t.file("a.txt")
        let d = t.dir("links")
        _ = run(FileOperation(kind: .link, sources: [a], destination: d))
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: d.appendingPathComponent("a.txt").path), a.path)
        _ = run(FileOperation(kind: .alias, sources: [a], destination: d))
        let alias = d.appendingPathComponent("a.txt alias")
        XCTAssertEqual((try? alias.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile, true)
    }

    func testUndoConflictThrows() throws {
        let t = TempDir()
        let a = t.file("a.txt"), b = t.file("b.txt")
        // pretend a was moved to b; a still exists → conflict
        XCTAssertThrowsError(try UndoAction.moved([MovePair(from: a, to: b)]).perform())
    }
}
