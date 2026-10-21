import XCTest
@testable import ExplorerKit

final class SortingTests: XCTestCase {
    func item(_ name: String, dir: Bool = false, size: Int64? = nil, mod: Date? = nil, rating: Int = 0, label: Int = 0) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/" + name), name: name, isDirectory: dir, size: size, modified: mod, labelNumber: label, rating: rating)
    }

    func testFoldersFirstAndNaturalOrder() {
        let items = [item("b10.txt"), item("b2.txt"), item("Zdir", dir: true), item("adir", dir: true)]
        let s = Sorter.sort(items, by: .name, order: .ascending, folders: .first).map(\.name)
        XCTAssertEqual(s, ["adir", "Zdir", "b2.txt", "b10.txt"])
        let last = Sorter.sort(items, by: .name, order: .descending, folders: .last).map(\.name)
        XCTAssertEqual(last, ["b10.txt", "b2.txt", "Zdir", "adir"])
    }

    func testSizeAndRatingSort() {
        let items = [item("a", size: 10, rating: 1), item("b", size: 5, rating: 5), item("c", size: 50)]
        XCTAssertEqual(Sorter.sort(items, by: .size, order: .ascending, folders: .mixed).map(\.name), ["b", "a", "c"])
        XCTAssertEqual(Sorter.sort(items, by: .rating, order: .ascending, folders: .mixed).map(\.name), ["b", "a", "c"])
    }

    func testSizeGroups() {
        let items = [item("z", size: 0), item("t", size: 5_000), item("s", size: 500_000), item("m", size: 5_000_000), item("d", dir: true)]
        let g = Sorter.group(items, by: .size)
        XCTAssertEqual(g.map(\.title), ["Folders", "Zero bytes", "Tiny Files", "Small Files", "Medium Files"])
    }

    func testDateGroups() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        let items = [
            item("today", mod: now.addingTimeInterval(-3600)),
            item("yest", mod: now.addingTimeInterval(-86400)),
            item("week", mod: now.addingTimeInterval(-3 * 86400)),
            item("month", mod: now.addingTimeInterval(-20 * 86400)),
            item("old", mod: cal.date(from: DateComponents(year: 2020, month: 1, day: 1))),
            item("none"),
        ]
        let g = Sorter.group(items, by: .dateModified, now: now, calendar: cal)
        XCTAssertEqual(g.map(\.title).prefix(4), ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
        XCTAssertEqual(g.last?.title, "Unknown Date")
        XCTAssertTrue(g.contains { $0.title == "2020" })
    }
}

final class NamingTests: XCTestCase {
    func testUniqueURL() {
        let t = TempDir()
        t.file("a.txt"); t.file("a 2.txt")
        XCTAssertEqual(FileNaming.uniqueURL(in: t.url, name: "a.txt").lastPathComponent, "a 3.txt")
        XCTAssertEqual(FileNaming.uniqueURL(in: t.url, name: "b.txt").lastPathComponent, "b.txt")
        t.dir("untitled folder")
        XCTAssertEqual(FileNaming.uniqueURL(in: t.url, name: "untitled folder", isDirectory: true).lastPathComponent, "untitled folder 2")
    }

    func testValidate() {
        XCTAssertNotNil(FileNaming.validate("  "))
        XCTAssertNotNil(FileNaming.validate("a/b"))
        XCTAssertNil(FileNaming.validate("ok.txt"))
    }
}

final class ViewOptionsTests: XCTestCase {
    func testInheritance() {
        let t = TempDir()
        let s = ViewOptionsStore(file: t.url.appendingPathComponent("vo.json"))
        var o = ViewOptions(); o.view = .gallery
        s.remember(o, for: "/Users/x/Pictures")
        XCTAssertEqual(s.options(for: "/Users/x/Pictures/", inherit: false)?.view, .gallery)
        XCTAssertNil(s.options(for: "/Users/x/Pictures/2024", inherit: false))
        XCTAssertEqual(s.options(for: "/Users/x/Pictures/2024/a", inherit: true)?.view, .gallery)
        XCTAssertEqual(s.rememberingFolder(for: "/Users/x/Pictures/2024", inherit: true), "/Users/x/Pictures")
        s.forget("/Users/x/Pictures")
        XCTAssertNil(s.options(for: "/Users/x/Pictures", inherit: true))
    }

