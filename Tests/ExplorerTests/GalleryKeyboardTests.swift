import AppKit
import Combine
import ExplorerKit
import XCTest
@testable import Explorer

final class GalleryKeyboardTests: XCTestCase {
    @MainActor
    func testGalleryTypeSelectionAndQuickLookArrowNavigationUseThumbnailResponder() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-keyboard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
        for name in ["alpha.png", "middle.png", "zebra.png"] {
            try pixel.write(to: fixture.appendingPathComponent(name))
        }
        let state = BrowserState(location: .directory(fixture))
        let loaded = expectation(description: "Fixture files loaded")
        let subscription = state.$items.filter { $0.count == 3 }.prefix(1).sink { _ in loaded.fulfill() }
        state.reload()
        wait(for: [loaded], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(state.items.count, 3)

        let gallery = GalleryViewController()
        gallery.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = gallery
        defer { window.close() }
        gallery.reloadItems()
        window.contentView?.layoutSubtreeIfNeeded()
        gallery.focus()
        XCTAssertTrue(window.firstResponder === gallery.keyboardView)
        gallery.keyboardView.keyDown(with: key(6, characters: "z", window: window))
        XCTAssertEqual(state.selection.map(\.name), ["zebra.png"])

        let ordered = state.items
        state.selection = [ordered[0]]
        gallery.syncSelection()
        XCTAssertTrue(gallery.handlePreviewNavigation(key(124, window: window)))
        XCTAssertEqual(state.selection.map(\.name), [ordered[1].name])
        XCTAssertTrue(window.firstResponder === gallery.keyboardView)
        XCTAssertTrue(gallery.handlePreviewNavigation(key(124, modifiers: .shift, window: window)))
        XCTAssertEqual(state.selection.map(\.name), [ordered[1].name, ordered[2].name])
        XCTAssertTrue(gallery.handlePreviewNavigation(key(123, modifiers: .shift, window: window)))
        XCTAssertEqual(state.selection.map(\.name), [ordered[1].name])
        XCTAssertFalse(gallery.handlePreviewNavigation(key(124, modifiers: .command, window: window)))
        XCTAssertFalse(gallery.handlePreviewNavigation(key(49, characters: " ", window: window)))
        XCTAssertEqual(state.selection.map(\.name), [ordered[1].name])
    }

    @MainActor
    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        let arrowCharacters: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                             125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
        let text = arrowCharacters[code].map { String(UnicodeScalar($0)!) } ?? characters
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }
}
