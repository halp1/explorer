import AppKit

/// A popup originating in a file view retains that scope even if the sidebar still has focus.
final class FileContextMenu: NSMenu {}

extension NSMenuItem {
    var isFileContextCommand: Bool {
        var ancestor = menu
        while let current = ancestor {
            if current is FileContextMenu { return true }
            ancestor = current.supermenu
        }
        return false
    }
}
