import UniformTypeIdentifiers
import Foundation

public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name = "Name"
    case kind = "Kind"
    case dateModified = "DateModified"
    case dateCreated = "DateCreated"
    case dateAdded = "DateAdded"
    case dateOpened = "DateOpened"
    case size = "Size"
    case tags = "Tags"
    case rating = "Rating"

    public var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAdded: return "Date Added"
        case .dateOpened: return "Date Last Opened"
        case .size: return "Size"
        case .tags: return "Tags"
        case .rating: return "Star Rating"
        }
    }

    /// Captions for the ascending/descending menu items, as the original shows them per key.
    public var orderTitles: (asc: String, desc: String) {
        switch self {
        case .name, .kind: return ("Alphabetical", "Reverse alphabetical")
        case .dateModified, .dateCreated, .dateAdded, .dateOpened: return ("Oldest first", "Newest first")
        case .size: return ("Smallest first", "Largest first")
        case .tags: return ("Tagged first", "Untagged first")
        case .rating: return ("Higher rating first", "Unrated first")
        }
    }
}

public enum SortOrder: String, Codable, Sendable { case ascending = "Ascending", descending = "Descending" }

public enum FolderPlacement: String, Codable, Sendable { case mixed, first, last }

public enum GroupKey: String, Codable, CaseIterable, Sendable {
    case none = "None"
    case kind = "Kind"
    case dateModified = "DateModified"
    case dateCreated = "DateCreated"
    case dateAdded = "DateAdded"
    case dateOpened = "DateOpened"
    case size = "Size"
    case tags = "Tags"
    case rating = "Rating"

    public var title: String {
        switch self {
        case .none: return "No Grouping"
        case .kind: return "Kind"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAdded: return "Date Added"
        case .dateOpened: return "Date Last Opened"
        case .size: return "Size"
        case .tags: return "Tags"
        case .rating: return "Star Rating"
        }
    }
}

public struct ItemGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var order: Int
    public var items: [FileItem]
    public init(id: String, title: String, order: Int, items: [FileItem]) { self.id = id; self.title = title; self.order = order; self.items = items }
}

