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

    /// Performs the undo and returns the inverse action.
    public func perform(trash: Trasher = Trasher()) throws -> UndoAction {
        let fm = FileManager.default
        switch self {
        case .created(let urls):
            var pairs: [MovePair] = []
            for u in urls.reversed() where FileNaming.defaultExists(u) {
                let t = try trash.trash(u)
                pairs.append(MovePair(from: u, to: t))
            }
            return .trashed(pairs)
        case .moved(let pairs):
            // Two-phase so swaps/cycles (a→b, b→a) can be undone.
            let vacating = Set(pairs.map { $0.to.standardizedFileURL.path })
            for p in pairs where FileNaming.defaultExists(p.from) && !vacating.contains(p.from.standardizedFileURL.path) {
                throw OpError.undoConflict(p.from)
            }
            var staged: [(MovePair, URL)] = []
            for p in pairs.reversed() {
                let tmp = p.to.deletingLastPathComponent().appendingPathComponent(".explorer-undo-\(UUID().uuidString)")
                try fm.moveItem(at: p.to, to: tmp)
                staged.append((p, tmp))
            }
            var done: [MovePair] = []
            for (p, tmp) in staged {
                try fm.createDirectory(at: p.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: p.from)
                done.append(p.swapped)
            }
            return .moved(done.reversed())
        case .trashed(let pairs):
            var restored: [URL] = []
            for p in pairs.reversed() {
                if FileNaming.defaultExists(p.from) { throw OpError.undoConflict(p.from) }
                try fm.createDirectory(at: p.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: p.to, to: p.from)
                restored.append(p.from)
            }
            return .created(restored)
        case .composite(let actions):
            var inverses: [UndoAction] = []
            for a in actions.reversed() { inverses.append(try a.perform(trash: trash)) }
            return .composite(inverses)
        case .custom(_, let undo):
            return try undo()
        }
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
        guard let e = undoStack.popLast() else { return nil }
        do {
            let inv = try e.action.perform(trash: trash)
            redoStack.append(Entry(title: e.title, action: inv))
            return e.action
        } catch {
            throw error
        }
    }

    @discardableResult
    public func redo(trash: Trasher = Trasher()) throws -> UndoAction? {
        guard let e = redoStack.popLast() else { return nil }
        let inv = try e.action.perform(trash: trash)
        undoStack.append(Entry(title: e.title, action: inv))
        return e.action
    }
}

/// Moves items to the system Trash, falling back to the app's private trash for locations
/// without one (network/removable volumes) when allowed.
public struct Trasher {
    public var allowPrivateTrash: Bool
    public var privateTrashRoot: URL

    public init(allowPrivateTrash: Bool = true, privateTrashRoot: URL = AppPaths.privateTrash) {
        self.allowPrivateTrash = allowPrivateTrash
        self.privateTrashRoot = privateTrashRoot
    }

    /// Returns the item's new location.
    public func trash(_ url: URL) throws -> URL {
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
