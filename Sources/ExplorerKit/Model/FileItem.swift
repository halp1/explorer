import Foundation
import UniformTypeIdentifiers

/// A row in a file view. Value type, cheap to diff.
public struct FileItem: Hashable, Identifiable, Sendable {
    public var id: String { url.path + (archivePath ?? "") }

    public var url: URL
    /// For archive entries: the entry path inside the archive (e.g. "dir/file.txt"); nil for real files.
    public var archivePath: String?
    public var name: String
    public var displayName: String
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymlink: Bool
    public var isAlias: Bool
    public var isHidden: Bool
    public var isLocked: Bool
    public var isVolume: Bool
    public var size: Int64?           // file size (allocated not used); nil for folders until computed
    public var compressedSize: Int64?
    public var itemCount: Int?        // folders: number of children (lazily filled)
    public var created: Date?
    public var modified: Date?
    public var added: Date?
    public var opened: Date?
    public var attributeChanged: Date?
    public var typeIdentifier: String?
    public var kind: String
    public var tags: [String]
    public var labelNumber: Int
    public var rating: Int
    public var cloud: CloudStatus
    public var gitStatus: GitStatus?

    public init(url: URL, archivePath: String? = nil, name: String, displayName: String? = nil,
                isDirectory: Bool, isPackage: Bool = false, isSymlink: Bool = false, isAlias: Bool = false,
                isHidden: Bool = false, isLocked: Bool = false, isVolume: Bool = false,
                size: Int64? = nil, compressedSize: Int64? = nil, itemCount: Int? = nil,
                created: Date? = nil, modified: Date? = nil, added: Date? = nil, opened: Date? = nil,
                attributeChanged: Date? = nil, typeIdentifier: String? = nil, kind: String = "",
                tags: [String] = [], labelNumber: Int = 0, rating: Int = 0, cloud: CloudStatus = .local,
                gitStatus: GitStatus? = nil) {
        self.url = url; self.archivePath = archivePath; self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory; self.isPackage = isPackage; self.isSymlink = isSymlink
        self.isAlias = isAlias; self.isHidden = isHidden; self.isLocked = isLocked; self.isVolume = isVolume
        self.size = size; self.compressedSize = compressedSize; self.itemCount = itemCount
        self.created = created; self.modified = modified; self.added = added; self.opened = opened
        self.attributeChanged = attributeChanged; self.typeIdentifier = typeIdentifier; self.kind = kind
        self.tags = tags; self.labelNumber = labelNumber; self.rating = rating; self.cloud = cloud
        self.gitStatus = gitStatus
    }

    /// Folder-like for navigation (directory that is not a package).
    public var isFolder: Bool { isDirectory && !isPackage }
    public var fileExtension: String { (name as NSString).pathExtension }
    public var stem: String { (name as NSString).deletingPathExtension }
    public var utType: UTType? { typeIdentifier.flatMap(UTType.init) }

    public var isArchive: Bool {
        !isDirectory && ArchiveFormat.detect(fileName: name) != nil
    }

    public var isImage: Bool { utType?.conforms(to: .image) ?? false }
    public var isMovie: Bool { utType?.conforms(to: .audiovisualContent) ?? false }
    public var isAudio: Bool { utType?.conforms(to: .audio) ?? false }
    public var isText: Bool {
        guard let t = utType else { return false }
        return t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .propertyList) || t.conforms(to: .json)
    }
}

public enum CloudStatus: String, Hashable, Codable, Sendable {
    case local, current, notDownloaded, downloading, uploading, notUploaded, excluded
}

public enum GitStatus: Character, Hashable, Codable, Sendable, CaseIterable {
    case conflicted = "U", modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C", untracked = "?", ignored = "!"

    /// Higher = more significant (used to roll a folder's status up from its children).
    public var significance: Int {
        switch self {
        case .conflicted: return 7
        case .deleted: return 6
        case .modified: return 5
        case .renamed: return 4
        case .copied: return 3
        case .added: return 2
        case .untracked: return 1
        case .ignored: return 0
        }
    }
}

// MARK: - Loading from the file system

public enum FileItemLoader {
    public static let resourceKeys: [URLResourceKey] = [
        .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        .isHiddenKey, .isUserImmutableKey, .isVolumeKey, .fileSizeKey, .totalFileSizeKey, .creationDateKey,
        .contentModificationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey, .attributeModificationDateKey,
        .typeIdentifierKey, .localizedTypeDescriptionKey, .tagNamesKey, .labelNumberKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsExcludedFromSyncKey,
    ]

