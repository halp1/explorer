import AppKit

/// Explicit targeting avoids NSWindow's empty native undo manager swallowing file undo.
/// Text editors still use their own undo manager and never fall back to file history.
final class UndoMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = UndoMenuTarget()
    private let windowProvider: () -> NSWindow?

    init(windowProvider: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.windowProvider = windowProvider
        super.init()
    }

    private enum Context {
        case text(UndoManager?)
        case files(BrowserWindowController)
        case unavailable
    }

    private var context: Context {
        guard let window = windowProvider() else { return .unavailable }
        if let editor = window.firstResponder as? NSTextView { return .text(editor.undoManager) }
        guard window.attachedSheet == nil, let browser = window.windowController as? BrowserWindowController else { return .unavailable }
        return .files(browser)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let redo = item.action == #selector(self.redo(_:))
        switch context {
        case .text(let manager):
            item.title = redo ? (manager?.redoMenuItemTitle ?? "Redo") : (manager?.undoMenuItemTitle ?? "Undo")
            return redo ? manager?.canRedo == true : manager?.canUndo == true
        case .files(let browser):
            return browser.validateMenuItem(item)
        case .unavailable:
            item.title = redo ? "Redo" : "Undo"
            return false
        }
    }

    @objc func undo(_ sender: Any?) {
        switch context {
        case .text(let manager): if manager?.canUndo == true { manager?.undo() }
        case .files(let browser): browser.undo(sender)
        case .unavailable: break
        }
    }

    @objc func redo(_ sender: Any?) {
        switch context {
        case .text(let manager): if manager?.canRedo == true { manager?.redo() }
        case .files(let browser): browser.redo(sender)
        case .unavailable: break
        }
    }
}
