import Foundation
@_exported import ExplorerHelperProtocol

extension URL {
    /// The parent directory, or nil at the file-system root.
    ///
    /// Use this instead of `deletingLastPathComponent()` in any walk-up loop: for a standardized
    /// root URL Foundation returns `file:///../` (path "/.."), then "/../..", and so on. The path never
    /// repeats, so loops that stop when the path stops changing never terminate.
    public var parentDirectory: URL? {
        let p = (path as NSString).standardizingPath
        guard !p.isEmpty, p != "/" else { return nil }
        let up = (p as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: up.isEmpty ? "/" : up, isDirectory: true)
    }

    /// This URL followed by every ancestor up to and including "/". Always finite.
    public var selfAndAncestors: [URL] {
        var out: [URL] = [self]
        var u = self
        while let up = u.parentDirectory, out.count < 4096 {
            out.append(up)
            u = up
        }
        return out
    }
}

public enum FileNaming {
    /// Localized display name of a folder (e.g. "iCloud Drive" for com~apple~CloudDocs).
    public static func displayName(of url: URL, preferPathNames: Bool = false) -> String {
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
        }
        if preferPathNames { return url.lastPathComponent }
        return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    /// Returns a non-existing URL in `dir` based on `name`, appending " 2", " 3"… before the extension.
    public static func uniqueURL(in dir: URL, name: String, isDirectory: Bool = false, exists: (URL) -> Bool = defaultExists) -> URL {
        let first = dir.appendingPathComponent(name, isDirectory: isDirectory)
        if !exists(first) { return first }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        if isDirectory { stem = name }
        // Strip an existing trailing " N"
        var start = 2
        if let r = stem.range(of: #" (\d+)$"#, options: .regularExpression), let n = Int(stem[r].dropFirst()) {
            stem = String(stem[..<r.lowerBound]); start = n + 1
        }
        var i = start
        while true {
            let candidate = (isDirectory || ext.isEmpty) ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let u = dir.appendingPathComponent(candidate, isDirectory: isDirectory)
            if !exists(u) { return u }
            i += 1
        }
    }

    public static func defaultExists(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0
    }

    /// Name for "Duplicate": "file copy.txt", "file copy 2.txt".
    public static func duplicateURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let isDir = url.hasDirectoryPath
        let ext = isDir ? "" : (name as NSString).pathExtension
        let stem = isDir ? name : (name as NSString).deletingPathExtension
        func make(_ suffix: String) -> URL {
            let n = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            return dir.appendingPathComponent(n)
        }
        var u = make("copy")
        var i = 2
        while defaultExists(u) { u = make("copy \(i)"); i += 1 }
        return u
    }

    /// Validates a user-entered file name.
    public static func validate(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "The new name cannot be empty." }
        if t.contains("/") { return "The name can’t contain “/”." }
        if t == "." || t == ".." { return "The name is reserved." }
        if t.utf8.count > 255 { return "The name is too long." }
        return nil
    }
}

public enum SizeFormat {
    public static func string(_ bytes: Int64?, style: ByteCountFormatter.CountStyle = .file) -> String {
        guard let b = bytes else { return "--" }
        if b == 0 { return "Zero bytes" }
        // Three significant digits like the original ("49.8 KB", "1.81 KB", "143 KB"); bytes spelled out.
        if b < 1000 { return "\(b) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(b) / 1000
        var i = 0
        while v >= 999.5 && i < units.count - 1 { v /= 1000; i += 1 }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        var str = String(format: "%.\(digits)f", v)
        if str.contains(".") { while str.hasSuffix("0") { str.removeLast() }; if str.hasSuffix(".") { str.removeLast() } }
        return "\(str) \(units[i])"
    }
}
