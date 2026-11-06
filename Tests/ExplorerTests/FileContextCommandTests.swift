import AppKit
import Combine
import ExplorerKit
import XCTest
@testable import Explorer

final class FileContextCommandTests: XCTestCase {
    @MainActor
    func testFilePopupTargetsClickedFileEvenWhileTreeKeepsFocusInEveryView() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-popup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("clicked.txt")
        try Data("must not target its parent".utf8).write(to: file)
        let prefs = Preferences.shared
        let options = prefs.defaultViewOptions
        let history = prefs.history
        let board = NSPasteboard.general
        let savedClipboard = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        let browser = BrowserWindowController(location: .directory(fixture))
        let window = try XCTUnwrap(browser.window)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            BrowserWindowController.all.removeAll { $0 === browser }
            prefs.defaultViewOptions = options
            prefs.history = history
            board.clearContents()
            board.writeObjects(savedClipboard)
        }
        for kind in ViewKind.allCases {
            let loaded = expectation(description: "Load popup fixture for \(kind)")
            let subscription = browser.state.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
            browser.state.options.view = kind
            browser.state.options.grouping = .none
            browser.state.go(.directory(fixture), recordHistory: false)
            wait(for: [loaded], timeout: 5)
            withExtendedLifetime(subscription) {}
            browser.setFileView(for: kind)
            browser.fileView.reloadItems()
            let index = try XCTUnwrap(browser.state.items.firstIndex { $0.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }, "\(kind): \(browser.state.items.map(\.name))")
            XCTAssertTrue(window.makeFirstResponder(browser.tree.outline))
            let popup: NSMenu?
            if let collection = browser.fileView as? CollectionViewController {
                popup = collection.menuFor(IndexPath(item: index, section: 0))
            } else if let table = browser.fileView as? TableViewController {
                popup = table.menuFor(row: index)
            } else if let gallery = browser.fileView as? GalleryViewController {
                popup = gallery.menuFor(IndexPath(item: index, section: 0))
            } else {
                XCTFail("Missing file view")
                return
            }
            let menu = try XCTUnwrap(popup)
            XCTAssertTrue(browser.hasTreeFocus, "Popup origin must not depend on focus")
            let copy = try XCTUnwrap(menu.items.first { $0.action == #selector(BrowserWindowController.copy(_:)) })
            XCTAssertTrue(browser.validateMenuItem(copy), "\(kind)")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
            XCTAssertEqual(FileOps.shared.clipboardURLs.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()], "\(kind)")
            let trash = try XCTUnwrap(menu.items.first { $0.action == #selector(BrowserWindowController.moveToTrash(_:)) })
            XCTAssertTrue(browser.validateMenuItem(trash), "\(kind)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        }
    }
}
