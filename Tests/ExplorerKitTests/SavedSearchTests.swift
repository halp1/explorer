import XCTest
@testable import ExplorerKit

/// Save Search turns the typed text into a Spotlight raw query and the tree reopens it later.
final class SavedSearchTests: XCTestCase {
    func testSavedNameQueryMatchesTheTypedTextLiterally() throws {
        let t = TempDir()
        for text in ["report", "Bob's \"notes\"", "a\\b", "50% *off*", "what?"] {
            let file = t.url.appendingPathComponent("s.savedSearch")
            try SavedSearchFile(rawQuery: SpotlightSearch.nameRawQuery(text), scopes: [t.url.path], displayName: "s").write(to: file)
            let saved = try XCTUnwrap(SavedSearchFile.read(file), text)
            let p = try XCTUnwrap(SpotlightSearch.rawQueryPredicate(saved.rawQuery), text)
            XCTAssertTrue(p.evaluate(with: ["kMDItemFSName": "My " + text.uppercased() + ".txt"]), text)
            XCTAssertFalse(p.evaluate(with: ["kMDItemFSName": "other.txt"]), text)
        }
    }

    /// NSPredicate raises an Objective-C exception on a malformed query, which no Swift catch can stop.
    func testMalformedRawQueryIsRejectedInsteadOfRaising() {
        for raw in ["(kMDItemFSName = \"*Bob's \"notes\"*\"cd)", "garbage ((", ""] {
            XCTAssertNil(SpotlightSearch.rawQueryPredicate(raw), raw)
        }
        XCTAssertNotNil(SpotlightSearch.rawQueryPredicate("kMDItemUserTags == \"Red\""))
    }
}
