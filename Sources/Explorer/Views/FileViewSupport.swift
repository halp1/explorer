import AppKit
import Darwin
import UniformTypeIdentifiers
import ExplorerKit

/// Implemented by the four file views (and the archive view).
protocol FileViewing: NSViewController {
    var state: BrowserState! { get set }
    var host: BrowserWindowController? { get set }
    func reloadItems()
    func syncSelection()
    func beginRename(_ url: URL)
    func focus()
    func setZoom(_ delta: Int)
}

extension FileViewing {
    func setZoom(_ delta: Int) {}
}

// MARK: - Drag out

enum DragOut {
    /// Pasteboard writer for an item. Archive entries become file promises extracted on drop.
    static func writer(for item: FileItem, state: BrowserState) -> NSPasteboardWriting? {
        if let address = item.mtpAddress {
            return mtpWriter(address: address, isDirectory: item.isDirectory, name: item.name, typeIdentifier: item.typeIdentifier)
        }
        if let inner = item.archivePath, let archive = state.archive {
            let type = item.isDirectory ? UTType.folder.identifier : (item.typeIdentifier ?? UTType.data.identifier)
            let p = ArchivePromiseProvider(fileType: type, delegate: ArchivePromiseDelegate.shared)
            p.userInfo = (archive, inner, item.name)
            return p
        }
        guard item.isLocalFile else { return nil }
        return item.url as NSURL
    }

    /// Also used by the tree so remote identity URLs never reach the system file clipboard.
    static func mtpWriter(address: MTPAddress, isDirectory: Bool, name: String, typeIdentifier: String?) -> NSPasteboardWriting? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        let type = isDirectory ? UTType.folder.identifier : (typeIdentifier ?? UTType.data.identifier)
        let provider = NSFilePromiseProvider(fileType: type, delegate: MTPPromiseDelegate.shared)
        provider.userInfo = (address, name)
        return provider
    }
}

final class MTPPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = MTPPromiseDelegate()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? (MTPAddress, String))?.1 ?? "Untitled"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let (address, _) = provider.userInfo as? (MTPAddress, String) else {
            completionHandler(OpError.message("Missing device item."))
            return
        }
        do {
            try LocalFileBoundary.require([url])
            let staging = try MTPOps.stagingDirectory()
            defer { MTPOps.discardEmptyStaging(staging) }
            guard let source = try MTPService.shared.download([address], to: staging, progress: { _, _ in true }).first else {
                throw OpError.message("The device did not return a file.")
            }
            // Prepare beside the promised destination, then publish atomically without replacement.
            // A failed cross-volume copy must never leave a partial promised file or folder.
            let manager = FileManager.default
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".explorer-mtp-promise-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: temporary) }
            let output = temporary.appendingPathComponent("output")
            try manager.copyItem(at: source, to: output)
            let status = output.withUnsafeFileSystemRepresentation { sourcePath in
                url.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
                }
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}

final class ArchivePromiseProvider: NSFilePromiseProvider {}

final class ArchivePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = ArchivePromiseDelegate()
    let queue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInitiated; return q }()

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (p.userInfo as? (Archive, String, String))?.2 ?? "Untitled"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let (archive, inner, _) = p.userInfo as? (Archive, String, String) else { completionHandler(nil); return }
        do {
            let tmp = try archive.extractToTemp([inner])
            let src = tmp.appendingPathComponent(inner)
            try FileManager.default.moveItem(at: src, to: url)
            try? FileManager.default.removeItem(at: tmp)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { queue }
}

// MARK: - Drop in

enum DropIn {
    private static func mtpDestination(_ dest: URL?, state: BrowserState?) -> MTPAddress? {
        // An explicit tree or selected-folder destination wins over the active tab.
        if let dest { return MTPAddress(url: dest) }
        return state?.mtpLocation
    }

