import Foundation
import Darwin

// MARK: - Conflicts

public enum ConflictDecision: Equatable, Sendable {
    case skip, keepBoth, replace, replaceOlder, merge, cancel
}

public struct Conflict: Sendable {
    public var source: URL
    public var existing: URL
    public var isFolder: Bool
    public var sourceModified: Date?
    public var existingModified: Date?
    public var sourceSize: Int64?
    public var existingSize: Int64?
    public var remaining: Int   // how many more top-level items after this one (to offer "Apply to All")
}

/// Answer from the UI; `applyToAll` makes the decision sticky for the rest of the operation
/// (separately for files and for folders).
public struct ConflictAnswer: Sendable {
    public var decision: ConflictDecision
    public var applyToAll: Bool
    public init(_ decision: ConflictDecision, applyToAll: Bool = false) { self.decision = decision; self.applyToAll = applyToAll }
}

/// Called on the operation's worker thread; may block (e.g. while a sheet is shown).
public typealias ConflictResolver = (Conflict) -> ConflictAnswer

// MARK: - Operation

public enum FileOperationKind: String, Sendable {
    case copy, move, duplicate, trash, delete, link, alias
    public var progressTitle: String {
        switch self {
        case .copy: return "Copying..."
        case .move: return "Moving..."
        case .duplicate: return "Duplicating..."
        case .trash: return "Moving to Trash..."
        case .delete: return "Deleting..."
        case .link: return "Creating symlinks..."
        case .alias: return "Creating aliases..."
        }
    }
    public var undoTitle: String {
        switch self {
        case .copy: return "Copy"; case .move: return "Move"; case .duplicate: return "Duplicate"
        case .trash: return "Move to Trash"; case .delete: return "Delete"; case .link: return "Create Symlinks"; case .alias: return "Create Aliases"
        }
    }
}

public enum OperationState: Equatable, Sendable { case preparing, running, paused, finishing, done, cancelled, failed(String) }

/// One long-running file operation with progress, pause/resume and cancellation.
/// Observable on the main thread; work happens on a private thread.
public final class FileOperation: ObservableObject, Identifiable {
    public let id = UUID()
    public let kind: FileOperationKind
    public let sources: [URL]
    public let destination: URL?

    @Published public private(set) var state: OperationState = .preparing
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var completedBytes: Int64 = 0
    @Published public private(set) var totalItems: Int = 0
    @Published public private(set) var completedItems: Int = 0
    @Published public private(set) var currentName: String = ""
    @Published public private(set) var errors: [String] = []

