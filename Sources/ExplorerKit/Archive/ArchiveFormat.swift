import Foundation

/// Archive formats Explorer can browse/create.
public enum ArchiveFormat: String, CaseIterable, Codable, Sendable {
    case zip, sevenZip = "7z", tar, tarGz = "tar.gz", tarBz2 = "tar.bz2", tarXz = "tar.xz", tarLz4 = "tar.lz4", tarZlib = "tar.zlib", tar7z = "tar.7z"
    case rar, sevenZipMulti = "7z.001"
    case gz, bz2, xz, lz4, zlib
    case appleArchive = "aar", cpio, iso = "iso", xar

    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .zip: return "ZIP"; case .sevenZip: return "7Z"; case .tar: return "TAR"; case .tarGz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"; case .tarXz: return "TAR.XZ"; case .tarLz4: return "TAR.LZ4"; case .tarZlib: return "TAR.ZLIB"
        case .tar7z: return "TAR.7Z"; case .rar: return "RAR"; case .sevenZipMulti: return "7Z (multi-volume)"
        case .gz: return "GZ"; case .bz2: return "BZ2"; case .xz: return "XZ"; case .lz4: return "LZ4"; case .zlib: return "ZLIB"
        case .appleArchive: return "Apple archive"; case .cpio: return "CPIO"; case .iso: return "ISO"; case .xar: return "XAR"
        }
    }

    /// Formats offered in "Compress to ›".
    public static let creatable: [ArchiveFormat] = [.zip, .sevenZip, .tar, .tarGz, .tarBz2, .tarXz, .tarLz4, .tarZlib, .tar7z]
    /// Formats that support a password (offered as "Protected …" variants).
    public static let protectable: [ArchiveFormat] = [.zip, .sevenZip, .tar7z]

    /// Whether entries can be added/removed after creation.
    public var isWritable: Bool {
        switch self {
        case .zip, .sevenZip, .tar, .tarGz, .tarBz2, .tarXz, .tarLz4, .tarZlib, .tar7z: return true
        default: return false
        }
    }

    /// Single compressed stream (no container).
    public var isSingleStream: Bool { [.gz, .bz2, .xz, .lz4, .zlib].contains(self) }

    public var isTarFamily: Bool { [.tar, .tarGz, .tarBz2, .tarXz, .tarLz4, .tarZlib, .tar7z].contains(self) }

    /// The single-file stream format used when compressing one file with a tar-compressed format.
    public var singleFileEquivalent: ArchiveFormat? {
        switch self {
        case .tarGz: return .gz; case .tarBz2: return .bz2; case .tarXz: return .xz; case .tarLz4: return .lz4; case .tarZlib: return .zlib
        default: return nil
        }
    }

    public static func detect(fileName: String) -> ArchiveFormat? {
        let n = fileName.lowercased()
        if n.range(of: #"\.7z\.\d{3}$"#, options: .regularExpression) != nil { return .sevenZipMulti }
        let ordered: [(String, ArchiveFormat)] = [
            (".tar.gz", .tarGz), (".tgz", .tarGz), (".tar.bz2", .tarBz2), (".tbz2", .tarBz2), (".tbz", .tarBz2),
            (".tar.xz", .tarXz), (".txz", .tarXz), (".tar.lz4", .tarLz4), (".tar.zlib", .tarZlib), (".tar.7z", .tar7z),
            (".tar", .tar), (".zip", .zip), (".7z", .sevenZip), (".rar", .rar),
            (".gz", .gz), (".bz2", .bz2), (".xz", .xz), (".lz4", .lz4), (".zlib", .zlib),
            (".aar", .appleArchive), (".cpio", .cpio), (".xar", .xar), (".iso", .iso),
        ]
        for (ext, f) in ordered where n.hasSuffix(ext) { return f }
        return nil
    }

    /// Strips the archive extension from a file name ("photos.tar.gz" → "photos").
    public static func baseName(_ fileName: String) -> String {
        guard let f = detect(fileName: fileName) else { return (fileName as NSString).deletingPathExtension }
        let lower = fileName.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lz4", ".tar.zlib", ".tar.7z", ".tgz", ".tbz2", ".tbz", ".txz"] where lower.hasSuffix(ext) {
            return String(fileName.dropLast(ext.count))
        }
        if f == .sevenZipMulti, let r = fileName.range(of: #"\.7z\.\d{3}$"#, options: [.regularExpression, .caseInsensitive]) {
            return String(fileName[..<r.lowerBound])
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// libarchive write configuration: (format name, filters, options).
    var writeConfig: (format: String, filters: [String]) {
        switch self {
        case .zip: return ("zip", [])
        case .sevenZip: return ("7zip", [])
        case .tar: return ("pax", [])
        case .tarGz: return ("pax", ["gzip"])
        case .tarBz2: return ("pax", ["bzip2"])
        case .tarXz: return ("pax", ["xz"])
        case .tarLz4: return ("pax", ["lz4"])
        case .tarZlib: return ("pax", ["zlib"])
        case .tar7z: return ("7zip", [])  // a tar wrapped in a 7z container
        case .gz: return ("raw", ["gzip"])
        case .bz2: return ("raw", ["bzip2"])
        case .xz: return ("raw", ["xz"])
        case .lz4: return ("raw", ["lz4"])
        case .zlib: return ("raw", ["zlib"])
        default: return ("", [])
        }
    }
}
