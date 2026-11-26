import XCTest
@testable import ExplorerKit

/// The JSON-backed lists behind tab sets and network share pin/hide/forget, each in a temp file.
final class StoreParityTests: XCTestCase {
    func testTabSetsSurviveARelaunchAndReplaceByName() throws {
        let t = TempDir()
        let file = t.url.appendingPathComponent("TabSets.json")
        let work = TabSet(name: "Work", tabs: [SavedTab(path: "/tmp/a", title: "Inbox", colorIndex: 3), SavedTab(path: "/tmp/b ö")])
        let store = JSONStore<TabSet>(file: file)
        store.items.append(work)
        store.items.append(TabSet(name: "Home", tabs: [SavedTab(path: "/tmp/c")]))
        // Save Tab Set over an existing name replaces it, as TabSetsUI.save does.
        store.items.removeAll { $0.name == "Home" }
        store.items.append(TabSet(name: "Home", tabs: [SavedTab(path: "/tmp/d")]))

        let reopened = JSONStore<TabSet>(file: file)
        XCTAssertEqual(reopened.items.map(\.name), ["Work", "Home"])
        XCTAssertEqual(reopened.items[0], work)
        XCTAssertEqual(reopened.items[1].tabs.map(\.path), ["/tmp/d"])

        // A corrupt file falls back to defaults instead of crashing at launch.
        try Data("{ not json".utf8).write(to: file)
        XCTAssertEqual(JSONStore<TabSet>(file: file, defaults: [work]).items, [work])
    }

    func testSharePinHideForgetAndRemountState() {
        let t = TempDir()
        let file = t.url.appendingPathComponent("RecentShares.json")
        let store = JSONStore<RecentShare>(file: file)
        RecentSharesStore.remember("smb://nas/media", mountPath: "/Volumes/media", in: store)
        RecentSharesStore.remember("smb://nas/backup%20set", mountPath: nil, in: store)
        XCTAssertEqual(store.items.map(\.url), ["smb://nas/backup%20set", "smb://nas/media"])
        XCTAssertEqual(store.items.map(\.displayName), ["backup set", "media"])

        // Pin one, hide the other (MountShareView.toggle and the tree's Pin and Hide items).
        store.items[1].pinned = true
        store.items[0].hidden = true
        let reopened = JSONStore<RecentShare>(file: file)
        XCTAssertEqual(reopened.items.filter(\.pinned).map(\.url), ["smb://nas/media"])
        XCTAssertEqual(reopened.items.filter { !$0.hidden }.map(\.url), ["smb://nas/media"])

        // Mounting a hidden share again brings it back, keeps its position and does not duplicate it.
        RecentSharesStore.remember("smb://nas/backup%20set", mountPath: "/Volumes/backup set", in: reopened)
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertFalse(reopened.items[0].hidden)
        XCTAssertEqual(reopened.items[0].lastMountPath, "/Volumes/backup set")
        XCTAssertTrue(reopened.items[1].pinned, "remembering one share must not touch another's pin")

        // Forget removes it for good.
        reopened.items.removeAll { $0.url == "smb://nas/media" }
        XCTAssertEqual(JSONStore<RecentShare>(file: file).items.map(\.url), ["smb://nas/backup%20set"])
    }

    func testMountedShareMatchingIgnoresCredentialsCaseAndTrailingSlash() {
        XCTAssertEqual(NetworkMounter.normalizedShare("smb://Josh:pw@NAS.local/Media/"), NetworkMounter.normalizedShare("smb://nas.local/media"))
        XCTAssertNotEqual(NetworkMounter.normalizedShare("smb://nas.local/media"), NetworkMounter.normalizedShare("smb://nas.local/media2"))
    }
}
