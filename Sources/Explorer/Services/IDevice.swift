import AppKit
import Combine
import ExplorerKit

/// iOS device browsing over AFC using libimobiledevice, loaded at runtime with dlopen
/// (Homebrew: `brew install libimobiledevice`). Without the library the "iOS Devices" node stays empty.
final class IDeviceRegistry: ObservableObject {
    static let shared = IDeviceRegistry()

    struct Device: Hashable, Identifiable {
        enum PairState { case paired, needsTrust, failed }
        var id: String { udid }
        var udid: String
        var name: String
        var network: Bool
        var state: PairState
    }

    @Published private(set) var devices: [Device] = []
    let lib = IMDLib.load()
    private var timer: Timer?
    private var clients: [String: AFCClient] = [:]
    private let queue = DispatchQueue(label: "idevice")

    var isAvailable: Bool { lib != nil }

    init() {
        guard lib != nil else { return }
        // Poll the device list (usbmuxd events would need a C callback trampoline; polling is simple and cheap).
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self, let lib = self.lib else { return }
            var found: [Device] = []
            for (udid, net) in lib.deviceList() {
                let existing = self.devices.first { $0.udid == udid }
                if let existing, existing.state == .paired { found.append(existing); continue }
                switch lib.deviceName(udid: udid, network: net) {
                case .success(let name): found.append(Device(udid: udid, name: name, network: net, state: .paired))
                case .failure(let e): found.append(Device(udid: udid, name: e == .needsTrust ? "Tap Trust on Device" : "Reconnect to pair", network: net, state: e == .needsTrust ? .needsTrust : .failed))
                }
            }
            let gone = Set(self.clients.keys).subtracting(found.map(\.udid))
            for g in gone { self.clients.removeValue(forKey: g) }
            DispatchQueue.main.async { if found != self.devices { self.devices = found } }
        }
    }

    func treeNodes() -> [TreeNode] {
        devices.map { d in
            let n = TreeNode(d.state == .paired ? .folder(Self.virtualURL(d.udid, "/")) : .placeholder(d.name), title: d.name, symbol: "iphone")
            return n
        }
    }

    /// Device folders are represented in the tree with a virtual file URL under /.explorer-device/<udid>/...
    static let virtualRoot = "/.explorer-device"
    static func virtualURL(_ udid: String, _ path: String) -> URL {
        URL(fileURLWithPath: virtualRoot + "/" + udid + (path == "/" ? "" : path), isDirectory: true)
    }
    static func parseVirtual(_ u: URL) -> (String, String)? {
        let p = u.path
        guard p.hasPrefix(virtualRoot + "/") else { return nil }
        let rest = String(p.dropFirst(virtualRoot.count + 1))
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? "/" + parts[1] : "/")
    }

    func client(_ udid: String) throws -> AFCClient {
        if let c = clients[udid] { return c }
        guard let lib else { throw OpError.message("iOS device is not connected") }
        let net = devices.first { $0.udid == udid }?.network ?? false
        let c = try AFCClient(lib: lib, udid: udid, network: net)
        clients[udid] = c
        return c
    }

    func deviceName(_ udid: String) -> String { devices.first { $0.udid == udid }?.name ?? "iOS Device" }

    // MARK: Listing

    func list(udid: String, path: String) throws -> [FileItem] {
        let c = try queue.sync { try client(udid) }
        return try c.list(path).map { e in
            let u = Self.virtualURL(udid, e.path)
            let ext = (e.name as NSString).pathExtension
            let type = e.isDir ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
            return FileItem(url: u, name: e.name, isDirectory: e.isDir, isSymlink: e.isLink, isHidden: e.name.hasPrefix("."),
                            size: e.isDir ? nil : e.size, modified: e.mtime, typeIdentifier: type.identifier,
                            kind: type.localizedDescription ?? "")
        }
    }

    // MARK: Transfers

    /// Downloads device items (recursively) into a local folder.
    func download(udid: String, paths: [String], to dir: URL, progress: ((String) -> Void)? = nil) throws -> [URL] {
        let c = try client(udid)
        var out: [URL] = []
        for p in paths {
            let name = (p as NSString).lastPathComponent
            let dest = FileNaming.uniqueURL(in: dir, name: name)
            try c.download(p, to: dest, progress: progress)
            out.append(dest)
        }
        return out
    }

    func upload(udid: String, files: [URL], to path: String, progress: ((String) -> Void)? = nil) throws {
        let c = try client(udid)
        for f in files { try c.upload(f, to: (path as NSString).appendingPathComponent(f.lastPathComponent), progress: progress) }
    }

    func remove(udid: String, paths: [String]) throws { let c = try client(udid); for p in paths { try c.removeRecursive(p) } }
    func rename(udid: String, from: String, to: String) throws {
        if (from as NSString).deletingLastPathComponent == "/" { throw OpError.message("Cannot rename top-level iOS device folders.") }
        try client(udid).rename(from, to)
    }
    func makeDirectory(udid: String, path: String) throws { try client(udid).mkdir(path) }
}

