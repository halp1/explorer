import AppKit
import ExplorerKit

/// UI-level archive workflows with progress and undo.
enum ArchiveOps {
    /// Shows the malware warning (unless dismissed forever) and asks for the archive password.
    static func askPassword(for url: URL, window: NSWindow?) -> String? {
        let prefs = Preferences.shared
        if prefs.warnPasswordArchives {
            let a = NSAlert()
            a.messageText = "Archive Locked"
            a.informativeText = "Password-protected archives are often used to distribute malware. Before proceeding, make sure you received this archive from a trusted source."
            a.alertStyle = .warning
            a.addButton(withTitle: "Proceed")
            a.addButton(withTitle: "Proceed and Don’t Warn Again")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: prefs.warnPasswordArchives = false
            default: return nil
            }
        }
        return Alerts.prompt("Archive password", message: String(format: "Enter the password for “%@”:", url.lastPathComponent), ok: "OK", selectStem: false, secure: true)
    }

    /// Runs `work` on a background queue with a progress sheet. `work` gets a progress callback returning false to cancel.
    static func run(_ title: String, window: NSWindow?, work: @escaping (@escaping ArchiveProgress) throws -> Void, done: @escaping (Error?) -> Void) {
        let sheet = ProgressSheet(title: title)
        if let window { window.beginSheet(sheet.window!) } else { sheet.showWindow(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            var err: Error?
            do {
                try work { f, name in
                    DispatchQueue.main.async { sheet.update(f, name) }
                    return !sheet.cancelled
                }
            } catch { err = error }
            DispatchQueue.main.async {
                if let window { window.endSheet(sheet.window!) } else { sheet.close() }
                if let err, !(err is OpError) { Sounds.play(.error) } else if err == nil { Sounds.play(.done) }
                done(err)
            }
        }
    }

    static func compress(_ urls: [URL], format: ArchiveFormat, protected: Bool, state: BrowserState?, window: NSWindow?) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        var password: String?
        if protected {
            guard let pw = Alerts.prompt("Set Archive Password", message: "", ok: "Compress", selectStem: false, secure: true), !pw.isEmpty else { return }
            password = pw
        }
        var fmt = format
        if urls.count == 1, !Archive.isDirectory(first), let single = format.singleFileEquivalent { fmt = single }
        let base = urls.count == 1 ? (fmt.isSingleStream ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent) : "Archive"
        let dest = FileNaming.uniqueURL(in: dir, name: base + "." + fmt.fileExtension)
        run("Compressing...", window: window, work: { p in
            try Archive.create(at: dest, format: format, items: urls, password: password, progress: p)
        }, done: { err in
            if let err {
                try? FileManager.default.removeItem(at: dest)
                if !(err is OpError) { Alerts.error("Error while adding to archive", err.localizedDescription, window: window) }
                return
            }
            FileOps.shared.history.record("Compress", .created([dest]))
            Preferences.shared.lastCompressFormat = format.rawValue
            state?.pendingSelection = [dest]
            state?.softReload()
            if Preferences.shared.removeShelfItemsAfterUse { ShelfStore.remove(urls) }
        })
    }

    /// Extracts archives next to themselves into a new folder named after the archive.
    static func extractHere(_ archives: [URL], state: BrowserState?, window: NSWindow?) {
        for u in archives {
            guard let a = try? Archive(url: u) else { continue }
            do { try a.load() } catch ArchiveError.passwordRequired {
                guard let pw = askPassword(for: u, window: window) else { continue }
                a.password = pw
            } catch {
                Alerts.error("Error while extracting an archive entry", error.localizedDescription, window: window); continue
            }
            let dir = state?.currentDirectory ?? u.deletingLastPathComponent()
            let name = ArchiveFormat.baseName(u.lastPathComponent)
            // A single top-level item (or single stream) extracts directly; otherwise into a folder.
            let tops = Set(a.entries.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
            let single = tops.count == 1 || a.format.isSingleStream
            let dest = single ? dir : FileNaming.uniqueURL(in: dir, name: name, isDirectory: true)
            let staging = AppPaths.temp.appendingPathComponent("extract-" + UUID().uuidString, isDirectory: true)
            run("Extracting archive...", window: window, work: { p in
                try a.extract([], to: single ? staging : dest, progress: p)
            }, done: { err in
                if let err {
                    if !(err is OpError) { Alerts.error("Error while extracting an archive entry", err.localizedDescription, window: window) }
                    return
                }
                var created: [URL] = []
                if single {
                    for c in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                        let t = FileNaming.uniqueURL(in: dest, name: c.lastPathComponent, isDirectory: c.hasDirectoryPath)
                        if (try? FileManager.default.moveItem(at: c, to: t)) != nil { created.append(t) }
                    }
                    try? FileManager.default.removeItem(at: staging)
                } else { created = [dest] }
                FileOps.shared.history.record("Extract Archive", .created(created))
                state?.pendingSelection = created
                state?.softReload()
            })
        }
    }

    /// Extracts entries (empty = all) of the open archive into a new folder next to it.
    static func extractEntries(_ paths: [String], state: BrowserState, window: NSWindow?) {
        guard let a = state.archive else { return }
        let dir = a.url.deletingLastPathComponent()
        let dest = FileNaming.uniqueURL(in: dir, name: ArchiveFormat.baseName(a.url.lastPathComponent), isDirectory: true)
        let strip = state.archiveInner
        run("Extracting archive...", window: window, work: { p in
            try a.extract(paths, to: dest, stripPrefix: strip, progress: p)
        }, done: { err in
            if let err { if !(err is OpError) { Alerts.error("Error while extracting an archive entry", err.localizedDescription, window: window) }; return }
            FileOps.shared.history.record("Extract Archive", .created([dest]))
            Sounds.play(.done)
            AppDelegate.shared.reveal(dest)
        })
    }

    static func add(_ urls: [URL], to a: Archive, inner: String, state: BrowserState?, window: NSWindow?) {
        guard !urls.isEmpty else { return }
        guard a.isWritable else { Alerts.error("Error while adding to archive", "This archive format is read-only.", window: window); return }
        let backup = AppPaths.temp.appendingPathComponent("archive-backup-" + UUID().uuidString + "-" + a.url.lastPathComponent)
        try? FileManager.default.copyItem(at: a.url, to: backup)
        run("Adding entries to archive...", window: window, work: { p in
            try a.add(urls, into: inner, progress: p)
        }, done: { err in
            if let err { if !(err is OpError) { Alerts.error("Error while adding to archive", err.localizedDescription, window: window) }; return }
            FileOps.shared.history.record("Add Entries to Archive", restore(a, from: backup))
            state?.reloadArchive()
        })
    }

    static func remove(_ paths: [String], from a: Archive, state: BrowserState?, window: NSWindow?) {
        guard !paths.isEmpty else { return }
        guard a.isWritable else { Alerts.error("Error while trashing an archive entry", "This archive format is read-only.", window: window); return }
        let backup = AppPaths.temp.appendingPathComponent("archive-backup-" + UUID().uuidString + "-" + a.url.lastPathComponent)
        try? FileManager.default.copyItem(at: a.url, to: backup)
        run("Removing entries from archive...", window: window, work: { p in
            try a.remove(paths, progress: p)
        }, done: { err in
            if let err { if !(err is OpError) { Alerts.error("Error while trashing an archive entry", err.localizedDescription, window: window) }; return }
            FileOps.shared.history.record("Move from Archive to Trash", restore(a, from: backup))
            state?.reloadArchive()
        })
    }

    /// Undo for archive edits: swap the archive file with a backup copy.
    static func restore(_ a: Archive, from backup: URL) -> UndoAction {
        .custom(name: "Archive") {
            let swap = AppPaths.temp.appendingPathComponent("archive-backup-" + UUID().uuidString + "-" + a.url.lastPathComponent)
            try FileManager.default.copyItem(at: a.url, to: swap)
            _ = try FileManager.default.replaceItemAt(a.url, withItemAt: backup)
            try? a.load()
            NotificationCenter.default.post(name: .viewSettingsChanged, object: nil)
            return restore(a, from: swap)
        }
    }
}

