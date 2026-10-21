import Foundation
import CArchive
import PLzmaSDK

/// One entry inside an archive.
public struct ArchiveEntry: Hashable, Sendable {
    public var path: String          // normalized, no leading "/", directories end with "/"
    public var size: Int64
    public var compressedSize: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isEncrypted: Bool
    public var linkTarget: String?

    public var name: String { (path.hasSuffix("/") ? String(path.dropLast()) : path).components(separatedBy: "/").last ?? path }
    public var parent: String {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        let up = (p as NSString).deletingLastPathComponent
        return up.isEmpty ? "" : up + "/"
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case unreadable
    case passwordRequired
    case wrongPassword
    case readOnly
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The archive is unreadable or corrupted."
        case .passwordRequired: return "The archive is corrupted, empty, or protected with a password."
        case .wrongPassword: return "The password is incorrect."
        case .readOnly: return "This archive format is read-only."
        case .failed(let s): return s
        }
    }
}

public typealias ArchiveProgress = (_ fraction: Double, _ currentName: String) -> Bool  // return false to cancel

/// A browsable, (optionally) modifiable archive. Implementation picks PLzma for 7z and libarchive for everything else.
public final class Archive {
    public let url: URL
    public let format: ArchiveFormat
    public var password: String?
    /// Legacy filename encoding for zip entries with non-UTF-8 names (e.g. "CP866", "Shift_JIS"); nil = automatic.
    public var filenameEncoding: String?
    public private(set) var entries: [ArchiveEntry] = []

    public init(url: URL, password: String? = nil) throws {
        guard let f = ArchiveFormat.detect(fileName: url.lastPathComponent) else { throw ArchiveError.unreadable }
        self.url = url
        self.format = f
        self.password = password
    }

    public var isWritable: Bool { format.isWritable }

    /// Volumes of a multi-volume 7z (file.7z.001, .002, ...).
    public var volumeURLs: [URL] {
        guard format == .sevenZipMulti else { return [url] }
        let base = ArchiveFormat.baseName(url.lastPathComponent) + ".7z."
        let dir = url.deletingLastPathComponent()
        var vols: [URL] = []
        var i = 1
        while true {
            let u = dir.appendingPathComponent(base + String(format: "%03d", i))
            guard FileManager.default.fileExists(atPath: u.path) else { break }
            vols.append(u); i += 1
        }
        return vols.isEmpty ? [url] : vols
    }

    var usesPLzma: Bool { format == .sevenZip || format == .sevenZipMulti || format == .tar7z }

    // MARK: Listing

    /// Reads the table of contents. Throws `.passwordRequired` when the listing (or content) is encrypted and no password is set.
    @discardableResult
    public func load() throws -> [ArchiveEntry] {
        var list = usesPLzma ? try loadPLzma() : try loadLibarchive()
        // tar.7z: present the inner tar's contents
        if format == .tar7z, list.count == 1, list[0].name.lowercased().hasSuffix(".tar") {
            let tmp = try extractToTempPLzma([list[0].path])
            let inner = try Archive(url: tmp.appendingPathComponent(list[0].path))
            list = try inner.load()
        }
        entries = Self.synthesizeDirectories(list)
        return entries
    }

    public var hasEncryptedEntries: Bool { entries.contains { $0.isEncrypted } }