    public static func load(_ urlIn: URL, preferPathNames: Bool = false) -> FileItem? {
        var url = urlIn
        url.removeAllCachedResourceValues()
        guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            // Broken symlink etc: fall back to lstat info
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: false,
                            isSymlink: (st.st_mode & S_IFMT) == S_IFLNK, isHidden: url.lastPathComponent.hasPrefix("."),
                            size: Int64(st.st_size), modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                            kind: "Symbolic link")
        }
        let name = v.name ?? url.lastPathComponent
        var display = name
        if !preferPathNames, let loc = v.localizedName, v.isDirectory == true { display = loc }
        var isDir = v.isDirectory ?? false
        // Symlinks to folders behave like folders.
        if v.isSymbolicLink == true {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &d) { isDir = d.boolValue }
        }
        return FileItem(
            url: url, name: name, displayName: display,
            isDirectory: isDir, isPackage: v.isPackage ?? false,
            isSymlink: v.isSymbolicLink ?? false, isAlias: (v.isAliasFile ?? false) && !(v.isSymbolicLink ?? false),
            isHidden: (v.isHidden ?? false) || name.hasPrefix("."), isLocked: v.isUserImmutable ?? false,
            isVolume: v.isVolume ?? false,
            size: isDir && !(v.isPackage ?? false) ? nil : (v.isPackage == true ? FileItemLoader.packageSize(url) : Int64(v.totalFileSize ?? v.fileSize ?? 0)),
            created: v.creationDate, modified: v.contentModificationDate, added: v.addedToDirectoryDate,
            opened: v.contentAccessDate, attributeChanged: v.attributeModificationDate,
            typeIdentifier: v.typeIdentifier, kind: v.localizedTypeDescription ?? "",
            tags: Metadata.tags(url).filter { FinderColor.byName($0) == nil },
            labelNumber: v.labelNumber ?? 0,
            rating: Metadata.starRating(url) ?? 0,
            cloud: cloudStatus(v))
    }

    static func cloudStatus(_ v: URLResourceValues) -> CloudStatus {
        guard v.isUbiquitousItem == true else { return .local }
        if v.ubiquitousItemIsExcludedFromSync == true { return .excluded }
        if v.ubiquitousItemIsDownloading == true { return .downloading }
        if v.ubiquitousItemIsUploading == true { return .uploading }
        if v.ubiquitousItemIsUploaded == false { return .notUploaded }
        if v.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
        return .current
    }

    /// Lists a directory. Throws `FolderAccessError` on permission failures.
    public static func list(_ dir: URL, includeHidden: Bool, preferPathNames: Bool = false) throws -> [FileItem] {
        let fm = FileManager.default
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { opts.insert(.skipsHiddenFiles) }
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: resourceKeys, options: opts)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
            throw FolderAccessError.noPermission(dir)
        }
        return urls.compactMap { load($0, preferPathNames: preferPathNames) }
            .filter { includeHidden || !$0.isHidden }
    }

    /// Recursive logical size of a package (apps, bundles), cached per path + modification date.
    nonisolated(unsafe) static var packageSizes: [String: (Date?, Int64)] = [:]
    static let packageLock = NSLock()
    public static func packageSize(_ url: URL) -> Int64 {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        packageLock.lock()
        if let c = packageSizes[url.path], c.0 == mod { packageLock.unlock(); return c.1 }
        packageLock.unlock()
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileSizeKey, .isRegularFileKey], options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: [.totalFileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                    total += Int64(v.totalFileSize ?? 0)
                }
            }
        }
        packageLock.lock(); packageSizes[url.path] = (mod, total); packageLock.unlock()
        return total
    }

    public static func childCount(_ dir: URL, includeHidden: Bool) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return includeHidden ? names.count : names.filter { !$0.hasPrefix(".") }.count
    }
}

public enum FolderAccessError: LocalizedError {
    case noPermission(URL)
    public var errorDescription: String? {
        switch self {
        case .noPermission(let u):
            return String(format: "The folder “%@” couldn’t be opened because you don’t have permission to view it.", u.lastPathComponent)
        }
    }
}

extension FinderColor {
    public static func byName(_ s: String) -> FinderColor? {
        allCases.first { $0.name == s }
    }
}