/// Simple modal progress sheet with Cancel.
final class ProgressSheet: NSWindowController {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private(set) var cancelled = false

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: w)
        let t = NSTextField(labelWithString: title); t.font = .boldSystemFont(ofSize: 13)
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(doCancel))
        cancel.keyEquivalent = "\u{1b}"
        let s = NSStackView(views: [t, bar, label, cancel])
        s.orientation = .vertical; s.alignment = .leading
        s.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        bar.widthAnchor.constraint(equalToConstant: 344).isActive = true
        label.widthAnchor.constraint(equalToConstant: 344).isActive = true
        w.contentView = s
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ f: Double, _ name: String) { bar.doubleValue = f; if !name.isEmpty { label.stringValue = name } }
    @objc private func doCancel() { cancelled = true; label.stringValue = "Cancelling..." }
}

enum DeviceOps {
    static func upload(_ files: [URL], udid: String, path: String, state: BrowserState, window: NSWindow?) {
        guard !files.isEmpty else { return }
        ArchiveOps.run(String(format: files.count == 1 ? "Copying %llu item..." : "Copying %llu items...", UInt64(files.count)), window: window, work: { p in
            try IDeviceRegistry.shared.upload(udid: udid, files: files, to: path) { n in _ = p(0.5, n) }
        }, done: { err in
            if let err { Alerts.error("Error while copying", err.localizedDescription, window: window) }
            state.reload()
        })
    }
}
