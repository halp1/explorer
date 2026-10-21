import Foundation

/// Extended-attribute helpers: star rating, tags, Finder comments.
public enum Metadata {
    static let ratingAttr = "com.apple.metadata:kMDItemStarRating"
    static let commentAttr = "com.apple.metadata:kMDItemFinderComment"

    public static func getXattr(_ url: URL, _ name: String) -> Data? {
        let len = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let r = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        return r > 0 ? data : nil
    }

    public static func setXattr(_ url: URL, _ name: String, _ data: Data?) throws {
        let r: Int32
        if let data {
            r = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        } else {
            r = removexattr(url.path, name, XATTR_NOFOLLOW)
            if r != 0 && errno == ENOATTR { return }
        }
        if r != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Star rating 0...5 stored as a binary plist number (same format Spotlight indexes as kMDItemStarRating).
    public static func starRating(_ url: URL) -> Int? {
        guard let d = getXattr(url, ratingAttr),
              let obj = try? PropertyListSerialization.propertyList(from: d, format: nil) else { return nil }
        if let n = obj as? NSNumber { return n.intValue }
        if let s = obj as? String { return Int(s) }
        return nil
    }

    public static func setStarRating(_ url: URL, _ rating: Int) throws {
        if rating <= 0 {
            try setXattr(url, ratingAttr, nil)
        } else {
            let d = try PropertyListSerialization.data(fromPropertyList: NSNumber(value: min(rating, 5)), format: .binary, options: 0)
            try setXattr(url, ratingAttr, d)
        }
    }

    public static func finderComment(_ url: URL) -> String? {
        if let md = MDItemCreateWithURL(nil, url as CFURL),
           let c = MDItemCopyAttribute(md, kMDItemFinderComment) as? String { return c }
        guard let d = getXattr(url, commentAttr),
              let obj = try? PropertyListSerialization.propertyList(from: d, format: nil) else { return nil }
        return obj as? String
    }

    // MARK: Tags

    /// Reads `_kMDItemUserTags` directly (fast, uncached). Entries look like "Name\nColorIndex".
    public static func tags(_ url: URL) -> [String] {
        guard let d = getXattr(url, "com.apple.metadata:_kMDItemUserTags"),
              let arr = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String] else { return [] }
        return arr.map { $0.components(separatedBy: "\n")[0] }
    }

    public static func setTags(_ url: URL, _ tags: [String]) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    public static func toggleColor(_ color: FinderColor, on urls: [URL]) throws {
        let allHave = urls.allSatisfy { tags($0).contains(color.name) }
        for u in urls {
            var t = tags(u)
            if allHave { t.removeAll { $0 == color.name } } else if !t.contains(color.name) { t.append(color.name) }
            try setTags(u, t)
        }
    }

    public static func toggleTextTag(_ tag: String, on urls: [URL]) throws {
        let allHave = urls.allSatisfy { tags($0).contains(tag) }
        for u in urls {
            var t = tags(u)
            if allHave { t.removeAll { $0 == tag } } else if !t.contains(tag) { t.append(tag) }
            try setTags(u, t)
        }
    }

    // MARK: Flags

    public static func setHidden(_ url: URL, _ hidden: Bool) throws {
        var u = url
        var v = URLResourceValues(); v.isHidden = hidden
        try u.setResourceValues(v)
    }

    public static func setLocked(_ url: URL, _ locked: Bool) throws {
        var u = url
        var v = URLResourceValues(); v.isUserImmutable = locked
        try u.setResourceValues(v)
    }

    public static func posixPermissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    public static func owner(_ url: URL) -> (user: String, group: String)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (a[.ownerAccountName] as? String ?? "?", a[.groupOwnerAccountName] as? String ?? "?")
    }

    public static func setPosixPermissions(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    /// Text tags used anywhere, from the Finder's tag list.
    public static func knownTextTags() -> [String] {
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/SyncedPreferences/com.apple.finder.plist")
        var result: [String] = []
        if let d = try? Data(contentsOf: prefs),
           let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let values = p["values"] as? [String: Any],
           let ft = values["FinderTagDict"] as? [String: Any],
           let v = ft["value"] as? [String: Any],
           let tags = v["FinderTags"] as? [[String: Any]] {
            result = tags.compactMap { $0["n"] as? String }
        }
        let colors = Set(FinderColor.allCases.map(\.name))
        result = result.filter { !colors.contains($0) }
        if result.isEmpty { result = ["Home", "Work", "Important"] }
        return result
    }
}