    func testDecodesPartialJSON() throws {
        let o = try JSONDecoder().decode(ViewOptions.self, from: Data(#"{"view":"Table"}"#.utf8))
        XCTAssertEqual(o.view, .table)
        XCTAssertEqual(o.sortKey, .name)
    }
}

final class RenameTests: XCTestCase {
    func inputs(_ names: [String]) -> [RenameInput] {
        names.map { RenameInput(url: URL(fileURLWithPath: "/nonexistent-dir/\($0)")) }
    }

    func testReplaceTextNameOnly() {
        let r = BatchRenamer.preview(inputs(["IMG_001.jpg", "img_002.JPG"]),
                                     steps: [.replaceText(find: "img_", replace: "Photo ", caseSensitive: false, target: .name)])
        XCTAssertEqual(r.map(\.newName), ["Photo 001.jpg", "Photo 002.JPG"])
    }

    func testRegexAndCaseAndExtension() {
        let r = BatchRenamer.preview(inputs(["a-1.TXT"]), steps: [
            .replaceRegex(pattern: #"(\w)-(\d)"#, template: "$2_$1", caseSensitive: true, target: .name),
            .changeCase(.lower, target: .fileExtension),
        ])
        XCTAssertEqual(r[0].newName, "1_a.txt")
    }

    func testCaseStyles() {
        let i = inputs(["hello WORLD.txt"])
        XCTAssertEqual(BatchRenamer.preview(i, steps: [.changeCase(.title, target: .name)])[0].newName, "Hello World.txt")
        XCTAssertEqual(BatchRenamer.preview(i, steps: [.changeCase(.sentence, target: .name)])[0].newName, "Hello world.txt")
        XCTAssertEqual(BatchRenamer.preview(i, steps: [.changeCase(.upper, target: .both)])[0].newName, "HELLO WORLD.TXT")
    }

    func testNumberSequence() {
        let r = BatchRenamer.preview(inputs(["c.txt", "a.txt", "b.txt"]), steps: [
            .addNumber(start: 1, step: 1, padding: 3, order: .name, descending: false, position: .end, offset: 0, fromEnd: false, delimiter: "_", target: .name),
        ])
        XCTAssertEqual(r.map(\.newName), ["c_003.txt", "a_001.txt", "b_002.txt"])
    }

    func testAddTextCustomPosition() {
        let r = BatchRenamer.preview(inputs(["abcdef.txt"]), steps: [
            .addText("-", position: .custom, offset: 2, fromEnd: true, target: .name),
        ])
        XCTAssertEqual(r[0].newName, "abcd-ef.txt")
    }

    func testAddDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: 2025, month: 3, day: 9))!
        let i = [RenameInput(url: URL(fileURLWithPath: "/x/a.jpg"), modified: d)]
        let r = BatchRenamer.preview(i, steps: [.addDate(source: .modified, format: "yyyy-MM-dd", position: .beginning, offset: 0, fromEnd: false, delimiter: " ", target: .name)], calendar: cal)
        XCTAssertEqual(r[0].newName, "2025-03-09 a.jpg")
    }

