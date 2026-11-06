import AppKit
import Combine
import ExplorerKit
import XCTest
@testable import Explorer

final class DeleteUndoTests: XCTestCase {
    @MainActor
    func testDeleteThenCommandZRestoresAllFilesThroughRealMenuResponderChain() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-delete-undo-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        let originals = ["first.txt", "second.txt"].map { fixture.appendingPathComponent($0) }
        for (index, url) in originals.enumerated() { try Data("original-\(index)".utf8).write(to: url) }
        let originalMenu = NSApp.mainMenu
        let originalHistory = Preferences.shared.history
        let originalSounds = Preferences.shared.sounds
        Preferences.shared.sounds = .off
        let trash = Trasher(privateTrashRoot: fixture.appendingPathComponent("private-trash", isDirectory: true), useSystemTrash: false)
        let operations = FileOps(trasher: trash)
        let controller = BrowserWindowController(location: .directory(fixture), operations: operations)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        // XCTest has no foreground key window. Supply the real browser window to the menu target.
        let undoTarget = UndoMenuTarget(windowProvider: { window })
        defer { withExtendedLifetime(undoTarget) {} }
        let menu = KeyboardMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = MainMenu.editMenu(undoTarget: undoTarget)
        menu.addItem(edit)
        NSApp.mainMenu = menu
        controller.fileView.focus()
        let history = operations.history
        let initialUndoCount = history.undoStack.count
        defer {
            // Restore only this test's files if an assertion exposed a broken undo path.
            let entries = history.undoStack + history.redoStack
            for entry in entries {
                for pair in trashPairs(entry.action) where originals.contains(pair.from) {
                    if !FileManager.default.fileExists(atPath: pair.from.path), FileManager.default.fileExists(atPath: pair.to.path) {
                        try? FileManager.default.moveItem(at: pair.to, to: pair.from)
                    }
                }
            }
            NSApp.mainMenu = originalMenu
            controller.state.selection = []
            window.close()
            BrowserWindowController.all.removeAll { $0 === controller }
            Preferences.shared.history = originalHistory
            Preferences.shared.sounds = originalSounds
            try? FileManager.default.removeItem(at: fixture)
        }
        let loaded = expectation(description: "File view loaded")
        let loadSubscription = controller.state.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        controller.state.reload()
        wait(for: [loaded], timeout: 5)
        withExtendedLifetime(loadSubscription) {}
        controller.state.selection = try originals.map { try XCTUnwrap(FileItemLoader.load($0)) }
        controller.fileView.focus()

        XCTAssertFalse(controller.hasTreeFocus)
        XCTAssertEqual(Set(controller.selURLs), Set(originals))
        let trashed = expectation(description: "Actual file deletion recorded for undo")
        let subscription = history.$undoStack.filter { $0.count == initialUndoCount + 1 }.prefix(1).sink { _ in trashed.fulfill() }
        controller.moveToTrash(nil)
        wait(for: [trashed], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: key(6, window: window)))
        for (index, url) in originals.enumerated() {
            XCTAssertEqual(try? String(contentsOf: url), "original-\(index)")
        }
        XCTAssertEqual(history.undoStack.count, initialUndoCount)
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: key(6, modifiers: [.command, .shift], window: window)))
        XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(history.undoStack.count, initialUndoCount + 1)
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: key(6, window: window)))
        for (index, url) in originals.enumerated() {
            XCTAssertEqual(try? String(contentsOf: url), "original-\(index)")
        }
        XCTAssertEqual(history.undoStack.count, initialUndoCount)
    }

    @MainActor
    func testImmediateCommandZWaitsForDeletionReceiptThenRestoresOnce() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-immediate-undo-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("recover.txt")
        try Data("recover immediately".utf8).write(to: file)
        let trash = Trasher(privateTrashRoot: fixture.appendingPathComponent("trash", isDirectory: true), useSystemTrash: false)
        let operations = FileOps(trasher: trash)
        let browser = BrowserWindowController(location: .directory(fixture), operations: operations)
        let window = try XCTUnwrap(browser.window)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            BrowserWindowController.all.removeAll { $0 === browser }
        }
        browser.state.selection = [try XCTUnwrap(FileItemLoader.load(file))]
        browser.fileView.focus()
        let target = UndoMenuTarget(windowProvider: { window })
        defer { withExtendedLifetime(target) {} }
        let menu = MainMenu.editMenu(undoTarget: target)
        let restored = expectation(description: "Queued undo completed after deletion")
        let subscription = operations.history.$redoStack.filter { $0.count == 1 }.prefix(1).sink { _ in restored.fulfill() }
        browser.moveToTrash(nil)
        XCTAssertTrue(menu.performKeyEquivalent(with: key(6, window: window)))
        XCTAssertFalse(operations.canUndo)
        wait(for: [restored], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(try String(contentsOf: file), "recover immediately")
        XCTAssertTrue(operations.history.undoStack.isEmpty)
        XCTAssertEqual(operations.history.redoStack.count, 1)
    }

    @MainActor
    func testTextUndoNeverConsumesFileHistoryAndFileUndoWorksWithoutSelection() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-text-undo-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let before = fixture.appendingPathComponent("before.txt")
        let after = fixture.appendingPathComponent("after.txt")
        try Data("file content".utf8).write(to: after)
        let operations = FileOps()
        operations.history.record("Rename", .moved([MovePair(from: before, to: after)]))
        let browser = BrowserWindowController(location: .directory(fixture), operations: operations)
        let window = try XCTUnwrap(browser.window)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            BrowserWindowController.all.removeAll { $0 === browser }
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        editor.allowsUndo = true
        editor.string = "before"
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" after", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        let target = UndoMenuTarget(windowProvider: { window })
        defer { withExtendedLifetime(target) {} }
        let menu = MainMenu.editMenu(undoTarget: target)
        XCTAssertTrue(menu.performKeyEquivalent(with: key(6, window: window)))
        XCTAssertEqual(editor.string, "before")
        XCTAssertEqual(operations.history.undoStack.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: after.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.path))
        XCTAssertTrue(menu.performKeyEquivalent(with: key(6, modifiers: [.command, .shift], window: window)))
        XCTAssertEqual(editor.string, "before after")
        editor.undoManager?.removeAllActions()
        let undo = try XCTUnwrap(menu.items.first { $0.action == #selector(UndoMenuTarget.undo(_:)) })
        XCTAssertFalse(target.validateMenuItem(undo))
        target.undo(nil)
        XCTAssertEqual(operations.history.undoStack.count, 1)
        browser.state.selection = []
        browser.fileView.focus()
        XCTAssertTrue(target.validateMenuItem(undo))
        XCTAssertTrue(menu.performKeyEquivalent(with: key(6, window: window)))
        XCTAssertEqual(try String(contentsOf: before), "file content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.path))
        XCTAssertTrue(operations.history.undoStack.isEmpty)
    }

    private func trashPairs(_ action: UndoAction) -> [MovePair] {
        switch action {
        case .trashed(let pairs): return pairs
        case .composite(let actions): return actions.flatMap(trashPairs)
        default: return []
        }
    }

    @MainActor
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) -> NSEvent {
        // AppKit needs layout-generated unmodified characters to distinguish Undo from Shift-Redo.
        // Construct but never post a system keyboard event. The menu target supplies its window.
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)!
    }
}
