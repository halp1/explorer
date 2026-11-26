import XCTest
@testable import ExplorerKit

/// Archive features PARITY.md tracked as built but not exercised: the filename encoding picker.
final class ArchiveParityTests: XCTestCase {
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