    /// Adds missing intermediate directory entries so the tree can be browsed.
    static func synthesizeDirectories(_ list: [ArchiveEntry]) -> [ArchiveEntry] {
        var byPath: [String: ArchiveEntry] = [:]
        for e in list { byPath[e.path] = e }
        for e in list {
            var p = e.parent
            while !p.isEmpty, byPath[p] == nil {
                byPath[p] = ArchiveEntry(path: p, size: 0, compressedSize: nil, modified: e.modified, isDirectory: true, isSymlink: false, isEncrypted: false)
                p = ArchiveEntry(path: p, size: 0, isDirectory: true, isSymlink: false, isEncrypted: false).parent
            }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    public func children(of dir: String) -> [ArchiveEntry] {
        entries.filter { $0.parent == dir && $0.path != dir }
    }

    /// Total uncompressed size of an entry (folders: recursive).
    public func totalSize(of e: ArchiveEntry) -> (Int64, Int64?) {
        guard e.isDirectory else { return (e.size, e.compressedSize) }
        var s: Int64 = 0, c: Int64 = 0, hasC = true
        for x in entries where x.path.hasPrefix(e.path) && !x.isDirectory {
            s += x.size
            if let cs = x.compressedSize { c += cs } else { hasC = false }
        }
        return (s, hasC ? c : nil)
    }

    static func normalize(_ p: String, isDir: Bool) -> String {
        var s = p
        while s.hasPrefix("/") || s.hasPrefix("./") { s = s.hasPrefix("./") ? String(s.dropFirst(2)) : String(s.dropFirst()) }
        if isDir && !s.hasSuffix("/") && !s.isEmpty { s += "/" }
        return s
    }

    private func loadLibarchive() throws -> [ArchiveEntry] {
        let a = try openRead()
        defer { archive_read_free(a) }
        var result: [ArchiveEntry] = []
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN { throw mapReadError(a) }
            guard let entry else { break }
            let rawPath = entryPath(entry)
            let type = archive_entry_filetype(entry)
            let isDir = type == AE_IFDIR || rawPath.hasSuffix("/")
            var name = Self.normalize(rawPath, isDir: isDir)
            if format.isSingleStream && (name == "data" || name.isEmpty) {
                name = ArchiveFormat.baseName(url.lastPathComponent)
            }
            let size = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : 0
            let mtime = archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil
            let enc = archive_entry_is_encrypted(entry) != 0
            let link = archive_entry_symlink(entry).map { String(cString: $0) }
            result.append(ArchiveEntry(path: name, size: size, compressedSize: nil, modified: mtime, isDirectory: isDir,
                                       isSymlink: type == AE_IFLNK, isEncrypted: enc, linkTarget: link))
            archive_read_data_skip(a)
        }
        if format == .zip { fillZipCompressedSizes(&result) }
        return result
    }

    private func entryPath(_ e: OpaquePointer) -> String {
        if let p = archive_entry_pathname_utf8(e) { return String(cString: p) }
        if let p = archive_entry_pathname(e) {
            let data = Data(bytes: p, count: strlen(p))
            if let encName = filenameEncoding {
                let cfEnc = CFStringConvertIANACharSetNameToEncoding(encName as CFString)
                if cfEnc != kCFStringEncodingInvalidId {
                    let ns = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                    if let s = String(data: data, encoding: String.Encoding(rawValue: ns)) { return s }
                }
            }
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    /// Reads compressed sizes from the zip central directory (libarchive does not expose them).
    private func fillZipCompressedSizes(_ list: inout [ArchiveEntry]) {
        guard let sizes = ZipCentralDirectory.compressedSizes(url) else { return }
        for i in list.indices {
            let key = list[i].path
            if let c = sizes[key] ?? sizes[key.hasSuffix("/") ? String(key.dropLast()) : key] { list[i].compressedSize = c }
        }
    }

    func openRead() throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw ArchiveError.unreadable }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if format.isSingleStream {
            archive_read_support_format_raw(a)
            archive_read_support_format_empty(a)
        }
        if let pw = password { archive_read_add_passphrase(a, pw) }
        if let enc = filenameEncoding { archive_read_set_options(a, "hdrcharset=\(enc)") }
        let r = archive_read_open_filename(a, url.path, 1 << 16)
        if r != ARCHIVE_OK {
            archive_read_free(a)
            throw ArchiveError.unreadable
        }
        return a
    }

    private func mapReadError(_ a: OpaquePointer) -> ArchiveError {
        let msg = archive_error_string(a).map { String(cString: $0) } ?? ""
        if msg.localizedCaseInsensitiveContains("passphrase") || msg.localizedCaseInsensitiveContains("encrypt") {
            return password == nil ? .passwordRequired : .wrongPassword
        }
        return msg.isEmpty ? .unreadable : .failed(msg)
    }

    private func plzmaInStream() throws -> InStream {
        let vols = volumeURLs
        if vols.count > 1 {
            return try InStream(streams: try vols.map { try InStream(path: try Path($0.path)) })
        }
        return try InStream(path: try Path(url.path))
    }

    private func openPLzmaDecoder(delegate: DecoderDelegate? = nil) throws -> Decoder {
        let d = try Decoder(stream: try plzmaInStream(), fileType: .sevenZ, delegate: delegate)
        if let pw = password { try d.setPassword(pw) }
        do {
            guard try d.open() else { throw ArchiveError.unreadable }
        } catch let e as Exception {
            throw password == nil ? ArchiveError.passwordRequired : (e.code == .invalidArguments ? .unreadable : .wrongPassword)
        }
        return d
    }

    private func loadPLzma() throws -> [ArchiveEntry] {
        let d = try openPLzmaDecoder()
        let items = try d.items()
        var result: [ArchiveEntry] = []
        for i in 0..<items.count {
            let it = try items.item(at: i)
            let p = try it.path().description
            result.append(ArchiveEntry(path: Self.normalize(p, isDir: it.isDir), size: Int64(it.size),
                                       compressedSize: it.packSize > 0 ? Int64(it.packSize) : nil,
                                       modified: it.modificationDate.timeIntervalSince1970 > 0 ? it.modificationDate : nil,
                                       isDirectory: it.isDir, isSymlink: false, isEncrypted: it.encrypted))
        }
        return result
    }

    // MARK: Extraction

    /// Extracts the given entry paths (directories include their contents; empty = everything) into `dest`,
    /// preserving the archive's internal structure relative to `stripPrefix`.
    public func extract(_ paths: [String], to destIn: URL, stripPrefix: String = "", progress: ArchiveProgress? = nil) throws {
        try FileManager.default.createDirectory(at: destIn, withIntermediateDirectories: true)
        // Resolve symlinked ancestors (e.g. /var → /private/var) so secure-symlink checks pass.
        let dest = Self.realURL(destIn)
        let wanted = paths
        func selected(_ p: String) -> Bool {
            if wanted.isEmpty { return true }
            return wanted.contains { w in p == w || (w.hasSuffix("/") && p.hasPrefix(w)) }
        }
        if format == .tar7z {
            let outer = try loadPLzma()
            guard let tarEntry = outer.first(where: { $0.name.lowercased().hasSuffix(".tar") }) else { throw ArchiveError.unreadable }
            let tmp = try extractToTempPLzma([tarEntry.path])
            let inner = try Archive(url: tmp.appendingPathComponent(tarEntry.path))
            try inner.load()
            try inner.extract(paths, to: dest, stripPrefix: stripPrefix, progress: progress)
            return
        }
        if usesPLzma {
            try extractPLzma(selected: selected, to: dest, stripPrefix: stripPrefix, progress: progress)
        } else {
            try extractLibarchive(selected: selected, to: dest, stripPrefix: stripPrefix, progress: progress)
        }
    }

    private func extractLibarchive(selected: (String) -> Bool, to dest: URL, stripPrefix: String, progress: ArchiveProgress?) throws {
        let a = try openRead()
        defer { archive_read_free(a) }
        guard let w = archive_write_disk_new() else { throw ArchiveError.unreadable }
        defer { archive_write_free(w) }
        archive_write_disk_set_options(w, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_XATTR | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS)
        archive_write_disk_set_standard_lookup(w)
        let total = max(1, entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size })
        var done: Int64 = 0
        var entry: OpaquePointer?
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN { throw mapReadError(a) }
            guard let entry else { break }
            let isDir = archive_entry_filetype(entry) == AE_IFDIR
            var p = Self.normalize(entryPath(entry), isDir: isDir)
            if format.isSingleStream && (p == "data" || p.isEmpty) { p = ArchiveFormat.baseName(url.lastPathComponent) }
            guard selected(p), p.hasPrefix(stripPrefix) else { archive_read_data_skip(a); continue }
            let rel = String(p.dropFirst(stripPrefix.count))
            if rel.isEmpty { archive_read_data_skip(a); continue }
            if let progress, !progress(Double(done) / Double(total), (rel as NSString).lastPathComponent) { throw OpError.cancelled }
            let out = dest.appendingPathComponent(rel).path
            archive_entry_set_pathname(entry, out)
            if archive_write_header(w, entry) < ARCHIVE_WARN {
                throw ArchiveError.failed(archive_error_string(w).map { String(cString: $0) } ?? "Error while extracting an archive entry")
            }
            if !isDir {
                while true {
                    let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                    if n == 0 { break }
                    if n < 0 { throw mapReadError(a) }
                    _ = buf.withUnsafeBytes { archive_write_data(w, $0.baseAddress, n) }
                    done += Int64(n)
                }
            }
            archive_write_finish_entry(w)
        }
        _ = progress?(1, "")
    }

    private final class DecoderProgress: DecoderDelegate {
        let cb: ArchiveProgress?
        var cancelled = false
        init(_ cb: ArchiveProgress?) { self.cb = cb }
        func decoder(decoder: Decoder, path: String, progress: Double) {
            if let cb, !cb(progress, (path as NSString).lastPathComponent) {
                cancelled = true
                try? decoder.abort()
            }
        }
    }

    private func extractPLzma(selected: (String) -> Bool, to dest: URL, stripPrefix: String, progress: ArchiveProgress?) throws {
        let delegate = DecoderProgress(progress)
        let d = try openPLzmaDecoder(delegate: delegate)
        let items = try d.items()
        let chosen = try ItemArray()
        for i in 0..<items.count {
            let it = try items.item(at: i)
            let p = Self.normalize(try it.path().description, isDir: it.isDir)
            if selected(p) { try chosen.add(item: it) }
        }
        let staging = stripPrefix.isEmpty ? dest : AppPaths.temp.appendingPathComponent(UUID().uuidString)
        do {
            guard try d.extract(items: chosen, to: try Path(staging.path), itemsFullPath: true) else {
                throw delegate.cancelled ? OpError.cancelled : ArchiveError.unreadable
            }
        } catch let e as Exception {
            if delegate.cancelled { throw OpError.cancelled }
            throw password == nil && hasEncryptedEntries ? ArchiveError.passwordRequired : ArchiveError.failed(e.what ?? "Error while extracting an archive entry")
        }
        if !stripPrefix.isEmpty {
            let src = staging.appendingPathComponent(stripPrefix)
            let fm = FileManager.default
            for c in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let t = FileNaming.uniqueURL(in: dest, name: c.lastPathComponent, isDirectory: c.hasDirectoryPath)
                try fm.moveItem(at: c, to: t)
            }
            try? fm.removeItem(at: staging)
        }
    }

    /// Extracts entries into a fresh temporary directory, returning it (used by Quick Look, drag-out, Open).
    public func extractToTemp(_ paths: [String]) throws -> URL {
        let dir = AppPaths.temp.appendingPathComponent("archive-" + UUID().uuidString, isDirectory: true)
        try extract(paths, to: dir)
        return dir
    }

    private func extractToTempPLzma(_ paths: [String]) throws -> URL {
        let dir = AppPaths.temp.appendingPathComponent("archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try extractPLzma(selected: { p in paths.contains(p) }, to: dir, stripPrefix: "", progress: nil)
        return dir
    }

    // MARK: Creation

    /// Creates a new archive at `dest` from the given file-system items (each stored under its last path component,
    /// optionally inside `prefix`).
    public static func create(at dest: URL, format: ArchiveFormat, items: [URL], password: String? = nil,
                              prefix: String = "", progress: ArchiveProgress? = nil) throws {
        var fmt = format
        // A single file with a tar-compressed format creates the plain single-stream form.
        if items.count == 1, !isDirectory(items[0]), let single = format.singleFileEquivalent { fmt = single }
        switch fmt {
        case .sevenZip:
            try createPLzma(at: dest, items: items.map { ($0, prefix + $0.lastPathComponent) }, password: password, progress: progress)
        case .tar7z:
            let tmpTar = AppPaths.temp.appendingPathComponent(UUID().uuidString).appendingPathComponent(ArchiveFormat.baseName(dest.lastPathComponent) + ".tar")
            try FileManager.default.createDirectory(at: tmpTar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try createLibarchive(at: tmpTar, format: .tar, items: items.map { ($0, prefix + $0.lastPathComponent) }, password: nil, progress: progress)
            try createPLzma(at: dest, items: [(tmpTar, tmpTar.lastPathComponent)], password: password, progress: nil)
            try? FileManager.default.removeItem(at: tmpTar.deletingLastPathComponent())
        default:
            try createLibarchive(at: dest, format: fmt, items: items.map { ($0, prefix + $0.lastPathComponent) }, password: password, progress: progress)
        }
    }

    public static func isDirectory(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    /// Writes items with libarchive. `items` = (source on disk, path inside archive).
    static func createLibarchive(at dest: URL, format: ArchiveFormat, items: [(URL, String)], password: String?,
                                 progress: ArchiveProgress?, extraFromArchive: ((OpaquePointer) throws -> Void)? = nil) throws {
        guard let w = archive_write_new() else { throw ArchiveError.failed("archive_write_new failed") }
        defer { archive_write_free(w) }
        let cfg = format.writeConfig
        if cfg.format == "raw" {
            archive_write_set_format_raw(w)
        } else if archive_write_set_format_by_name(w, cfg.format) != ARCHIVE_OK {
            throw ArchiveError.failed("Unsupported format \(cfg.format)")
        }
        for f in cfg.filters {
            if archive_write_add_filter_by_name(w, f) != ARCHIVE_OK {
                throw ArchiveError.failed(archive_error_string(w).map { String(cString: $0) } ?? "Unsupported filter \(f)")
            }
        }
        if let pw = password, format == .zip {
            archive_write_set_options(w, "zip:encryption=aes256")
            archive_write_set_passphrase(w, pw)
        }
        guard archive_write_open_filename(w, dest.path) == ARCHIVE_OK else {
            throw ArchiveError.failed(archive_error_string(w).map { String(cString: $0) } ?? "Error while creating the archive")
        }
        // Collect file list for progress
        var files: [(URL, String)] = []
        for (src, inner) in items {
            files.append((src, inner))
            if isDirectory(src), !isSymlink(src), let subs = try? FileManager.default.subpathsOfDirectory(atPath: src.path) {
                for rel in subs.sorted() {
                    files.append((src.appendingPathComponent(rel), inner + "/" + rel))
                }
            }
        }
        let total = max(1, files.count)
        for (i, (src, inner)) in files.enumerated() {
            if let progress, !progress(Double(i) / Double(total), src.lastPathComponent) {
                archive_write_close(w)
                try? FileManager.default.removeItem(at: dest)
                throw OpError.cancelled
            }
            try writeDiskEntry(w, src: src, inner: inner)
        }
        try extraFromArchive?(w)
        if archive_write_close(w) != ARCHIVE_OK {
            throw ArchiveError.failed(archive_error_string(w).map { String(cString: $0) } ?? "Error while creating the archive")
        }
        _ = progress?(1, "")
    }

    static func realURL(_ u: URL) -> URL {
        guard let r = realpath(u.path, nil) else { return u }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r), isDirectory: true)
    }

    static func isSymlink(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func writeDiskEntry(_ w: OpaquePointer, src: URL, inner: String) throws {
        var st = stat()
        guard lstat(src.path, &st) == 0 else { return }
        guard let e = archive_entry_new() else { return }
        defer { archive_entry_free(e) }
        let kind = st.st_mode & S_IFMT
        archive_entry_set_pathname_utf8(e, kind == S_IFDIR ? inner + "/" : inner)
        archive_entry_set_perm(e, UInt32(st.st_mode & 0o7777))
        archive_entry_set_mtime(e, st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec)
        switch kind {
        case S_IFDIR:
            archive_entry_set_filetype(e, AE_IFDIR); archive_entry_set_size(e, 0)
            archive_write_header(w, e)
        case S_IFLNK:
            archive_entry_set_filetype(e, AE_IFLNK); archive_entry_set_size(e, 0)
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: src.path) { archive_entry_set_symlink(e, dest) }
            archive_write_header(w, e)
        default:
            archive_entry_set_filetype(e, AE_IFREG)
            archive_entry_set_size(e, Int64(st.st_size))
            if archive_write_header(w, e) < ARCHIVE_WARN {
                throw ArchiveError.failed(archive_error_string(w).map { String(cString: $0) } ?? "Error while adding to archive")
            }
            guard let fh = FileHandle(forReadingAtPath: src.path) else { return }
            defer { try? fh.close() }
            while true {
                let chunk = fh.readData(ofLength: 1 << 16)
                if chunk.isEmpty { break }
                _ = chunk.withUnsafeBytes { archive_write_data(w, $0.baseAddress, chunk.count) }
            }
        }
    }

    private final class EncoderProgress: EncoderDelegate {
        let cb: ArchiveProgress?
        var cancelled = false
        init(_ cb: ArchiveProgress?) { self.cb = cb }
        func encoder(encoder: Encoder, path: String, progress: Double) {
            if let cb, !cb(progress, (path as NSString).lastPathComponent) { cancelled = true; try? encoder.abort() }
        }
    }

    static func createPLzma(at dest: URL, items: [(URL, String)], password: String?, progress: ArchiveProgress?) throws {
        let delegate = EncoderProgress(progress)
        let out = try OutStream(path: try Path(dest.path))
        let enc = try Encoder(stream: out, fileType: .sevenZ, method: .LZMA2, delegate: delegate)
        if let pw = password {
            try enc.setPassword(pw)
            try enc.setShouldEncryptContent(true)
            try enc.setShouldEncryptHeader(true)
        }
        try enc.setShouldStoreModificationTime(true)
        for (src, inner) in items {
            if isDirectory(src) {
                try enc.add(path: try Path(src.path), mode: .followSymlinks, archivePath: try Path(inner))
            } else {
                try enc.add(stream: try InStream(path: try Path(src.path)), archivePath: try Path(inner))
            }
        }
        guard try enc.open() else { throw ArchiveError.failed("Error while creating the archive") }
        let ok = try enc.compress()
        if delegate.cancelled { try? FileManager.default.removeItem(at: dest); throw OpError.cancelled }
        if !ok { throw ArchiveError.failed("Error while creating the archive") }
        _ = progress?(1, "")
    }

    // MARK: Modification (rebuild)

    /// Adds file-system items into the archive under `innerDir` ("" = root). Existing entries with the same path are replaced.
    public func add(_ items: [URL], into innerDir: String, progress: ArchiveProgress? = nil) throws {
        guard isWritable else { throw ArchiveError.readOnly }
        try rebuild(removing: Set(items.map { innerDir + $0.lastPathComponent }), adding: items, prefix: innerDir, progress: progress)
    }

    /// Removes entries (directories recursively).
    public func remove(_ paths: [String], progress: ArchiveProgress? = nil) throws {
        guard isWritable else { throw ArchiveError.readOnly }
        try rebuild(removing: Set(paths), adding: [], prefix: "", progress: progress)
    }

    /// Re-creates the archive: extract everything except removed paths to staging, then write staging + additions.
    private func rebuild(removing: Set<String>, adding: [URL], prefix: String, progress: ArchiveProgress?) throws {
        if entries.isEmpty { try load() }
        let fm = FileManager.default
        let staging = AppPaths.temp.appendingPathComponent("rebuild-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        func removed(_ p: String) -> Bool {
            removing.contains { r in p == r || p == r + "/" || p.hasPrefix(r.hasSuffix("/") ? r : r + "/") }
        }
        let keep = entries.filter { !removed($0.path) && !$0.isDirectory }.map(\.path)
        let keepDirs = entries.filter { !removed($0.path) && $0.isDirectory }.map(\.path)
        if !keep.isEmpty { try extract(keep, to: staging) }
        for d in keepDirs { try? fm.createDirectory(at: staging.appendingPathComponent(d), withIntermediateDirectories: true) }
        // Place additions into staging
        let dest = staging.appendingPathComponent(prefix, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for a in adding {
            let t = dest.appendingPathComponent(a.lastPathComponent)
            if fm.fileExists(atPath: t.path) { try fm.removeItem(at: t) }
            try fm.copyItem(at: a, to: t)
        }
        let top = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        let tmpOut = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        if top.isEmpty {
            // Empty archive
            try Self.createLibarchive(at: tmpOut, format: format == .sevenZip ? .zip : format, items: [], password: password, progress: progress)
        } else {
            try Self.create(at: tmpOut, format: format, items: top, password: password, progress: progress)
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmpOut)
        try load()
    }
}

// MARK: - Zip central directory reader (compressed sizes)

enum ZipCentralDirectory {
    static func compressedSizes(_ url: URL) -> [String: Int64]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd(), end >= 22 else { return nil }
        let tailLen = min(end, 65557)
        try? fh.seek(toOffset: end - tailLen)
        guard let tail = try? fh.read(upToCount: Int(tailLen)) else { return nil }
        let bytes = [UInt8](tail)
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int64 { Int64(b[o]) | Int64(b[o+1]) << 8 | Int64(b[o+2]) << 16 | Int64(b[o+3]) << 24 }
        let count = u16(bytes, eocd + 10)
        let cdSize = u32(bytes, eocd + 12)
        let cdOff = u32(bytes, eocd + 16)
        guard cdOff != 0xFFFFFFFF, cdSize > 0, cdSize < 256 << 20 else { return nil }
        try? fh.seek(toOffset: UInt64(cdOff))
        guard let cdData = try? fh.read(upToCount: Int(cdSize)) else { return nil }
        let cd = [UInt8](cdData)
        var result: [String: Int64] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd[p] == 0x50, cd[p+1] == 0x4b, cd[p+2] == 0x01, cd[p+3] == 0x02 else { break }
            let csize = u32(cd, p + 20)
            let nlen = u16(cd, p + 28), elen = u16(cd, p + 30), clen = u16(cd, p + 32)
            guard p + 46 + nlen <= cd.count else { break }
            let name = String(decoding: cd[(p+46)..<(p+46+nlen)], as: UTF8.self)
            result[Archive.normalize(name, isDir: name.hasSuffix("/"))] = csize
            p += 46 + nlen + elen + clen
        }
        return result
    }
}
