import Foundation

public struct MovePair: Hashable, Sendable {
    public var from: URL
    public var to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
    public var swapped: MovePair { MovePair(from: to, to: from) }
}

/// A reversible record of a completed file operation. Performing an undo returns the inverse
/// record, which becomes the redo entry (and vice versa).
public indirect enum UndoAction {
    /// Items that came into existence. Undo = move them to the Trash.
    case created([URL])
    /// Items moved/renamed. Undo = move each `to` back to `from`.
    case moved([MovePair])
    /// Items moved to the (system or private) Trash. `from` = original, `to` = location in trash. Undo = restore.
    case trashed([MovePair])
    /// Several actions performed in order. Undo reverses them in reverse order.
    case composite([UndoAction])
    /// Arbitrary reversible change (metadata, permissions, archive edits...).
    case custom(name: String, undo: () throws -> UndoAction)

    public var isEmpty: Bool {
        switch self {
        case .created(let u): return u.isEmpty
        case .moved(let p), .trashed(let p): return p.isEmpty
        case .composite(let a): return a.allSatisfy(\.isEmpty)
        case .custom: return false
        }
    }

    /// Performs the undo and returns the inverse action. Built-in actions roll back completed
    /// steps on failure. A custom closure must leave its own state unchanged when it throws.
    public func perform(trash: Trasher = Trasher()) throws -> UndoAction {
        try performStep(trash: trash).inverse
    }

    /// Rollback preserves exact trash paths, unlike a normal redo which may choose a new bucket.
    private func performStep(trash: Trasher) throws -> (inverse: UndoAction, rollback: UndoAction) {
        let fm = FileManager.default
        var rollbacks: [UndoAction] = []
        do {
            switch self {
            case .created(let urls):
                var pairs: [MovePair] = []
                for u in urls.reversed() where FileNaming.defaultExists(u) {
                    let t = try trash.trash(u)
                    let pair = MovePair(from: u, to: t)
                    pairs.append(pair)
                    rollbacks.append(.moved([pair]))
                }
                return (.trashed(pairs), .composite(rollbacks))
            case .moved(let pairs):
                // Preflight before staging anything, including all sources of swaps and cycles.
                let vacating = Set(pairs.map { $0.to.standardizedFileURL.path })
                for p in pairs {
                    if FileNaming.defaultExists(p.from) && !vacating.contains(p.from.standardizedFileURL.path) {
                        throw OpError.undoConflict(p.from)
                    }
                    _ = try fm.attributesOfItem(atPath: p.to.path)
                }
                var staged: [(MovePair, URL)] = []
                for p in pairs.reversed() {
                    let tmp = p.to.deletingLastPathComponent().appendingPathComponent(".explorer-undo-\(UUID().uuidString)")
                    try fm.moveItem(at: p.to, to: tmp)
                    rollbacks.append(.moved([MovePair(from: p.to, to: tmp)]))
                    staged.append((p, tmp))
                }
                var done: [MovePair] = []
                for (p, tmp) in staged {
                    try fm.createDirectory(at: p.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: p.from)
                    rollbacks.append(.moved([MovePair(from: tmp, to: p.from)]))
                    done.append(p.swapped)
                }
                let inverse = UndoAction.moved(done.reversed())
                return (inverse, inverse)
            case .trashed(let pairs):
                // A late conflict must not restore only part of a multi-item deletion.
                for p in pairs {
                    if FileNaming.defaultExists(p.from) { throw OpError.undoConflict(p.from) }
                    _ = try fm.attributesOfItem(atPath: p.to.path)
                }
                var restored: [URL] = []
                for p in pairs.reversed() {
                    try fm.createDirectory(at: p.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: p.to, to: p.from)
                    rollbacks.append(.moved([p.swapped]))
                    restored.append(p.from)
                }
                return (.created(restored), .composite(rollbacks))
            case .composite(let actions):
                var inverses: [UndoAction] = []
                for action in actions.reversed() {
                    let step = try action.performStep(trash: trash)
                    inverses.append(step.inverse)
                    rollbacks.append(step.rollback)
                }
                return (.composite(inverses), .composite(rollbacks))
            case .custom(_, let undo):
                let inverse = try undo()
                return (inverse, inverse)
            }
        } catch {
            throw rollback(after: error, steps: rollbacks, trash: trash)
        }
    }

    private func rollback(after error: Error, steps: [UndoAction], trash: Trasher) -> Error {
        var pending = steps
        if let recovery = error as? UndoRecoveryError { pending.append(recovery.rollback) }
        var cause = error
        while let recovery = cause as? UndoRecoveryError { cause = recovery.cause }
        while let action = pending.last {
            do {
                _ = try action.perform(trash: trash)
                pending.removeLast()
            } catch let rollbackError {
                if let recovery = rollbackError as? UndoRecoveryError {
                    pending[pending.count - 1] = recovery.retrying(action, trash: trash)
                }
                return UndoRecoveryError(cause: cause, rollback: .composite(pending))
            }
        }
        return cause
    }

    /// URLs touched by this action (used to refresh views after undo).
    public var affectedURLs: [URL] {
        switch self {
        case .created(let u): return u
        case .moved(let p), .trashed(let p): return p.flatMap { [$0.from, $0.to] }
        case .composite(let a): return a.flatMap(\.affectedURLs)
        case .custom: return []
        }
    }
}

