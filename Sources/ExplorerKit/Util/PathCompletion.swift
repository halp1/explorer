import Foundation

/// Folder completions for the Go to Folder (⇧⌘G) field.
public enum PathCompletion {
    /// Subfolders of the typed path's parent whose names start with the typed last component, case-insensitively,
    /// in Finder order, each as a full path ending in "/". A trailing "/" lists the folder itself. "~" expands.
    public static func candidates(for text: String, limit: Int = 12) -> [String] {
        // expandingTildeInPath also drops a trailing "/", so read it from the typed text.
        let listsFolder = text.hasSuffix("/")
        let expanded = (text as NSString).expandingTildeInPath
        let dir = listsFolder ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = listsFolder ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(prefix) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0), isDirectory: &d) && d.boolValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(limit).map { (dir as NSString).appendingPathComponent($0) + "/" }
    }
}
