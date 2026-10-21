import Foundation

public struct VolumeInfo: Hashable, Sendable {
    public var url: URL
    public var name: String
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isNetwork: Bool
    public var isRoot: Bool
    public var capacity: Int64?
    public var available: Int64?
    public var format: String?
}

public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    public static func all() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info)
            .filter { $0.isRoot || !$0.url.path.hasPrefix("/System/Volumes") }
    }

    public static func info(_ url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if v.volumeIsBrowsable == false { return nil }
        let isNetwork = v.volumeIsLocal == false
        let root = v.volumeIsRootFileSystem ?? (url.path == "/")
        let avail: Int64? = v.volumeAvailableCapacityForImportantUsage ?? v.volumeAvailableCapacity.map { Int64($0) }
        return VolumeInfo(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent,
                          isInternal: (v.volumeIsInternal ?? false) || root, isRemovable: v.volumeIsRemovable ?? false,
                          isEjectable: v.volumeIsEjectable ?? false, isNetwork: isNetwork, isRoot: root,
                          capacity: v.volumeTotalCapacity.map { Int64($0) }, available: avail,
                          format: v.volumeLocalizedFormatDescription)
    }

    public static func internalDrives() -> [VolumeInfo] { all().filter { !$0.isNetwork && $0.isInternal && !$0.isEjectable } }
    public static func externalDrives() -> [VolumeInfo] { all().filter { !$0.isNetwork && !( $0.isInternal && !$0.isEjectable) } }
    public static func networkVolumes() -> [VolumeInfo] { all().filter(\.isNetwork) }

    /// Volume containing `url`.
    public static func volume(containing url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return info(v)
    }

    // MARK: Cloud locations

    public static var iCloudDrive: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static var cloudStorage: [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether the URL is inside a Cloud Storage provider container (File Provider).
    public static func isInCloudStorage(_ url: URL) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path
        return url.standardizedFileURL.path.hasPrefix(root + "/")
    }

    public static var userTrash: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true) }

    /// Full Disk Access probe: ~/.Trash is unreadable without it.
    public static var hasFullDiskAccess: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: userTrash.path)) != nil
    }
}