    public var fractionCompleted: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return Double(completedItems) / Double(totalItems) }
        return 0
    }

    /// The resulting top-level items (for selection after completion).
    public private(set) var results: [URL] = []
    public private(set) var undo: UndoAction?

    public var resolver: ConflictResolver = { _ in ConflictAnswer(.keepBoth) }
    public var errorHandler: ((Error, URL) -> Bool)?  // return true to continue, false to abort
    public var onFinish: ((FileOperation) -> Void)?
    public var trasher = Trasher()

    private var cancelled = false
    private let pauseLock = NSCondition()
    private var paused = false
    private var stickyFile: ConflictDecision?
    private var stickyFolder: ConflictDecision?
    private var bytesSinceUpdate: Int64 = 0
    private var lastUpdate = Date.distantPast
    private var created: [URL] = []
    private var moved: [MovePair] = []
    private var trashedReplaced: [MovePair] = []

    public init(kind: FileOperationKind, sources: [URL], destination: URL?) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    // MARK: Control

    public func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "FileOperation.\(kind.rawValue)"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Runs synchronously on the calling thread (tests, scripting).
    public func runSync() { run() }

    public func cancel() {
        cancelled = true
        resume()
    }

    public func pause() {
        pauseLock.lock(); paused = true; pauseLock.unlock()
        publish { $0.state = .paused }
    }

    public func resume() {
        pauseLock.lock(); paused = false; pauseLock.broadcast(); pauseLock.unlock()
        publish { if $0.state == .paused { $0.state = .running } }
    }

    public var isFinished: Bool {
        switch state { case .done, .cancelled, .failed: return true; default: return false }
    }

    private func checkpoint() throws {
        pauseLock.lock()
        while paused && !cancelled { pauseLock.wait() }
        pauseLock.unlock()
        if cancelled { throw OpError.cancelled }
    }

    // MARK: Publishing

    private func publish(_ f: @escaping (FileOperation) -> Void) {
        if Thread.isMainThread { f(self) } else { DispatchQueue.main.async { f(self) } }
    }

    private func publishProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) > 0.1 else { return }
        lastUpdate = now
        let b = bytesSinceUpdate
        bytesSinceUpdate = 0
        publish { $0.completedBytes += b }
    }

    // MARK: Run

    private func run() {
        do {
            // Reject remote identities before measuring sources or touching any destination.
            try LocalFileBoundary.require(sources + (destination.map { [$0] } ?? []))
            try prepare()
            publish { $0.state = .running }
            switch kind {
            case .copy: try transfer(move: false)
            case .move: try transfer(move: true)
            case .duplicate: try duplicate()
            case .trash: try trashAll()
            case .delete: try deleteAll()
            case .link, .alias: try link(alias: kind == .alias)
            }
            publishProgress(force: true)
            finish(.done)
        } catch OpError.cancelled {
            finish(.cancelled)
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }

    private func finish(_ s: OperationState) {
        var parts: [UndoAction] = []
        if !trashedReplaced.isEmpty { parts.append(.trashed(trashedReplaced)) }
        if !moved.isEmpty { parts.append(.moved(moved)) }
        if !created.isEmpty { parts.append(.created(created)) }
        undo = parts.isEmpty ? nil : (parts.count == 1 ? parts[0] : .composite(parts))
        let r = results
        DispatchQueue.main.async {
            self.results = r
            self.state = s
            self.onFinish?(self)
        }
    }

    private func prepare() throws {
        var bytes: Int64 = 0
        var items = 0
        if kind == .copy || kind == .duplicate || (kind == .move && !sameVolumeForAll()) {
            for s in sources {
                try checkpoint()
                let (b, n) = Self.measure(s)
                bytes += b; items += n
            }
        } else {
            items = sources.count
        }
        let b = bytes, n = items
        publish { $0.totalBytes = b; $0.totalItems = n }
    }

    private func sameVolumeForAll() -> Bool {
        guard let d = destination else { return true }
        return sources.allSatisfy { Self.sameVolume($0, d) }
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard LocalFileBoundary.accepts(a), LocalFileBoundary.accepts(b) else { return false }
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0 else { return false }
        // Nearest existing ancestor of the destination decides its volume.
        guard b.selfAndAncestors.contains(where: { stat($0.path, &sb) == 0 }) else { return false }
        return sa.st_dev == sb.st_dev
    }

    /// Total bytes and item count under `url` (no symlink following).
    public static func measure(_ url: URL) -> (Int64, Int) {
        guard LocalFileBoundary.accepts(url) else { return (0, 0) }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return (0, 0) }
        if (st.st_mode & S_IFMT) != S_IFDIR { return (Int64(st.st_size), 1) }
        var bytes: Int64 = 0, n = 1
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            for case let u as URL in e {
                n += 1
                if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                    bytes += Int64(v.fileSize ?? 0)
                }
            }
        }
        return (bytes, n)
    }

    // MARK: Copy / Move

    private func transfer(move: Bool) throws {
        guard let dest = destination else { return }
        for (i, src) in sources.enumerated() {
            try checkpoint()
            let srcStd = src.standardizedFileURL.resolvingSymlinksInPath()
            let destStd = dest.standardizedFileURL.resolvingSymlinksInPath()
            if destStd.path == srcStd.path || destStd.path.hasPrefix(srcStd.path + "/") {
                if !reportError(OpError.intoItself(src), src) { throw OpError.cancelled }
                continue
            }
            var target = dest.appendingPathComponent(src.lastPathComponent)
            publish { $0.currentName = src.lastPathComponent }
            if src.deletingLastPathComponent().standardizedFileURL.path == dest.standardizedFileURL.path {
                if move { continue }  // moving onto itself is a no-op
                target = FileNaming.uniqueURL(in: dest, name: src.lastPathComponent, isDirectory: isDir(src))
            }
            if let placed = try place(src, at: target, move: move, remaining: sources.count - i - 1) {
                results.append(placed)
            }
        }
    }

    /// Places `src` at `target` resolving conflicts. Returns the final URL or nil if skipped.
    private func place(_ src: URL, at target: URL, move: Bool, remaining: Int) throws -> URL? {
        var target = target
        if FileNaming.defaultExists(target) {
            let srcIsDir = isDir(src), dstIsDir = isDir(target)
            let decision = try decide(src: src, existing: target, folder: srcIsDir && dstIsDir, remaining: remaining)
            switch decision {
            case .skip:
                countSkipped(src)
                return nil
            case .cancel:
                throw OpError.cancelled
            case .keepBoth:
                target = FileNaming.uniqueURL(in: target.deletingLastPathComponent(), name: target.lastPathComponent, isDirectory: srcIsDir)
            case .replaceOlder:
                let sm = modDate(src), dm = modDate(target)
                if let sm, let dm, dm >= sm { countSkipped(src); return nil }
                try replaceExisting(target)
            case .replace:
                try replaceExisting(target)
            case .merge:
                if srcIsDir && dstIsDir {
                    try merge(src, into: target, move: move)
                    return target
                }
                try replaceExisting(target)
            }
        }
        if move {
            try moveItem(src, to: target)
        } else {
            try copyItem(src, to: target)
            created.append(target)
        }
        return target
    }

    private func merge(_ srcDir: URL, into dstDir: URL, move: Bool) throws {
        let children = (try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)) ?? []
        for c in children {
            try checkpoint()
            _ = try place(c, at: dstDir.appendingPathComponent(c.lastPathComponent), move: move, remaining: 1)
        }
        if move, ((try? FileManager.default.contentsOfDirectory(atPath: srcDir.path)) ?? ["x"]).isEmpty {
            try? FileManager.default.removeItem(at: srcDir)
        }
    }

    private func decide(src: URL, existing: URL, folder: Bool, remaining: Int) throws -> ConflictDecision {
        if folder, let s = stickyFolder { return s }
        if !folder, let s = stickyFile { return s }
        let c = Conflict(source: src, existing: existing, isFolder: folder,
                         sourceModified: modDate(src), existingModified: modDate(existing),
                         sourceSize: Self.measure(src).0, existingSize: Self.measure(existing).0, remaining: remaining)
        let a = resolver(c)
        if a.applyToAll { if folder { stickyFolder = a.decision } else { stickyFile = a.decision } }
        return a.decision
    }

    private func replaceExisting(_ url: URL) throws {
        let t = try trasher.trash(url)
        trashedReplaced.append(MovePair(from: url, to: t))
    }

    private func countSkipped(_ src: URL) {
        let (b, n) = Self.measure(src)
        bytesSinceUpdate += b
        publish { $0.completedItems += n }
    }

    private func moveItem(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if Self.sameVolume(src, dst.deletingLastPathComponent()) {
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                if !reportError(error, src) { throw OpError.cancelled }
                return
            }
            moved.append(MovePair(from: src, to: dst))
            publish { $0.completedItems += 1 }
        } else {
            // Cross-volume: copy then remove source.
            try copyItem(src, to: dst)
            do {
                try fm.removeItem(at: src)
                moved.append(MovePair(from: src, to: dst))
            } catch {
                created.append(dst)
                _ = reportError(error, src)
            }
        }
    }

    // MARK: copyfile with progress

    private final class CopyContext {
        weak var op: FileOperation?
        var lastCopied: off_t = 0
        init(_ op: FileOperation) { self.op = op }
    }

    private func copyItem(_ src: URL, to dst: URL) throws {
        try checkpoint()
        guard let state = copyfile_state_alloc() else { throw OpError.message("copyfile_state_alloc failed") }
        defer { copyfile_state_free(state) }
        let ctx = CopyContext(self)
        let ctxPtr = Unmanaged.passRetained(ctx)
        defer { ctxPtr.release() }
        let cb: copyfile_callback_t = { what, stage, state, src, dst, ctxRaw in
            guard let ctxRaw else { return COPYFILE_CONTINUE }
            let ctx = Unmanaged<CopyContext>.fromOpaque(ctxRaw).takeUnretainedValue()
            guard let op = ctx.op else { return COPYFILE_QUIT }
            if op.cancelled { return COPYFILE_QUIT }
            if op.paused {
                op.pauseLock.lock()
                while op.paused && !op.cancelled { op.pauseLock.wait() }
                op.pauseLock.unlock()
                if op.cancelled { return COPYFILE_QUIT }
            }
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                op.bytesSinceUpdate += Int64(copied - ctx.lastCopied)
                ctx.lastCopied = copied
                op.publishProgress()
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START {
                ctx.lastCopied = 0
                if let src { let n = (String(cString: src) as NSString).lastPathComponent; DispatchQueue.main.async { op.currentName = n } }
            } else if (what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR) && stage == COPYFILE_FINISH {
                DispatchQueue.main.async { op.completedItems += 1 }
            } else if stage == COPYFILE_ERR {
                return COPYFILE_SKIP
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctxPtr.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_CLONE | COPYFILE_EXCL)
        let r = copyfile(src.path, dst.path, state, flags)
        if cancelled {
            try? FileManager.default.removeItem(at: dst)
            throw OpError.cancelled
        }
        if r != 0 {
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: src.path])
            if !reportError(err, src) { throw OpError.cancelled }
        }
        if !isDir(src) { publish { $0.completedItems += 1 } }
        publishProgress(force: true)
    }

    // MARK: Duplicate

    private func duplicate() throws {
        for s in sources {
            try checkpoint()
            let d = FileNaming.duplicateURL(for: s)
            publish { $0.currentName = s.lastPathComponent }
            try copyItem(s, to: d)
            created.append(d)
            results.append(d)
        }
    }

    // MARK: Trash / delete

    private func trashAll() throws {
        for s in sources {
            try checkpoint()
            publish { $0.currentName = s.lastPathComponent }
            do {
                let t = try trasher.trash(s)
                // Record each receipt immediately so cancelling a later item cannot discard it.
                trashedReplaced.append(MovePair(from: s, to: t))
                results.append(t)
            } catch {
                if !reportError(error, s) { break }
            }
            publish { $0.completedItems += 1 }
        }
    }

    private func deleteAll() throws {
        for s in sources {
            try checkpoint()
            publish { $0.currentName = s.lastPathComponent }
            do { try FileManager.default.removeItem(at: s) } catch { if !reportError(error, s) { break } }
            publish { $0.completedItems += 1 }
        }
    }

    // MARK: Links

    private func link(alias: Bool) throws {
        guard let dest = destination else { return }
        for s in sources {
            try checkpoint()
            let name = alias ? s.lastPathComponent + " alias" : s.lastPathComponent
            let target = FileNaming.uniqueURL(in: dest, name: name, isDirectory: false)
            do {
                if alias {
                    let data = try s.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try URL.writeBookmarkData(data, to: target)
                } else {
                    guard FileNaming.defaultExists(s) else {
                        throw OpError.message(String(format: "Couldn’t not create the symbolic link because the file “%@” doesn’t exist", s.lastPathComponent))
                    }
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: s)
                }
                created.append(target)
                results.append(target)
            } catch {
                if !reportError(error, s) { break }
            }
            publish { $0.completedItems += 1 }
        }
    }

    // MARK: Helpers

    private func reportError(_ e: Error, _ u: URL) -> Bool {
        let msg = e.localizedDescription
        publish { $0.errors.append(msg) }
        return errorHandler?(e, u) ?? true
    }

    private func isDir(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func modDate(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