import UniformTypeIdentifiers

// MARK: - dlopen bridge

final class IMDLib {
    typealias idevice_t = OpaquePointer
    typealias lockdownd_t = OpaquePointer
    typealias afc_t = OpaquePointer

    struct ServiceDescriptor { var port: UInt16; var sslEnabled: UInt8; var identifier: UnsafeMutablePointer<CChar>? }
    struct DeviceInfo { var udid: UnsafeMutablePointer<CChar>?; var conn_type: Int32; var conn_data: UnsafeMutableRawPointer? }

    let handle: UnsafeMutableRawPointer
    let get_device_list_extended: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutableRawPointer?>?>, UnsafeMutablePointer<Int32>) -> Int32
    let device_list_extended_free: @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    let new_with_options: @convention(c) (UnsafeMutablePointer<idevice_t?>, UnsafePointer<CChar>, Int32) -> Int32
    let device_free: @convention(c) (idevice_t?) -> Int32
    let lockdown_new_handshake: @convention(c) (idevice_t?, UnsafeMutablePointer<lockdownd_t?>, UnsafePointer<CChar>) -> Int32
    let lockdown_free: @convention(c) (lockdownd_t?) -> Int32
    let lockdown_get_name: @convention(c) (lockdownd_t?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    let lockdown_start_service: @convention(c) (lockdownd_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let service_descriptor_free: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let afc_new: @convention(c) (idevice_t?, UnsafeMutableRawPointer?, UnsafeMutablePointer<afc_t?>) -> Int32
    let afc_free: @convention(c) (afc_t?) -> Int32
    let afc_read_directory: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> Int32
    let afc_get_file_info: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> Int32
    let afc_dictionary_free: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    let afc_file_open: @convention(c) (afc_t?, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UInt64>) -> Int32
    let afc_file_close: @convention(c) (afc_t?, UInt64) -> Int32
    let afc_file_read: @convention(c) (afc_t?, UInt64, UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    let afc_file_write: @convention(c) (afc_t?, UInt64, UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    let afc_remove_path: @convention(c) (afc_t?, UnsafePointer<CChar>) -> Int32
    let afc_rename_path: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    let afc_make_directory: @convention(c) (afc_t?, UnsafePointer<CChar>) -> Int32

    static func load() -> IMDLib? {
        let candidates = ["/opt/homebrew/lib/libimobiledevice-1.0.dylib", "/usr/local/lib/libimobiledevice-1.0.dylib",
                          "/opt/homebrew/lib/libimobiledevice-1.0.6.dylib", "/usr/local/lib/libimobiledevice-1.0.6.dylib"]
        for c in candidates {
            if let h = dlopen(c, RTLD_NOW), let l = IMDLib(h) { return l }
        }
        return nil
    }

    private init?(_ h: UnsafeMutableRawPointer) {
        handle = h
        func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let a: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutableRawPointer?>?>, UnsafeMutablePointer<Int32>) -> Int32 = sym("idevice_get_device_list_extended"),
              let b: @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 = sym("idevice_device_list_extended_free"),
              let c: @convention(c) (UnsafeMutablePointer<idevice_t?>, UnsafePointer<CChar>, Int32) -> Int32 = sym("idevice_new_with_options"),
              let d: @convention(c) (idevice_t?) -> Int32 = sym("idevice_free"),
              let e: @convention(c) (idevice_t?, UnsafeMutablePointer<lockdownd_t?>, UnsafePointer<CChar>) -> Int32 = sym("lockdownd_client_new_with_handshake"),
              let f: @convention(c) (lockdownd_t?) -> Int32 = sym("lockdownd_client_free"),
              let g: @convention(c) (lockdownd_t?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 = sym("lockdownd_get_device_name"),
              let i: @convention(c) (lockdownd_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = sym("lockdownd_start_service"),
              let j: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = sym("lockdownd_service_descriptor_free"),
              let k: @convention(c) (idevice_t?, UnsafeMutableRawPointer?, UnsafeMutablePointer<afc_t?>) -> Int32 = sym("afc_client_new"),
              let l: @convention(c) (afc_t?) -> Int32 = sym("afc_client_free"),
              let m: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> Int32 = sym("afc_read_directory"),
              let n: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> Int32 = sym("afc_get_file_info"),
              let o: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 = sym("afc_dictionary_free"),
              let p: @convention(c) (afc_t?, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UInt64>) -> Int32 = sym("afc_file_open"),
              let q: @convention(c) (afc_t?, UInt64) -> Int32 = sym("afc_file_close"),
              let r: @convention(c) (afc_t?, UInt64, UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Int32 = sym("afc_file_read"),
              let s: @convention(c) (afc_t?, UInt64, UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Int32 = sym("afc_file_write"),
              let t: @convention(c) (afc_t?, UnsafePointer<CChar>) -> Int32 = sym("afc_remove_path"),
              let u: @convention(c) (afc_t?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = sym("afc_rename_path"),
              let v: @convention(c) (afc_t?, UnsafePointer<CChar>) -> Int32 = sym("afc_make_directory")
        else { return nil }
        get_device_list_extended = a; device_list_extended_free = b; new_with_options = c; device_free = d
        lockdown_new_handshake = e; lockdown_free = f; lockdown_get_name = g; lockdown_start_service = i
        service_descriptor_free = j; afc_new = k; afc_free = l; afc_read_directory = m; afc_get_file_info = n
        afc_dictionary_free = o; afc_file_open = p; afc_file_close = q; afc_file_read = r; afc_file_write = s
        afc_remove_path = t; afc_rename_path = u; afc_make_directory = v
    }

    static let LOOKUP_USBMUX: Int32 = 1 << 1
    static let LOOKUP_NETWORK: Int32 = 1 << 2

    func deviceList() -> [(String, Bool)] {
        var list: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        var count: Int32 = 0
        guard get_device_list_extended(&list, &count) == 0, let list else { return [] }
        defer { _ = device_list_extended_free(list) }
        var out: [(String, Bool)] = []
        var seen = Set<String>()
        for i in 0..<Int(count) {
            // struct idevice_info { char *udid; enum idevice_connection_type conn_type; void *conn_data; }
            guard let raw = list[i] else { continue }
            let info = raw.assumingMemoryBound(to: DeviceInfo.self).pointee
            guard let u = info.udid else { continue }
            let udid = String(cString: u)
            let net = info.conn_type == 2
            if seen.insert(udid).inserted { out.append((udid, net)) }
        }
        return out
    }

    enum PairError: Error { case needsTrust, failed }

    func deviceName(udid: String, network: Bool) -> Result<String, PairError> {
        var dev: idevice_t?
        guard new_with_options(&dev, udid, network ? Self.LOOKUP_NETWORK : Self.LOOKUP_USBMUX) == 0 else { return .failure(.failed) }
        defer { _ = device_free(dev) }
        var ld: lockdownd_t?
        let r = lockdown_new_handshake(dev, &ld, "Explorer")
        guard r == 0 else { return .failure(r == -18 || r == -19 || r == -5 ? .needsTrust : .failed) }  // PAIRING_DIALOG_RESPONSE_PENDING / USER_DENIED / PASSWORD_PROTECTED
        defer { _ = lockdown_free(ld) }
        var name: UnsafeMutablePointer<CChar>?
        guard lockdown_get_name(ld, &name) == 0, let name else { return .success("iOS Device") }
        defer { free(name) }
        return .success(String(cString: name))
    }
}

final class AFCClient {
    struct Entry { var name: String; var path: String; var isDir: Bool; var isLink: Bool; var size: Int64; var mtime: Date? }
    let lib: IMDLib
    private var dev: IMDLib.idevice_t?
    private var afc: IMDLib.afc_t?
    private let lock = NSLock()

    init(lib: IMDLib, udid: String, network: Bool) throws {
        self.lib = lib
        guard lib.new_with_options(&dev, udid, network ? IMDLib.LOOKUP_NETWORK : IMDLib.LOOKUP_USBMUX) == 0 else { throw OpError.message("iOS device is not connected") }
        var ld: IMDLib.lockdownd_t?
        guard lib.lockdown_new_handshake(dev, &ld, "Explorer") == 0 else { throw OpError.message("Tap Trust on Device") }
        defer { _ = lib.lockdown_free(ld) }
        var svc: UnsafeMutableRawPointer?
        guard lib.lockdown_start_service(ld, "com.apple.afc", &svc) == 0 else { throw OpError.message("Could not start AFC on the device.") }
        defer { _ = lib.service_descriptor_free(svc) }
        guard lib.afc_new(dev, svc, &afc) == 0 else { throw OpError.message("Could not connect to the device filesystem.") }
    }

    deinit { _ = lib.afc_free(afc); _ = lib.device_free(dev) }

    private func check(_ r: Int32, _ what: String) throws {
        if r != 0 { throw OpError.message("\(what) failed (AFC error \(r))") }
    }

    func info(_ path: String) -> [String: String] {
        var dict: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        guard lib.afc_get_file_info(afc, path, &dict) == 0, let dict else { return [:] }
        defer { _ = lib.afc_dictionary_free(dict) }
        var out: [String: String] = [:]
        var i = 0
        while let k = dict[i], let v = dict[i + 1] { out[String(cString: k)] = String(cString: v); i += 2 }
        return out
    }

    func list(_ path: String) throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var arr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        try check(lib.afc_read_directory(afc, path, &arr), "Reading folder")
        guard let arr else { return [] }
        defer { _ = lib.afc_dictionary_free(arr) }
        var names: [String] = []
        var i = 0
        while let p = arr[i] { let n = String(cString: p); if n != "." && n != ".." { names.append(n) }; i += 1 }
        return names.map { n in
            let full = (path as NSString).appendingPathComponent(n)
            let inf = info(full)
            let fmt = inf["st_ifmt"] ?? ""
            let mtime = inf["st_mtime"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1e9) }
            return Entry(name: n, path: full, isDir: fmt == "S_IFDIR", isLink: fmt == "S_IFLNK", size: Int64(inf["st_size"] ?? "0") ?? 0, mtime: mtime)
        }
    }

    func download(_ path: String, to dest: URL, progress: ((String) -> Void)?) throws {
        let inf = info(path)
        if inf["st_ifmt"] == "S_IFDIR" {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for e in try list(path) { try download(e.path, to: dest.appendingPathComponent(e.name), progress: progress) }
            return
        }
        progress?((path as NSString).lastPathComponent)
        lock.lock(); defer { lock.unlock() }
        var h: UInt64 = 0
        try check(lib.afc_file_open(afc, path, 1 /* RDONLY */, &h), "Opening file")
        defer { _ = lib.afc_file_close(afc, h) }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }
        var buf = [CChar](repeating: 0, count: 1 << 18)
        while true {
            var n: UInt32 = 0
            try check(lib.afc_file_read(afc, h, &buf, UInt32(buf.count), &n), "Reading file")
            if n == 0 { break }
            buf.withUnsafeBytes { fh.write(Data($0.prefix(Int(n)))) }
        }
        if let m = inf["st_mtime"].flatMap(Double.init) {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: m / 1e9)], ofItemAtPath: dest.path)
        }
    }

    func upload(_ src: URL, to path: String, progress: ((String) -> Void)?) throws {
        var d: ObjCBool = false
        FileManager.default.fileExists(atPath: src.path, isDirectory: &d)
        if d.boolValue {
            try mkdir(path)
            for c in try FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                try upload(c, to: (path as NSString).appendingPathComponent(c.lastPathComponent), progress: progress)
            }
            return
        }
        progress?(src.lastPathComponent)
        lock.lock(); defer { lock.unlock() }
        var h: UInt64 = 0
        try check(lib.afc_file_open(afc, path, 3 /* WRONLY|CREAT|TRUNC */, &h), "AFC write")
        defer { _ = lib.afc_file_close(afc, h) }
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        while true {
            let chunk = fh.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            var written: UInt32 = 0
            let r = chunk.withUnsafeBytes { lib.afc_file_write(afc, h, $0.bindMemory(to: CChar.self).baseAddress!, UInt32(chunk.count), &written) }
            if r != 0 { throw OpError.message("AFC write failed") }
        }
    }

    func mkdir(_ path: String) throws { lock.lock(); defer { lock.unlock() }; try check(lib.afc_make_directory(afc, path), "Creating folder") }
    func rename(_ a: String, _ b: String) throws { lock.lock(); defer { lock.unlock() }; try check(lib.afc_rename_path(afc, a, b), "Renaming") }

    func removeRecursive(_ path: String) throws {
        if info(path)["st_ifmt"] == "S_IFDIR" { for e in try list(path) { try removeRecursive(e.path) } }
        lock.lock(); defer { lock.unlock() }
        try check(lib.afc_remove_path(afc, path), "Deleting")
    }
}
