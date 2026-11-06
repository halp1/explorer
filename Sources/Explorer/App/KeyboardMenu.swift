import AppKit

/// AppKit consumes even disabled menu equivalents. Let text navigation reach its editor first.
final class KeyboardMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window = event.window ?? NSApp.keyWindow, window.firstResponder is NSTextView {
            let mods = KeyboardShortcuts.modifiers(event.modifierFlags)
            if (mods == .command && [123, 124, 125, 126].contains(event.keyCode)) ||
                (mods.contains(.command) && [51, 117].contains(event.keyCode)) {
                return false
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