/// Carries unfinished rollback work so history can recover without repeating completed moves.
private struct UndoRecoveryError: LocalizedError {
    let cause: Error
    let rollback: UndoAction

    var errorDescription: String? {
        cause.localizedDescription + " Some changes could not be rolled back. Resolve the conflict and retry."
    }

    func retrying(_ action: UndoAction, trash: Trasher) -> UndoAction {
        var pendingRollback: UndoAction? = rollback
        return .custom(name: "Recover Undo", undo: {
            if let pending = pendingRollback {
                _ = try pending.perform(trash: trash)
                pendingRollback = nil
            }
            // Recovery is administrative work, not an extra redo step.
            return try action.perform(trash: trash)
        })
    }
}

public enum OpError: LocalizedError {
    case undoConflict(URL)
    case cancelled
    case trashUnavailable(URL)
    case sameLocation
    case intoItself(URL)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .undoConflict(let u): return "Cannot undo: an item named “\(u.lastPathComponent)” already exists."
        case .cancelled: return "The operation was cancelled."
        case .trashUnavailable(let u): return String(format: "“%@” could not be moved to Trash. You can permanently delete it instead, but this cannot be undone.", u.lastPathComponent)
        case .sameLocation: return "The source and destination are the same."
        case .intoItself(let u): return "Cannot copy or move “\(u.lastPathComponent)” into itself."
        case .message(let s): return s
        }
    }
}

/// A linear undo/redo history of file operations.
public final class UndoHistory: ObservableObject {
    public struct Entry {
        public var title: String
        public var action: UndoAction
        fileprivate var pendingRollback: UndoAction? = nil
    }
    @Published public private(set) var undoStack: [Entry] = []
    @Published public private(set) var redoStack: [Entry] = []
    public var limit = 100

    public init() {}

    public func record(_ title: String, _ action: UndoAction?) {
        guard let action, !action.isEmpty else { return }
        undoStack.append(Entry(title: title, action: action))
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public var undoTitle: String? { undoStack.last?.title }
    public var redoTitle: String? { redoStack.last?.title }

    @discardableResult
    public func undo(trash: Trasher = Trasher()) throws -> UndoAction? {
        guard var entry = undoStack.last else { return nil }
        do {
            let inverse = try perform(&entry, trash: trash)
            undoStack.removeLast()
            redoStack.append(Entry(title: entry.title, action: inverse))
            return entry.action
        } catch {
            undoStack[undoStack.count - 1] = entry
            throw error
        }
    }

    @discardableResult
    public func redo(trash: Trasher = Trasher()) throws -> UndoAction? {
        guard var entry = redoStack.last else { return nil }
        do {
            let inverse = try perform(&entry, trash: trash)
            redoStack.removeLast()
            undoStack.append(Entry(title: entry.title, action: inverse))
            return entry.action
        } catch {
            redoStack[redoStack.count - 1] = entry
            throw error
        }
    }

    private func perform(_ entry: inout Entry, trash: Trasher) throws -> UndoAction {
        // Finish recovery first without turning it into an extra undo/redo operation.
        if let pending = entry.pendingRollback {
            do {
                _ = try pending.perform(trash: trash)
                entry.pendingRollback = nil
            } catch {
                if let recovery = error as? UndoRecoveryError {
                    entry.pendingRollback = recovery.retrying(pending, trash: trash)
                }
                throw error
            }
        }
        do {
            return try entry.action.perform(trash: trash)
        } catch {
            if let recovery = error as? UndoRecoveryError { entry.pendingRollback = recovery.rollback }
            throw error
        }
    }
}

/// Moves items to the system Trash, falling back to the app's private trash for locations
/// without one (network/removable volumes) when allowed.
public struct Trasher {
    public var allowPrivateTrash: Bool
    public var privateTrashRoot: URL
    public var useSystemTrash: Bool

    public init(allowPrivateTrash: Bool = true, privateTrashRoot: URL = AppPaths.privateTrash, useSystemTrash: Bool = true) {
        self.allowPrivateTrash = allowPrivateTrash
        self.privateTrashRoot = privateTrashRoot
        self.useSystemTrash = useSystemTrash
    }

    /// Returns the item's new location. Private-only storage also supports hosts without system Trash access.
    public func trash(_ url: URL) throws -> URL {
        if !useSystemTrash {
            guard allowPrivateTrash else { throw OpError.trashUnavailable(url) }
            return try privateTrash(url)
        }
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let r = result as URL? { return r }
        } catch {
            guard allowPrivateTrash else { throw OpError.trashUnavailable(url) }
        }
        return try privateTrash(url)
    }

    public func privateTrash(_ url: URL) throws -> URL {
        let bucket = privateTrashRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let dest = bucket.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Whether `url` lives in the app's private trash (such items are deleted on quit).
    public func isInPrivateTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(privateTrashRoot.standardizedFileURL.path)
    }

    public static func emptyPrivateTrash(_ root: URL = AppPaths.privateTrash) {
        let fm = FileManager.default
        for c in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: c)
        }
    }
}