public enum Sorter {
    public static func sort(_ items: [FileItem], by key: SortKey, order: SortOrder, folders: FolderPlacement) -> [FileItem] {
        let asc = order == .ascending
        return items.sorted { a, b in
            if folders != .mixed, a.isFolder != b.isFolder {
                return folders == .first ? a.isFolder : !a.isFolder
            }
            let c = compare(a, b, key)
            if c == .orderedSame {
                // stable tiebreak by name, always ascending
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            return asc ? c == .orderedAscending : c == .orderedDescending
        }
    }

    public static func compare(_ a: FileItem, _ b: FileItem, _ key: SortKey) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T?, _ y: T?) -> ComparisonResult {
            switch (x, y) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedAscending
            case (_, nil): return .orderedDescending
            case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            }
        }
        switch key {
        case .name: return a.displayName.localizedStandardCompare(b.displayName)
        case .kind:
            let r = a.kind.localizedStandardCompare(b.kind)
            return r
        case .dateModified: return cmp(a.modified, b.modified)
        case .dateCreated: return cmp(a.created, b.created)
        case .dateAdded: return cmp(a.added, b.added)
        case .dateOpened: return cmp(a.opened, b.opened)
        case .size: return cmp(a.size ?? (a.isFolder ? -1 : 0), b.size ?? (b.isFolder ? -1 : 0))
        case .tags:
            // "Tagged first" when ascending
            let ta = a.labelNumber > 0 || !a.tags.isEmpty, tb = b.labelNumber > 0 || !b.tags.isEmpty
            if ta == tb { return .orderedSame }
            return ta ? .orderedAscending : .orderedDescending
        case .rating:
            // "Higher rating first" when ascending
            return cmp(b.rating, a.rating)
        }
    }

    // MARK: Grouping

    /// Buckets items without reordering them inside a bucket, so a folders-first sort stays folders-first per group.
    /// `folders: .last` moves the size grouping's own "Folders" bucket (folders have no size) to the end.
    public static func group(_ items: [FileItem], by key: GroupKey, folders: FolderPlacement = .first, now: Date = Date(), calendar: Calendar = .current) -> [ItemGroup] {
        guard key != .none else { return [ItemGroup(id: "all", title: "", order: 0, items: items)] }
        var buckets: [String: ItemGroup] = [:]
        for it in items {
            let (id, title, order) = bucket(for: it, key: key, now: now, calendar: calendar)
            if buckets[id] == nil {
                buckets[id] = ItemGroup(id: id, title: title, order: order, items: [])
            }
            buckets[id]!.items.append(it)
        }
        var out = buckets.values.sorted { $0.order == $1.order ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.order < $1.order }
        if folders == .last, let i = out.firstIndex(where: { $0.id == "folders" }) { out.append(out.remove(at: i)) }
        return out
    }

    static func bucket(for it: FileItem, key: GroupKey, now: Date, calendar: Calendar) -> (String, String, Int) {
        switch key {
        case .none: return ("all", "", 0)
        case .kind:
            let k = kindGroup(it)
            return (k, k, 0)
        case .dateModified: return dateBucket(it.modified, now: now, cal: calendar)
        case .dateCreated: return dateBucket(it.created, now: now, cal: calendar)
        case .dateAdded: return dateBucket(it.added, now: now, cal: calendar)
        case .dateOpened: return dateBucket(it.opened, now: now, cal: calendar)
        case .size:
            if it.isFolder { return ("folders", "Folders", -1) }
            let s = it.size ?? 0
            let mb: Int64 = 1_000_000
            switch s {
            case 0: return ("zero", "Zero bytes", 0)
            case ..<(100 * 1000): return ("tiny", "Tiny Files", 1)
            case ..<(1 * mb): return ("small", "Small Files", 2)
            case ..<(100 * mb): return ("medium", "Medium Files", 3)
            case ..<(1000 * mb): return ("large", "Large Files", 4)
            case ..<(4000 * mb): return ("huge", "Huge Files", 5)
            default: return ("gigantic", "Gigantic Files", 6)
            }
        case .tags:
            if let first = FinderColor.menuOrder.first(where: { c in it.labelNumber == c.rawValue }) {
                return ("c\(first.rawValue)", first.name, FinderColor.menuOrder.firstIndex(of: first)!)
            }
            if let t = it.tags.first { return ("t" + t, t, 10) }
            return ("none", "No Tags", 100)
        case .rating:
            if it.rating > 0 { return ("r\(it.rating)", String(repeating: "★", count: it.rating), 5 - it.rating) }
            return ("none", "No Rating", 100)
        }
    }

    static func dateBucket(_ d: Date?, now: Date, cal: Calendar) -> (String, String, Int) {
        guard let d else { return ("unknown", "Unknown Date", 100_000) }
        if d > now.addingTimeInterval(60) { return ("future", "Future", -1) }
        // Relative to `now` (not the wall clock) so grouping is deterministic.
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days == 0 { return ("today", "Today", 0) }
        if days == 1 { return ("yesterday", "Yesterday", 1) }
        if days <= 7 { return ("7", "Previous 7 Days", 2) }
        let monthAgo = cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now)) ?? now
        if d >= monthAgo { return ("30", "Previous 30 Days", 3) }
        let comps = cal.dateComponents([.year, .month], from: d)
        let nowYear = cal.component(.year, from: now)
        if comps.year == nowYear, let m = comps.month {
            // A DateFormatter per item made large folders slow to group.
            return ("m\(m)", cal.standaloneMonthSymbols[m - 1], 100 - m)
        }
        return ("y\(comps.year!)", String(comps.year!), 1000 + (9999 - (comps.year ?? 0)))
    }

    static func kindGroup(_ it: FileItem) -> String {
        if it.isFolder { return "Folders" }
        guard let t = it.utType else { return "Other" }
        if t.conforms(to: .application) { return "Applications" }
        if t.conforms(to: .image) { return "Images" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "Movies" }
        if t.conforms(to: .audio) { return "Music" }
        if t.conforms(to: .pdf) { return "PDF Documents" }
        if t.conforms(to: .presentation) { return "Presentations" }
        if t.conforms(to: .spreadsheet) { return "Spreadsheets" }
        if t.conforms(to: .archive) || it.isArchive { return "Archives" }
        if t.conforms(to: .diskImage) { return "Disk Images" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) { return "Developer" }
        if t.conforms(to: .text) || t.conforms(to: .compositeContent) { return "Documents" }
        if t.conforms(to: .font) { return "Fonts" }
        return "Other"
    }
}
