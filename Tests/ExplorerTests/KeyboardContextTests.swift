import AppKit
import Combine
import ExplorerKit
import Quartz
import XCTest
@testable import Explorer

final class KeyboardContextTests: XCTestCase {
    @MainActor
    func testMenuAndRawKeyValidationProtectEditorsAndTreeFromStaleFileSelection() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-context-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stale = fixture.appendingPathComponent("stale.txt")
        try Data("unchanged".utf8).write(to: stale)
        let controller = BrowserWindowController(location: .directory(fixture))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer {
            controller.state.selection = []
            window.close()
            BrowserWindowController.all.removeAll { $0 === controller }
        }
        let file = try XCTUnwrap(FileItemLoader.load(stale))
        controller.state.selection = [file]
        controller.fileView.focus()
        let shelf = NSMenuItem(title: "", action: #selector(BrowserWindowController.addToShelf(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        shelf.keyEquivalentModifierMask = .command
        shelf.target = controller
        let menu = KeyboardMenu()
        menu.addItem(shelf)
        XCTAssertTrue(controller.validateMenuItem(shelf))

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        editor.string = "editing text"
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(controller.validateMenuItem(shelf))
        menu.update()
        let right = key(124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command, window: window)
        XCTAssertFalse(menu.performKeyEquivalent(with: right))
        XCTAssertFalse(controller.handleKey(right))
        let delete = NSMenuItem(title: "", action: #selector(BrowserWindowController.deletePermanently(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(delete))
        XCTAssertFalse(controller.handleKey(key(117, modifiers: .option, window: window)))
        XCTAssertEqual(try String(contentsOf: stale), "unchanged")

        XCTAssertTrue(window.makeFirstResponder(controller.tree.outline))
        let rating = NSMenuItem(title: "", action: #selector(BrowserWindowController.setRating(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(rating))
        let openWith = NSMenuItem(title: "", action: #selector(BrowserWindowController.openWithApp(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(openWith))
        let quickLookWasOpen = QLPreviewPanel.sharedPreviewPanelExists()
        XCTAssertTrue(controller.handleKey(key(49, characters: " ", window: window), fromTree: true))
        XCTAssertEqual(QLPreviewPanel.sharedPreviewPanelExists(), quickLookWasOpen)
        XCTAssertEqual(controller.state.selection.map(\.url), [stale])
        XCTAssertEqual(try String(contentsOf: stale), "unchanged")
    }

    @MainActor
    func testCommandDownOpensExactlyOnceThroughEveryFileViewResponder() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-open-key-" + UUID().uuidString, isDirectory: true)
        let child = fixture.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let originalOptions = Preferences.shared.defaultViewOptions
        let originalHistory = Preferences.shared.history
        let controller = BrowserWindowController(location: .directory(fixture))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            BrowserWindowController.all.removeAll { $0 === controller }
            Preferences.shared.defaultViewOptions = originalOptions
            Preferences.shared.history = originalHistory
        }
        for kind in ViewKind.allCases {
            let loaded = expectation(description: "Load fixture for \(kind)")
            let subscription = controller.state.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
            controller.state.options.view = kind
            controller.state.go(.directory(fixture), recordHistory: false)
            wait(for: [loaded], timeout: 5)
            withExtendedLifetime(subscription) {}
            controller.setFileView(for: kind)
            controller.state.selection = [try XCTUnwrap(FileItemLoader.load(child))]
            controller.fileView.reloadItems()
            controller.fileView.focus()
            let priorHistoryCount = controller.state.backStack.count
            controller.fileView.keyboardView.keyDown(with: key(125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .command, window: window))
            XCTAssertEqual(controller.state.location, .directory(child), "\(kind)")
            XCTAssertEqual(controller.state.backStack.count, priorHistoryCount + 1, "\(kind)")
        }
    }

    @MainActor
    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }
}
