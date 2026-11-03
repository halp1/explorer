import AppKit
import UniformTypeIdentifiers
import ExplorerKit

/// App-wide coordinator for file operations: progress, undo/redo, conflicts, clipboard and sounds.
final class FileOps: ObservableObject {
    static let shared = FileOps()

    @Published private(set) var running: [FileOperation] = []
    let history = UndoHistory()
    let prefs = Preferences.shared

    /// Internal (Explorer-style) cut: items waiting to be moved on paste.
    @Published private(set) var internalCut: [URL] = []
    /// Cut via Trash: original → location in trash, plus the pasteboard change count we wrote.
    private var cutViaTrash: (pairs: [MovePair], changeCount: Int)?

    var trasher: Trasher { Trasher(allowPrivateTrash: prefs.usePrivateTrash) }

    @discardableResult
    private func admit(_ urls: [URL], window: NSWindow?) -> Bool {
        do { try LocalFileBoundary.require(urls) }
        catch {
            Alerts.error("Local File Operation Unavailable", error.localizedDescription, window: window)
            return false
        }
        return true
    }

    // MARK: Generic runner

    @discardableResult
    func start(_ kind: FileOperationKind, _ sources: [URL], to dest: URL?, window: NSWindow?, title: String? = nil,
               completion: ((FileOperation) -> Void)? = nil) -> FileOperation {
        let op = FileOperation(kind: kind, sources: sources, destination: dest)
        guard admit(sources + (dest.map { [$0] } ?? []), window: window) else {
            // Keep the returned operation observable, but its own boundary will fail before work.
            op.onFinish = completion
            op.start()
            return op
        }
        op.trasher = trasher
        op.resolver = { [weak window] c in ConflictPrompt.ask(c, window: window) }
        op.errorHandler = { [weak self, weak window] e, u in self?.askContinue(after: e, item: u, kind: kind, window: window) ?? false }
        op.onFinish = { [weak self] op in
            guard let self else { return }
            self.running.removeAll { $0 === op }
            self.history.record(title ?? kind.undoTitle, op.undo)
            switch op.state {
            case .done: Sounds.play(kind == .trash || kind == .delete ? .trash : .done)
            case .failed(let msg):
                Sounds.play(.error)
                Alerts.error(Self.errorTitle(kind), msg, window: window)
            default: break
            }
            completion?(op)
        }
        running.append(op)
        op.start()
        return op
    }

    static func errorTitle(_ k: FileOperationKind) -> String {
        switch k {
        case .copy: return "Error while copying"
        case .move: return "Error while moving"
        case .duplicate: return "Error while duplicating"
        case .trash: return "Error while moving to trash"
        case .delete: return "Error while deleting"
        case .link: return "Error while creating a symlink"
        case .alias: return "Error while creating an alias"
        }
    }

