import XCTest
@testable import ExplorerKit

final class ArchiveTests: XCTestCase {
    func fixture(_ t: TempDir) -> [URL] {
        t.file("in/hello.txt", "hello world")
        t.file("in/folder/inner.txt", "inner")
        t.file("in/folder/deep/z.txt", "z")
        return [t.url.appendingPathComponent("in/hello.txt"), t.url.appendingPathComponent("in/folder")]
    }

    func testDetect() {
        XCTAssertEqual(ArchiveFormat.detect(fileName: "a.tar.gz"), .tarGz)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "a.TGZ"), .tarGz)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "a.7z.001"), .sevenZipMulti)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "a.gz"), .gz)
        XCTAssertNil(ArchiveFormat.detect(fileName: "a.txt"))
        XCTAssertEqual(ArchiveFormat.baseName("photos.tar.gz"), "photos")
        XCTAssertEqual(ArchiveFormat.baseName("x.7z.001"), "x")
    }

    func roundTrip(_ f: ArchiveFormat, password: String? = nil) throws {
        let t = TempDir()
        let items = fixture(t)
        let dest = t.url.appendingPathComponent("out." + f.fileExtension)
        try Archive.create(at: dest, format: f, items: items, password: password)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "\(f)")

        let a = try Archive(url: dest, password: password)
        let entries = try a.load()
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("hello.txt"), "\(f): \(paths)")
        XCTAssertTrue(paths.contains("folder/"), "\(f): \(paths)")
        XCTAssertTrue(paths.contains("folder/deep/z.txt"), "\(f): \(paths)")
        XCTAssertEqual(Set(a.children(of: "").map(\.name)), ["hello.txt", "folder"], "\(f)")

        let out = t.dir("x")
        try a.extract([], to: out)
        XCTAssertEqual(t.read("x/hello.txt"), "hello world", "\(f)")
        XCTAssertEqual(t.read("x/folder/deep/z.txt"), "z", "\(f)")

        // Partial extract with prefix stripping
        let out2 = t.dir("y")
        try a.extract(["folder/"], to: out2, stripPrefix: "folder/")
        XCTAssertEqual(t.read("y/inner.txt"), "inner", "\(f)")

        // Modify
        let extra = t.file("extra.txt", "E")
        try a.add([extra], into: "folder/")
        XCTAssertTrue(a.entries.contains { $0.path == "folder/extra.txt" }, "\(f)")
        try a.remove(["hello.txt"])
        XCTAssertFalse(a.entries.contains { $0.path == "hello.txt" }, "\(f)")
        XCTAssertTrue(a.entries.contains { $0.path == "folder/deep/z.txt" }, "\(f)")
    }

    func testZip() throws { try roundTrip(.zip) }
    func testTar() throws { try roundTrip(.tar) }
    func testTarGz() throws { try roundTrip(.tarGz) }
    func testTarBz2() throws { try roundTrip(.tarBz2) }
    func testTarXz() throws { try roundTrip(.tarXz) }
    func testSevenZip() throws { try roundTrip(.sevenZip) }
    func testProtectedZip() throws { try roundTrip(.zip, password: "s3cret") }
    func testProtected7z() throws { try roundTrip(.sevenZip, password: "s3cret") }

    func testTar7z() throws {
        let t = TempDir()
        let items = fixture(t)
        let dest = t.url.appendingPathComponent("o.tar.7z")
        try Archive.create(at: dest, format: .tar7z, items: items)
        let a = try Archive(url: dest)
        let paths = Set(try a.load().map(\.path))
        XCTAssertTrue(paths.contains("folder/deep/z.txt"), "\(paths)")
        let out = t.dir("x")
        try a.extract([], to: out)
        XCTAssertEqual(t.read("x/hello.txt"), "hello world")
    }

    func testPasswordRequired() throws {
        let t = TempDir()
        let items = fixture(t)
        let dest = t.url.appendingPathComponent("p.7z")
        try Archive.create(at: dest, format: .sevenZip, items: items, password: "pw")
        let a = try Archive(url: dest)
        XCTAssertThrowsError(try a.load()) { e in
            XCTAssertEqual(e as? ArchiveError, .passwordRequired)
        }
    }

    func testSingleFileTarGzBecomesGz() throws {
        let t = TempDir()
        let f = t.file("one.txt", "single")
        let dest = t.url.appendingPathComponent("one.txt.gz")
        try Archive.create(at: dest, format: .tarGz, items: [f])
        let a = try Archive(url: dest)
        let e = try a.load()
        XCTAssertEqual(e.map(\.path), ["one.txt"])
        let out = t.dir("x")
        try a.extract([], to: out)
        XCTAssertEqual(t.read("x/one.txt"), "single")
    }

    func testZipCompressedSizes() throws {
        let t = TempDir()
        let big = t.file("big.txt", String(repeating: "abcdefgh", count: 10000))
        let dest = t.url.appendingPathComponent("c.zip")
        try Archive.create(at: dest, format: .zip, items: [big])
        let a = try Archive(url: dest)
        let e = try a.load().first { $0.path == "big.txt" }!
        XCTAssertEqual(e.size, 80000)
        XCTAssertNotNil(e.compressedSize)
        XCTAssertLessThan(e.compressedSize!, 80000)
    }

    func testOfficeTemplatesAreValidZips() throws {
        let t = TempDir()
        for tpl in [DocumentTemplate.word, .excel, .powerpoint] {
            let u = t.url.appendingPathComponent(tpl.defaultName)
            try tpl.write(to: u)
            try FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: u.path + ".zip"))
            let entries = try Archive(url: URL(fileURLWithPath: u.path + ".zip")).load()
            XCTAssertTrue(entries.contains { $0.path == "[Content_Types].xml" }, "\(tpl)")
        }
    }
}
