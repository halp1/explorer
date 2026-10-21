import Foundation

/// Full-scan (non-Spotlight) name search. Results are a snapshot.
public final class FullScanSearch {
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true }

    /// Calls `found` in batches on the main queue; `done` when finished.
    public func run(text: String, in root: URL, includeHidden: Bool, found: @escaping ([URL]) -> Void, done: @escaping () -> Void) {
        let needle = text.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [URL] = []
            var lastFlush = Date()
            let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.nameKey], options: opts, errorHandler: { _, _ in true }) {
                for case let u as URL in e {
                    if self?.cancelled ?? true { break }
                    if needle.isEmpty || u.lastPathComponent.lowercased().contains(needle) {
                        batch.append(u)
                    }
                    if !batch.isEmpty && (batch.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.3) {
                        let b = batch; batch = []; lastFlush = Date()
                        DispatchQueue.main.async { found(b) }
                    }
                }
            }
            let b = batch
            DispatchQueue.main.async { if !b.isEmpty { found(b) }; done() }
        }
    }
}

/// Live Spotlight query wrapper.
public final class SpotlightSearch: NSObject {
    public let query = NSMetadataQuery()
    private var handler: (([URL], Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    public override init() { super.init() }

    /// `predicate` overrides the name search (smart nodes, saved searches).
    public func start(predicate: NSPredicate, scopes: [Any], onUpdate: @escaping (_ results: [URL], _ gathering: Bool) -> Void) {
        stop()
        handler = onUpdate
        query.predicate = predicate
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.3
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidUpdate, .NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            tokens.append(nc.addObserver(forName: name, object: query, queue: .main) { [weak self] n in
                self?.emit(gathering: n.name != .NSMetadataQueryDidFinishGathering && n.name != .NSMetadataQueryDidUpdate)
            })
        }
        DispatchQueue.main.async { self.query.start() }
    }

    private func emit(gathering: Bool) {
        query.disableUpdates()
        var urls: [URL] = []
        urls.reserveCapacity(query.resultCount)
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem, let p = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: p))
            }
        }
        query.enableUpdates()
        handler?(urls, gathering)
    }

    public func stop() {
        query.stop()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    deinit { stop() }

    // MARK: Predicates

    public static func namePredicate(_ text: String) -> NSPredicate {
        NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(text)*")
    }

    public static func recentPredicate(days: Int, now: Date = Date()) -> NSPredicate {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        return NSPredicate(format: "%K >= %@ && %K != 'public.folder'", NSMetadataItemFSContentChangeDateKey, since as NSDate, "kMDItemContentType")
    }

    public static func tagPredicate(_ tag: String) -> NSPredicate {
        NSPredicate(format: "kMDItemUserTags == %@", tag)
    }

    public static func ratingPredicate(_ r: Int) -> NSPredicate {
        NSPredicate(format: "kMDItemStarRating == %d", r)
    }

    public static func rawQueryPredicate(_ raw: String) -> NSPredicate? {
        NSPredicate(fromMetadataQueryString: raw)
    }
}

// MARK: - Saved searches (.savedSearch plist, Finder-compatible)

public struct SavedSearchFile {
    public var rawQuery: String
    public var scopes: [String]
    public var displayName: String

    public init(rawQuery: String, scopes: [String], displayName: String) {
        self.rawQuery = rawQuery; self.scopes = scopes; self.displayName = displayName
    }

    public static var folder: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Saved Searches", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "savedSearch" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func write(to url: URL) throws {
        let dict: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": rawQuery,
            "RawQueryDict": ["RawQuery": rawQuery, "SearchScopes": scopes],
            "SearchCriteria": ["CurrentFolderPath": scopes, "FXScopeArrayOfPaths": scopes],
            "ViewSettings": [:] as [String: Any],
        ]
        let d = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try d.write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) -> SavedSearchFile? {
        guard let d = try? Data(contentsOf: url),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let raw = p["RawQuery"] as? String ?? (p["RawQueryDict"] as? [String: Any])?["RawQuery"] as? String else { return nil }
        let scopes = ((p["RawQueryDict"] as? [String: Any])?["SearchScopes"] as? [String]) ?? []
        return SavedSearchFile(rawQuery: raw, scopes: scopes, displayName: url.deletingPathExtension().lastPathComponent)
    }

    /// Spotlight search scopes from saved paths (special tokens mapped to NSMetadataQuery constants).
    public var queryScopes: [Any] {
        if scopes.isEmpty { return [NSMetadataQueryLocalComputerScope] }
        return scopes.map { s -> Any in
            switch s {
            case "kMDQueryScopeComputer": return NSMetadataQueryLocalComputerScope
            case "kMDQueryScopeHome": return NSMetadataQueryUserHomeScope
            default: return URL(fileURLWithPath: s)
            }
        }
    }
}

// MARK: - Folder sizes

public final class FolderSizeCalculator {
    public static let shared = FolderSizeCalculator()
    private let sem = DispatchSemaphore(value: 3)
    private var cache: [String: Int64] = [:]
    private let lock = NSLock()

    public func cached(_ url: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return cache[url.path] }
    public func invalidate(_ url: URL) { lock.lock(); cache.removeValue(forKey: url.path); lock.unlock() }

    public func calculate(_ url: URL, completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            self.sem.wait()
            defer { self.sem.signal() }
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                for case let u as URL in e {
                    if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                        total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                    }
                }
            }
            self.lock.lock(); self.cache[url.path] = total; self.lock.unlock()
            DispatchQueue.main.async { completion(total) }
        }
    }
}