    /// Called on the worker thread when an item fails. Offers "Retry as Administrator" for permission errors.
    private func askContinue(after e: Error, item: URL, kind: FileOperationKind, window: NSWindow?) -> Bool {
        var result = true
        DispatchQueue.main.sync {
            let ns = e as NSError
            let permission = (ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code))
                || (ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code))
            let a = NSAlert()
            a.messageText = String(format: "“%@” failed", item.lastPathComponent)
            a.informativeText = e.localizedDescription
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: "Cancel")
            if permission { a.addButton(withTitle: "Retry as Administrator") }
            let r = a.runModal()
            switch r {
            case .alertFirstButtonReturn: result = true
            case .alertThirdButtonReturn:
                result = true
                retryPrivileged(kind, item, window: window)
            default: result = false
            }
        }
        return result
    }

    private func retryPrivileged(_ kind: FileOperationKind, _ item: URL, window: NSWindow?) {
        let ops: [Privileged.Op]
        switch kind {
        case .delete, .trash: ops = [.remove(item.path)]
        default: return
        }
        Privileged.shared.run(ops) { e in
            if let e, !(e is OpError) { Alerts.error("The operation could not be completed.", e.localizedDescription, window: window) }
        }
    }

    // MARK: Undo / Redo

    func undo(window: NSWindow?) {
        do { try history.undo(trash: trasher); Sounds.play(.done) }
        catch { Alerts.error("Error while undoing", error.localizedDescription, window: window) }
    }

    func redo(window: NSWindow?) {
        do { try history.redo(trash: trasher) }
        catch { Alerts.error("Error while undoing", error.localizedDescription, window: window) }
    }

    // MARK: Trash / Delete

    func moveToTrash(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty, admit(urls, window: window) else { return }
        // Items that cannot go to the system Trash and private trash is disabled → offer permanent delete.
        if !prefs.usePrivateTrash {
            let unsupported = urls.filter { !Self.volumeSupportsTrash($0) }
            if !unsupported.isEmpty {
                let a = NSAlert()
                a.messageText = "Trash Is Unavailable for This Location"
                a.informativeText = String(format: "“%@” could not be moved to Trash. You can permanently delete it instead, but this cannot be undone.", unsupported[0].lastPathComponent)
                a.addButton(withTitle: "Delete Permanently"); a.addButton(withTitle: "Cancel")
                a.alertStyle = .warning
                if a.runModal() == .alertFirstButtonReturn { start(.delete, urls, to: nil, window: window) }
                return
            }
        }
        start(.trash, urls, to: nil, window: window)
    }

    static func volumeSupportsTrash(_ u: URL) -> Bool {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: u, create: false)) != nil
    }

    func deletePermanently(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty, admit(urls, window: window) else { return }
        let a = NSAlert()
        a.messageText = urls.count == 1 ? String(format: "Permanently Delete “%@”?", urls[0].lastPathComponent) : "Are you sure you want to delete the selected items permanently?"
        a.informativeText = "This action is immediate and cannot be undone."
        a.alertStyle = .critical
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        Sounds.play(.question)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        start(.delete, urls, to: nil, window: window)
    }

    func emptyTrash(window: NSWindow?) {
        let items = (try? FileManager.default.contentsOfDirectory(at: Volumes.userTrash, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Are you sure you want to delete the selected items permanently?"
        a.informativeText = "This action is immediate and cannot be undone."
        a.addButton(withTitle: "Empty Trash"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        start(.delete, items, to: nil, window: window)
    }

    // MARK: Clipboard

    func copy(_ urls: [URL]) {
        guard urls.allSatisfy(LocalFileBoundary.accepts) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        internalCut = []
        cutViaTrash = nil
    }

    func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map { LocalFileBoundary.accepts($0) ? $0.path : $0.absoluteString }.joined(separator: "\n"), forType: .string)
    }

    /// Cut: per settings, either move to Trash now (works with other apps) or remember for an internal move.
    func cut(_ urls: [URL], window: NSWindow?, forceInternal: Bool = false) {
        guard !urls.isEmpty, admit(urls, window: window) else { return }
        let cloud = urls.contains(where: Volumes.isInCloudStorage)
        if forceInternal || !prefs.cutViaTrash || (cloud && prefs.internalCutForCloud) {
            copy(urls)
            internalCut = urls
            return
        }
        start(.trash, urls, to: nil, window: window, title: "Cut via Trash") { [weak self] op in
            guard let self, op.state == .done, case .trashed(let pairs)? = op.undo else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(pairs.map(\.to) as [NSURL])
            self.cutViaTrash = (pairs, pb.changeCount)
            self.internalCut = []
        }
    }

    var clipboardURLs: [URL] {
        ((NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).filter(LocalFileBoundary.accepts)
    }

    var canPaste: Bool { !clipboardURLs.isEmpty || NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.image.identifier, UTType.plainText.identifier]) }

    /// Detects that the pasteboard was replaced while cut-via-trash items were waiting.
    func checkClipboardReplaced(window: NSWindow?) {
        guard let c = cutViaTrash, NSPasteboard.general.changeCount != c.changeCount else { return }
        cutViaTrash = nil
        Alerts.info("Clipboard Replaced", "The clipboard was replaced while items cut to Trash were waiting to be pasted. Those items remain in Trash.", window: window)
    }

    enum PasteMode { case auto, move, symlinks, aliases }

    func paste(into dest: URL, mode: PasteMode = .auto, window: NSWindow?, completion: (([URL]) -> Void)? = nil) {
        let urls = clipboardURLs
        guard !urls.isEmpty, admit(urls + [dest], window: window) else { return }
        let done: (FileOperation) -> Void = { op in completion?(op.results) }
        switch mode {
        case .symlinks: start(.link, urls, to: dest, window: window, completion: done)
        case .aliases: start(.alias, urls, to: dest, window: window, completion: done)
        case .move: start(.move, urls, to: dest, window: window, completion: done)
        case .auto:
            if let c = cutViaTrash, NSPasteboard.general.changeCount == c.changeCount {
                cutViaTrash = nil
                NSPasteboard.general.clearContents()
                start(.move, c.pairs.map(\.to), to: dest, window: window, title: "Paste", completion: done)
            } else if !internalCut.isEmpty, Set(internalCut) == Set(urls) {
                internalCut = []
                start(.move, urls, to: dest, window: window, completion: done)
            } else {
                start(.copy, urls, to: dest, window: window, completion: done)
            }
        }
    }

    // MARK: Drag & drop

    /// Decides the operation for a drop given modifier keys and settings.
    func dropOperation(sources: [URL], dest: URL, modifiers: NSEvent.ModifierFlags) -> FileOperationKind {
        if modifiers.contains(.control) { return prefs.linking == .symlink ? (modifiers.contains(.option) ? .alias : .link) : (modifiers.contains(.option) ? .link : .alias) }
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }
        if prefs.dragBehavior == .finder {
            return sources.allSatisfy { FileOperation.sameVolume($0, dest) } ? .move : .copy
        }
        return .move
    }

    // MARK: Create

    func newFolder(in dir: URL, name: String, moving selection: [URL] = [], window: NSWindow?) -> URL? {
        guard admit([dir] + selection, window: window), FileNaming.validate(name) == nil else { return nil }
        let u = dir.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        } catch {
            Alerts.error("Error while creating a folder", error.localizedDescription, window: window)
            return nil
        }
        if selection.isEmpty {
            history.record("Create Folder", .created([u]))
        } else {
            let pairs = selection.map { MovePair(from: $0, to: u.appendingPathComponent($0.lastPathComponent)) }
            var done: [MovePair] = []
            for p in pairs { if (try? FileManager.default.moveItem(at: p.from, to: p.to)) != nil { done.append(p) } }
            history.record("Create Folder with Selection", .composite([.created([u]), .moved(done)]))
        }
        Sounds.play(.done)
        return u
    }

    func newFile(in dir: URL, name: String, template: DocumentTemplate, window: NSWindow?) -> URL? {
        guard admit([dir], window: window), FileNaming.validate(name) == nil else { return nil }
        let u = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) {
            Alerts.error("Error saving file", String(format: "Could not create an empty file “%@” because a file with such name already exists.", name), window: window)
            return nil
        }
        do { try template.write(to: u) } catch {
            Alerts.error("Error saving file", error.localizedDescription, window: window); return nil
        }
        history.record("Create File", .created([u]))
        return u
    }

    /// Creates a file from the clipboard: text → .txt, RTF → .rtf, image → chosen format, URL → .webloc.
    func newFileFromClipboard(in dir: URL, name: String, imageType: UTType?, window: NSWindow?) -> URL? {
        guard admit([dir], window: window), FileNaming.validate(name) == nil else { return nil }
        let pb = NSPasteboard.general
        let u = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) {
            Alerts.error("Error saving file", String(format: "Could not create a file “%@” because a file with such name already exists.", name), window: window)
            return nil
        }
        do {
            if let imageType, let img = NSImage(pasteboard: pb) {
                guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    throw OpError.message("Could not read an image from the clipboard.")
                }
                let fileType: NSBitmapImageRep.FileType = imageType == .jpeg ? .jpeg : imageType == .tiff ? .tiff : imageType == .heic ? .png : .png
                guard let data = rep.representation(using: fileType, properties: [:]) else {
                    throw OpError.message("Could not convert the clipboard image to the selected format.")
                }
                try data.write(to: u, options: .withoutOverwriting)
            } else if let rtf = pb.data(forType: .rtf), u.pathExtension.lowercased() == "rtf" {
                try rtf.write(to: u, options: .withoutOverwriting)
            } else if let s = pb.string(forType: .string), let url = URL(string: s), url.scheme != nil, s.count < 2048, u.pathExtension == "webloc" {
                let d = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                try d.write(to: u, options: .withoutOverwriting)
            } else if let s = pb.string(forType: .string) {
                try Data(s.utf8).write(to: u, options: .withoutOverwriting)
            } else {
                throw OpError.message("The clipboard is empty or holds content that cannot be saved to a file.")
            }
        } catch {
            Alerts.error("Error saving file", error.localizedDescription, window: window)
            return nil
        }
        history.record("Create File from Clipboard", .created([u]))
        return u
    }

    /// Suggested extension for clipboard contents.
    static func clipboardKind() -> (ext: String, isImage: Bool)? {
        let pb = NSPasteboard.general
        if NSImage.canInit(with: pb), pb.string(forType: .string) == nil { return ("png", true) }
        if pb.data(forType: .rtf) != nil && pb.string(forType: .string) != nil { return ("rtf", false) }
        if let s = pb.string(forType: .string) {
            if let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(u.scheme ?? "") { return ("webloc", false) }
            return ("txt", false)
        }
        return nil
    }

    // MARK: Rename

    @discardableResult
    func rename(_ url: URL, to name: String, window: NSWindow?) -> URL? {
        guard admit([url], window: window) else { return nil }
        if let err = FileNaming.validate(name) {
            Alerts.error("Error while renaming", name.trimmingCharacters(in: .whitespaces).isEmpty ? String(format: "Unable to rename “%@”: The new name cannot be empty.", url.lastPathComponent) : err, window: window)
            return nil
        }
        guard name != url.lastPathComponent else { return url }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            if name.lowercased() == url.lastPathComponent.lowercased() {
                // case-only rename on case-insensitive volumes
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: tmp)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } else {
                try FileManager.default.moveItem(at: url, to: dest)
            }
        } catch {
            Alerts.error("Error while renaming", error.localizedDescription, window: window)
            return nil
        }
        history.record("Rename", .moved([MovePair(from: url, to: dest)]))
        return dest
    }

    // MARK: Misc

    func touch(_ urls: [URL]) {
        guard urls.allSatisfy(LocalFileBoundary.accepts) else { return }
        var old: [(URL, Date?)] = []
        for u in urls {
            old.append((u, try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        }
        history.record("Touch", Self.restoreDates(old))
    }

    private static func restoreDates(_ old: [(URL, Date?)]) -> UndoAction {
        .custom(name: "Touch") {
            var cur: [(URL, Date?)] = []
            for (u, d) in old {
                cur.append((u, try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
                if let d { try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path) }
            }
            return restoreDates(cur)
        }
    }

    func recordMetadataChange(_ title: String, urls: [URL], apply: @escaping () throws -> Void) {
        guard !urls.isEmpty, urls.allSatisfy(LocalFileBoundary.accepts) else { return }
        let snapshot = urls.map { ($0, Metadata.tags($0), Metadata.starRating($0)) }
        do { try apply() } catch { NSSound.beep(); return }
        history.record(title, Self.restoreMetadata(snapshot))
    }

    private static func restoreMetadata(_ snap: [(URL, [String], Int?)]) -> UndoAction {
        .custom(name: "Metadata") {
            let cur = snap.map { ($0.0, Metadata.tags($0.0), Metadata.starRating($0.0)) }
            for (u, tags, rating) in snap {
                try Metadata.setTags(u, tags)
                try Metadata.setStarRating(u, rating ?? 0)
            }
            return restoreMetadata(cur)
        }
    }
}
