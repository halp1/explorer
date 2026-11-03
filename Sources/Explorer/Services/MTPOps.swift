import AppKit
import ExplorerKit

/// UI coordinator for copy-only MTP transfers. Staged outputs live for the app lifetime.
enum MTPOps {
    private static let queue = DispatchQueue(label: "explorer.mtp.operations", qos: .userInitiated)
    private static let stagingMaintenance: Void = {
        queue.async {
            let manager = FileManager.default
            let root = AppPaths.temp
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix("MTP-"), UUID(uuidString: String(name.dropFirst(4))) != nil,
                      let attributes = try? manager.attributesOfItem(atPath: entry.path),
                      attributes[.type] as? FileAttributeType == .typeDirectory,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
                try? manager.removeItem(at: entry)
            }
        }
    }()

    static func canWrite(_ address: MTPAddress) -> Bool {
        address.storageID != nil && MTPService.shared.canWrite(address)
    }

    static func canMutate(_ address: MTPAddress) -> Bool {
        address.objectID != nil && address.parent.map(canWrite) == true
    }

    static func stagingDirectory() throws -> URL {
        // Maintenance runs once at first use, before any current-launch directory can be old.
        _ = stagingMaintenance
        let dir = AppPaths.temp.appendingPathComponent("MTP-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func discardEmptyStaging(_ directory: URL) {
        guard directory.deletingLastPathComponent().standardizedFileURL == AppPaths.temp.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("MTP-"),
              let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func stage(_ addresses: [MTPAddress], window: NSWindow?, onFailure: (() -> Void)? = nil, completion: @escaping ([URL]) -> Void) {
        guard !addresses.isEmpty else { return }
        run("Downloading...", window: window, work: { progress in
            let directory = try stagingDirectory()
            do { return try MTPService.shared.download(addresses, to: directory, progress: progress) }
            catch {
                discardEmptyStaging(directory)
                throw error
            }
        }) { result in
            switch result {
            case .success(let urls): completion(urls)
            case .failure(let error):
                onFailure?()
                report(error, title: "Error while downloading", window: window)
            }
        }
    }

    static func copy(_ addresses: [MTPAddress], window: NSWindow?) {
        stage(addresses, window: window) { FileOps.shared.copy($0) }
    }

    static func upload(_ files: [URL], to address: MTPAddress, state: BrowserState?, window: NSWindow?) {
        guard !files.isEmpty, files.allSatisfy(LocalFileBoundary.accepts), canWrite(address) else { return }
        run("Copying to Device...", window: window, work: { progress in
            try LocalFileBoundary.require(files)
            try MTPService.shared.upload(files, to: address, progress: progress)
        }) { result in
            if case .failure(let error) = result { report(error, title: "Error while copying", window: window) }
            changed(state)
        }
    }

    static func rename(_ address: MTPAddress, to name: String, state: BrowserState?, window: NSWindow?) {
        guard canMutate(address), validName(name, window: window) else { return }
        run("Renaming...", window: window, work: { progress in
            guard progress(0, name) else { throw OpError.cancelled }
            try MTPService.shared.rename(address, to: name)
        }) { result in
            if case .failure(let error) = result { report(error, title: "Error while renaming", window: window) }
            changed(state)
        }
    }

    static func newFolder(in address: MTPAddress, state: BrowserState?, window: NSWindow?) {
        guard canWrite(address),
              let name = Alerts.prompt("New Folder", message: "", defaultValue: "untitled folder", ok: "Create", selectStem: false),
              validName(name, window: window) else { return }
        run("Creating Folder...", window: window, work: { progress in
            guard progress(0, name) else { throw OpError.cancelled }
            try MTPService.shared.makeDirectory(name, in: address)
        }) { result in
            if case .failure(let error) = result { report(error, title: "Error while creating a folder", window: window) }
            changed(state)
        }
    }

    static func remove(_ addresses: [MTPAddress], state: BrowserState?, window: NSWindow?) {
        guard !addresses.isEmpty, addresses.allSatisfy(canMutate) else { return }
        let title = addresses.count == 1 ? "Permanently Delete “\(addresses[0].title)”?" : "Permanently Delete Selected Items?"
        guard Alerts.confirm(title, "This action is immediate and cannot be undone.", ok: "Delete", destructive: true) else { return }
        run("Deleting...", window: window, work: { progress in
            try MTPService.shared.remove(addresses, progress: progress)
        }) { result in
            if case .failure(let error) = result { report(error, title: "Error while deleting", window: window) }
            changed(state)
        }
    }

    private static func validName(_ name: String, window: NSWindow?) -> Bool {
        if let error = FileNaming.validate(name) {
            Alerts.error("Invalid Name", error, window: window)
            return false
        }
        return true
    }

    private static func changed(_ state: BrowserState?) {
        state?.reload()
        NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
    }

    private static func report(_ error: Error, title: String, window: NSWindow?) {
        if case OpError.cancelled = error { return }
        Alerts.error(title, error.localizedDescription, window: window)
    }

    private static func run<T>(_ title: String, window: NSWindow?,
                               work: @escaping (@escaping (Double, String) -> Bool) throws -> T,
                               completion: @escaping (Result<T, Error>) -> Void) {
        let sheet = MTPProgressSheet(title: title)
        if let parent = window, let child = sheet.window, parent.attachedSheet == nil {
            parent.beginSheet(child)
        } else {
            sheet.showWindow(nil)
        }
        queue.async {
            let result = Result { try work { fraction, name in sheet.progress(fraction, name) } }
            DispatchQueue.main.async {
                if let child = sheet.window, let parent = child.sheetParent { parent.endSheet(child) }
                sheet.close()
                completion(result)
            }
        }
    }
}

/// Cancellation is read by libmtp's worker callback and written only through the lock.
private final class MTPProgressSheet: NSWindowController {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let lock = NSLock()
    private var cancelled = false
    private var lastUpdate = Date.distantPast

    init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTransfer))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [heading, bar, label, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        bar.widthAnchor.constraint(equalToConstant: 344).isActive = true
        label.widthAnchor.constraint(equalToConstant: 344).isActive = true
        window.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    func progress(_ fraction: Double, _ name: String) -> Bool {
        lock.lock()
        let keepGoing = !cancelled
        let now = Date()
        let update = keepGoing && (fraction >= 1 || now.timeIntervalSince(lastUpdate) > 0.1)
        if update { lastUpdate = now }
        lock.unlock()
        if update {
            DispatchQueue.main.async { [self] in
                lock.lock()
                let active = !cancelled
                lock.unlock()
                guard active else { return }
                bar.doubleValue = fraction.isFinite ? min(1, max(0, fraction)) : 0
                label.stringValue = name
            }
        }
        return keepGoing
    }

    @objc private func cancelTransfer() {
        lock.lock()
        cancelled = true
        lock.unlock()
        label.stringValue = "Cancelling..."
    }
}
