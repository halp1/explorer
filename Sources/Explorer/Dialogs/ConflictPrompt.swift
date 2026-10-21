import AppKit
import ExplorerKit

/// Naming-conflict dialog for copy/move. Files: Skip / Keep Both / Replace / Replace Older.
/// Folders: Skip / Merge / Replace. "Apply to All Files/Folders" makes the choice sticky.
enum ConflictPrompt {
    /// Called from a worker thread; blocks until the user answers.
    static func ask(_ c: Conflict, window: NSWindow?) -> ConflictAnswer {
        var answer = ConflictAnswer(.cancel)
        let work = { answer = present(c) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return answer
    }

    private static func present(_ c: Conflict) -> ConflictAnswer {
        Sounds.play(.question)
        let a = NSAlert()
        a.alertStyle = .warning
        let kind = c.isFolder ? "folder" : "item"
        a.messageText = String(format: "An %@ named “%@” already exists in this location.", kind, c.existing.lastPathComponent)
        a.informativeText = "Do you want to replace it?\n\n" + describe("Existing", c.existingModified, c.existingSize) + "\n" + describe("Incoming", c.sourceModified, c.sourceSize)
        a.icon = NSWorkspace.shared.icon(forFile: c.existing.path)
        var decisions: [ConflictDecision]
        if c.isFolder {
            a.addButton(withTitle: "Merge"); a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Skip"); a.addButton(withTitle: "Cancel")
            decisions = [.merge, .replace, .skip, .cancel]
        } else {
            a.addButton(withTitle: "Keep Both"); a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Replace Older")
            a.addButton(withTitle: "Skip"); a.addButton(withTitle: "Cancel")
            decisions = [.keepBoth, .replace, .replaceOlder, .skip, .cancel]
        }
        a.buttons.last?.keyEquivalent = "\u{1b}"
        if c.remaining > 0 {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = c.isFolder ? "Apply to All Folders" : "Apply to All Files"
        }
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let d = decisions.indices.contains(r) ? decisions[r] : .cancel
        return ConflictAnswer(d, applyToAll: a.suppressionButton?.state == .on)
    }

    private static func describe(_ label: String, _ date: Date?, _ size: Int64?) -> String {
        let d = DateDisplay(length: .medium, mode: .relative, showTime: true).string(date)
        return "\(label): \(SizeFormat.string(size)), modified \(d)"
    }
}
