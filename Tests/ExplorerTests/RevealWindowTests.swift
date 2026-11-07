import AppKit
import ExplorerKit
import XCTest
@testable import Explorer

final class RevealWindowTests: XCTestCase {
    /// Reveal requests (Chrome "Show in folder") open a new window already pointed at the parent folder.
    @MainActor
    func testNewWindowRevealingAFileLoadsTheFolderAndSelectsTheFile() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-reveal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        let target = fixture.appendingPathComponent("download.pdf")
        for url in [fixture.appendingPathComponent("other.txt"), target] { try Data("x".utf8).write(to: url) }
        let originalHistory = Preferences.shared.history
        let controller = BrowserWindowController(location: .directory(fixture), select: [target])
        defer {
            controller.window?.close()
            BrowserWindowController.all.removeAll { $0 === controller }
            Preferences.shared.history = originalHistory
            try? FileManager.default.removeItem(at: fixture)
        }
        let state = controller.state
        let deadline = Date().addingTimeInterval(5)
        while (state.items.isEmpty || state.loading) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(Set(state.items.map(\.url.lastPathComponent)), ["other.txt", "download.pdf"])
        XCTAssertEqual(state.selection.map(\.url.lastPathComponent), ["download.pdf"])
    }
}