    private static func hasPromises(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static let types: [NSPasteboard.PasteboardType] = [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        ((info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).filter(LocalFileBoundary.accepts)
    }

    /// Validates a drop onto `dest` (a folder URL) and returns the drag operation for the cursor.
    static func validate(_ info: NSDraggingInfo, dest: URL?, state: BrowserState?) -> NSDragOperation {
        let srcs = urls(info)
        if let address = mtpDestination(dest, state: state) {
            guard MTPOps.canWrite(address) else { return [] }
            return !srcs.isEmpty || hasPromises(info) ? .copy : []
        }
        if let dest, !LocalFileBoundary.accepts(dest) { return [] }
        if state?.isArchive == true && dest == nil {
            return (state?.archive?.isWritable ?? false) && !srcs.isEmpty ? .copy : []
        }
        guard let dest else { return [] }
        if srcs.isEmpty {
            return info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) ? .copy : []
        }
        // Not into itself or its own parent (no-op move)
        let dp = dest.standardizedFileURL.path
        if srcs.contains(where: { dp == $0.standardizedFileURL.path || dp.hasPrefix($0.standardizedFileURL.path + "/") }) { return [] }
        let mods = NSEvent.modifierFlags
        switch FileOps.shared.dropOperation(sources: srcs, dest: dest, modifiers: mods) {
        case .copy: return .copy
        case .link, .alias: return .link
        default:
            if srcs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == dp }) { return [] }
            return .move
        }
    }

    /// Performs the drop. Returns true if accepted.
    @discardableResult
    static func perform(_ info: NSDraggingInfo, dest: URL?, archiveInner: String? = nil, state: BrowserState?, window: NSWindow?) -> Bool {
        let srcs = urls(info)
        if let address = mtpDestination(dest, state: state) {
            guard MTPOps.canWrite(address) else { return false }
            if !srcs.isEmpty {
                MTPOps.upload(srcs, to: address, state: state, window: window)
                return true
            }
            guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
            do {
                for receiver in receivers {
                    let staging = try MTPOps.stagingDirectory()
                    receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: ArchivePromiseDelegate.shared.queue) { url, error in
                        DispatchQueue.main.async {
                            if let error { Alerts.error("Error receiving file", error.localizedDescription, window: window) }
                            else { MTPOps.upload([url], to: address, state: state, window: window) }
                        }
                    }
                }
                return true
            } catch {
                Alerts.error("Error receiving file", error.localizedDescription, window: window)
                return false
            }
        }
        if let dest, !LocalFileBoundary.accepts(dest) { return false }
        if let state, state.isArchive, let archive = state.archive {
            guard !srcs.isEmpty else { return false }
            ArchiveOps.add(srcs, to: archive, inner: archiveInner ?? state.archiveInner, state: state, window: window)
            return true
        }
        guard let dest else { return false }
        if srcs.isEmpty {
            // File promises (e.g. from Photos, Mail, or our own archive entries in another window)
            guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] else { return false }
            for r in receivers {
                r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: ArchivePromiseDelegate.shared.queue) { _, _ in }
            }
            return true
        }
        let kind = FileOps.shared.dropOperation(sources: srcs, dest: dest, modifiers: NSEvent.modifierFlags)
        FileOps.shared.start(kind, srcs, to: dest, window: window) { op in
            if Preferences.shared.removeShelfItemsAfterUse && kind == .move { ShelfStore.remove(srcs) }
            state?.select(urls: op.results)
        }
        return true
    }
}

// MARK: - Shared text styling

enum ItemStyle {
    static func font(_ base: CGFloat, bold: Bool = false) -> NSFont {
        let size = base + CGFloat(Preferences.shared.fontSizeDelta)
        return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    static func displayName(_ item: FileItem) -> String {
        let prefs = Preferences.shared
        switch prefs.showExtension {
        case .show: return item.isFolder ? item.displayName : item.name
        case .hide: return item.isFolder || item.isPackage && item.fileExtension == "app" ? item.displayName : (item.stem.isEmpty ? item.name : item.stem)
        case .respectFinder:
            if !item.isLocalFile { return item.name }
            return FileManager.default.displayName(atPath: item.url.path)
        }
    }

    static func truncation(_ t: Truncation) -> NSLineBreakMode {
        switch t { case .end: return .byTruncatingTail; case .middle: return .byTruncatingMiddle; case .beginning: return .byTruncatingHead; case .none: return .byClipping }
    }

    static func labelColor(_ n: Int) -> NSColor? {
        switch FinderColor(rawValue: n) {
        case .gray: return .systemGray; case .green: return .systemGreen; case .purple: return .systemPurple
        case .blue: return .systemBlue; case .yellow: return .systemYellow; case .red: return .systemRed; case .orange: return .systemOrange
        case nil: return nil
        }
    }

    static func gitColor(_ s: GitStatus) -> NSColor {
        switch s {
        case .modified: return .systemBlue; case .added: return .systemGreen; case .deleted: return .systemRed
        case .renamed, .copied: return .systemTeal; case .untracked: return .systemGray; case .conflicted: return .systemOrange; case .ignored: return .tertiaryLabelColor
        }
    }

    /// Small trailing badges: label dots, git status, cloud status.
    static func badges(_ item: FileItem) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if let c = labelColor(item.labelNumber) {
            s.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 9)]))
        }
        if let g = item.gitStatus {
            s.append(NSAttributedString(string: " " + String(g.rawValue), attributes: [.foregroundColor: gitColor(g), .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)]))
        }
        switch item.cloud {
        case .notDownloaded: s.append(symbol("icloud.and.arrow.down"))
        case .downloading: s.append(symbol("arrow.down.circle"))
        case .uploading, .notUploaded: s.append(symbol("icloud.and.arrow.up"))
        default: break
        }
        return s
    }

    static func symbol(_ name: String) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        let s = NSMutableAttributedString(string: " ")
        s.append(NSAttributedString(attachment: a))
        return s
    }

    static func dateDisplay() -> DateDisplay {
        let p = Preferences.shared
        return DateDisplay(length: p.dateLength, mode: p.dateMode, showTime: p.showTimeInDates)
    }
}