    func testCollisionAndEmptyDetected() {
        let r = BatchRenamer.preview(inputs(["a1.txt", "a2.txt"]), steps: [.replaceRegex(pattern: #"\d"#, template: "", caseSensitive: true, target: .name)])
        XCTAssertNotNil(r[0].error); XCTAssertNotNil(r[1].error)
        let e = BatchRenamer.preview(inputs(["abc.txt"]), steps: [.replaceText(find: "abc.txt", replace: "", caseSensitive: true, target: .both)])
        XCTAssertNotNil(e[0].error)
    }

    func testCommitSwapAndUndo() throws {
        let t = TempDir()
        let a = t.file("a.txt", "A"), b = t.file("b.txt", "B")
        let results = [RenameResult(url: a, newName: "b.txt"), RenameResult(url: b, newName: "a.txt")]
        let undo = try BatchRenamer.commit(results)
        XCTAssertEqual(t.read("b.txt"), "A"); XCTAssertEqual(t.read("a.txt"), "B")
        _ = try undo.perform()
        XCTAssertEqual(t.read("a.txt"), "A"); XCTAssertEqual(t.read("b.txt"), "B")
    }
}

final class GitTests: XCTestCase {
    func testPorcelainParsingAndRollup() {
        let out = " M src/a.swift\0?? new.txt\0R  dir/new.swift\0dir/old.swift\0A  added.c\0UU conflict.txt\0!! build/\0 D deep/x/y.txt\0"
        let s = Git.parsePorcelain(out)
        XCTAssertEqual(s["src/a.swift"], .modified)
        XCTAssertEqual(s["src"], .modified)
        XCTAssertEqual(s["new.txt"], .untracked)
        XCTAssertEqual(s["dir/new.swift"], .renamed)
        XCTAssertNil(s["dir/old.swift"])
        XCTAssertEqual(s["added.c"], .added)
        XCTAssertEqual(s["conflict.txt"], .conflicted)
        XCTAssertEqual(s["build"], .ignored)
        XCTAssertEqual(s["deep"], .deleted)
        XCTAssertEqual(s["deep/x"], .deleted)
    }

    func testRealRepo() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), Git.isAvailable else { throw XCTSkip("git unavailable") }
        let t = TempDir()
        let g = Git(root: t.url)
        try g.git(["init", "-q"])
        try g.git(["config", "user.email", "t@example.com"]); try g.git(["config", "user.name", "T"])
        try g.git(["config", "core.hooksPath", t.dir("nohooks").path])
        let f = t.file("sub/f.txt", "1")
        XCTAssertEqual(try g.status()["sub"], .untracked)
        try g.stage([f])
        XCTAssertEqual(try g.status()["sub/f.txt"], .added)
        _ = try g.commit(message: "init")
        try "2".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try g.status()["sub"], .modified)
        try g.discard([f])
        XCTAssertEqual(t.read("sub/f.txt"), "1")
        XCTAssertEqual(Git.repositoryRoot(for: t.url.appendingPathComponent("sub"))?.standardizedFileURL.path, t.url.standardizedFileURL.path)
    }
}

final class ActionsTests: XCTestCase {
    func testSubstitutionPerFile() {
        let a = ScriptAction(name: "x", kind: .shell, command: "sips {path} --out {dir}/{stem}.jpg", perFile: true)
        let s = ActionRunner.scripts(for: a, items: [URL(fileURLWithPath: "/tmp/it's here.png"), URL(fileURLWithPath: "/tmp/b.png")], dir: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], "sips '/tmp/it'\\''s here.png' --out '/tmp'/'it'\\''s here'.jpg")
    }

    func testBatchAndAppleScript() {
        let a = ScriptAction(name: "x", kind: .appleScript, command: "set f to {name}", perFile: false)
        let s = ActionRunner.scripts(for: a, items: [URL(fileURLWithPath: "/a/1.txt"), URL(fileURLWithPath: "/a/2 \"q\".txt")], dir: URL(fileURLWithPath: "/a"))
        XCTAssertEqual(s, [#"set f to {"1.txt", "2 \"q\".txt"}"#])
        XCTAssertFalse(ScriptAction(name: "d", kind: .shell, command: "ls {dir}", perFile: false).needsSelection)
    }

    func testShellRuns() {
        let t = TempDir()
        let o = ActionRunner.runShell("echo hi > out.txt", in: t.url)
        XCTAssertEqual(o.status, 0)
        XCTAssertEqual(t.read("out.txt"), "hi\n")
    }
}

final class URLSchemeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(AppURLScheme.parse(URL(string: "explorer:///%23")!), .newWindow)
        XCTAssertEqual(AppURLScheme.parse(URL(string: "explorer:///Users/me/My%20Docs/")!), .open(URL(fileURLWithPath: "/Users/me/My Docs/", isDirectory: true)))
        XCTAssertEqual(AppURLScheme.parse(URL(string: "explorerreveal:///Users/me/a%C3%A9.txt")!), .reveal(URL(fileURLWithPath: "/Users/me/aé.txt")))
        XCTAssertEqual(AppURLScheme.encode("/a b/é"), "/a%20b/%C3%A9")
    }
}

