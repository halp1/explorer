import XCTest
@testable import ExplorerKit

/// Archive features PARITY.md tracked as built but not exercised: multi-volume 7z and the filename encoding picker.
final class ArchiveParityTests: XCTestCase {
    private static let sevenZipTool = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Volumes are produced by the real 7-Zip so the test reads what users actually download.
    func testMultiVolume7zListsAndExtractsAcrossEveryVolume() throws {
        guard let tool = Self.sevenZipTool else { throw XCTSkip("needs 7zz to generate a multi-volume fixture") }
        let t = TempDir()
        let payload = String(repeating: "0123456789abcdef", count: 300)  // forces the entry across volumes
        t.file("src/hello.txt", "hello volumes")
        t.file("src/docs/notes.txt", payload)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.currentDirectoryURL = t.url.appendingPathComponent("src")
        p.arguments = ["a", "-mx=0", "-v1k", "../set.7z", "hello.txt", "docs"]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let first = t.url.appendingPathComponent("set.7z.001")
        let a = try Archive(url: first)
        XCTAssertEqual(a.format, .sevenZipMulti)
        XCTAssertGreaterThan(a.volumeURLs.count, 2)
        XCTAssertEqual(a.volumeURLs.map(\.lastPathComponent), (1...a.volumeURLs.count).map { String(format: "set.7z.%03d", $0) })

        let paths = Set(try a.load().map(\.path))
        XCTAssertEqual(paths, ["hello.txt", "docs/", "docs/notes.txt"])
        try a.extract([], to: t.dir("out"))
        XCTAssertEqual(t.read("out/docs/notes.txt"), payload)
        XCTAssertEqual(t.read("out/hello.txt"), "hello volumes")

        // A missing middle volume must be named, not reported as a password prompt for an unencrypted set.
        try FileManager.default.removeItem(at: t.url.appendingPathComponent("set.7z.002"))
        let broken = try Archive(url: first)
        XCTAssertThrowsError(try broken.load()) { e in
            guard case ArchiveError.missingVolume(let name) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(name, "set.7z.002")
        }
    }

    /// A zip written by an old Russian Windows tool: CP866 name bytes, no UTF-8 flag.
    func testFilenameEncodingPickerDecodesLegacyZipNames() throws {
        let zip = "UEsDBBQAAAAAAAAAIQBhmUJgBgAAAAYAAAAJAAAAjuLn8eIudHh0cHJpdmV0UEsBAhQDFAAAAAAAAAAhAGGZQmAGAAAABgAAAAkAAAAAAAAAAAAAAIABAAAAAI7i5/HiLnR4dFBLBQYAAAAAAQABADcAAAAtAAAAAAA="
        let t = TempDir()
        let url = t.url.appendingPathComponent("legacy.zip")
        try XCTUnwrap(Data(base64Encoded: zip)).write(to: url)

        let a = try Archive(url: url)
        a.filenameEncoding = "CP866"
        XCTAssertEqual(try a.load().map(\.path), ["Отчёт.txt"])
        try a.extract([], to: t.dir("out"))
        XCTAssertEqual(t.read("out/Отчёт.txt"), "privet")

        // Switching the picker and reloading must re-decode, as setArchiveEncoding does.
        a.filenameEncoding = "CP1251"
        XCTAssertNotEqual(try a.load().map(\.path), ["Отчёт.txt"])
        a.filenameEncoding = "CP866"
        XCTAssertEqual(try a.load().map(\.path), ["Отчёт.txt"])
    }
}