final class ContextMenuTests: XCTestCase {
    func testCollapseSeparators() {
        let l: [ContextMenuEntry] = [.separator(), .init(.open), .separator(), .separator(), .init(.copy), .separator()]
        XCTAssertEqual(ContextMenuLayout.collapseSeparators(l).map(\.isSeparator), [false, true, false])
    }
    func testDefaultsContainEveryCommand() {
        let have = Set(ContextMenuLayout.defaults.compactMap(\.command))
        XCTAssertEqual(have, Set(MenuCommand.allCases))
        XCTAssertFalse(ContextMenuLayout.defaults.first { $0.command == .revealInFinder }!.visible)
    }
}

final class MetadataTests: XCTestCase {
    func testRatingAndTagsRoundTrip() throws {
        let t = TempDir()
        let f = t.file("r.txt")
        try Metadata.setStarRating(f, 4)
        XCTAssertEqual(Metadata.starRating(f), 4)
        try Metadata.setStarRating(f, 0)
        XCTAssertNil(Metadata.starRating(f))
        try Metadata.toggleColor(.red, on: [f])
        XCTAssertTrue(Metadata.tags(f).contains("Red"))
        try Metadata.toggleColor(.red, on: [f])
        XCTAssertFalse(Metadata.tags(f).contains("Red"))
        try Metadata.toggleTextTag("Work", on: [f])
        XCTAssertEqual(FileItemLoader.load(f)?.tags, ["Work"])
    }

    func testSavedSearchRoundTrip() throws {
        let t = TempDir()
        let u = t.url.appendingPathComponent("s.savedSearch")
        try SavedSearchFile(rawQuery: "kMDItemFSName == \"*x*\"cd", scopes: ["/Users"], displayName: "s").write(to: u)
        let r = SavedSearchFile.read(u)
        XCTAssertEqual(r?.rawQuery, "kMDItemFSName == \"*x*\"cd")
        XCTAssertEqual(r?.scopes, ["/Users"])
    }
}

/// Regression: walking up from a standardized URL past "/" used to loop forever
/// (Foundation yields "/..", "/../..", …), eating ~140 MB/s until the app was killed.
final class ParentWalkTests: XCTestCase {
    func testParentDirectoryStopsAtRoot() {
        XCTAssertNil(URL(fileURLWithPath: "/").parentDirectory)
        XCTAssertNil(URL(fileURLWithPath: "/").standardizedFileURL.parentDirectory)
        XCTAssertEqual(URL(fileURLWithPath: "/Users").parentDirectory?.path, "/")
        XCTAssertEqual(URL(fileURLWithPath: "/Users/x/").standardizedFileURL.parentDirectory?.path, "/Users")
    }

    func testAncestorsAreFinite() {
        let a = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.selfAndAncestors
        XCTAssertEqual(a.last?.path, "/")
        XCTAssertLessThan(a.count, 10)
    }

    func testRepositoryRootTerminatesOutsideRepos() {
        XCTAssertNil(Git.repositoryRoot(for: URL(fileURLWithPath: "/")))
        XCTAssertNil(Git.repositoryRoot(for: URL(fileURLWithPath: "/usr/bin")))
        XCTAssertNil(Git.repositoryRoot(for: FileManager.default.temporaryDirectory.standardizedFileURL))
    }

    func testLocationParentTerminates() {
        var loc: Location? = .directory(URL(fileURLWithPath: "/a/b/c"))
        var n = 0
        while let l = loc, n < 100 { loc = l.parent; n += 1 }
        XCTAssertEqual(n, 4)  // /a/b/c, /a/b, /a, /
    }

    func testSameVolumeWithMissingDestination() {
        let t = TempDir()
        let f = t.file("a.txt")
        XCTAssertTrue(FileOperation.sameVolume(f, t.url.appendingPathComponent("missing/deeper")))
    }
}
