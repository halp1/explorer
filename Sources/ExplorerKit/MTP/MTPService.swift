import Foundation
import Combine
import Darwin
import UniformTypeIdentifiers

/// Synchronous operations must be called from a worker thread. Native work is
/// serialized with discovery. Only canWrite and the published snapshot are UI APIs.
public final class MTPService: ObservableObject {
    public static let shared = MTPService()
    private static let nativeQueue = DispatchQueue(label: "Explorer.MTP", qos: .utility)
    @Published public private(set) var devices: [MTPDevice] = []
    public let isAvailable: Bool

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let transport: MTPTransport
    private var timer: DispatchSourceTimer?
    private var connections: [String: MTPConnection] = [:]
    private var lastPublished: [MTPDevice] = []
    private let snapshotLock = NSLock()
    private var writable: Set<String> = []
    private let fm = FileManager.default
    private let maxDepth = 128

    public convenience init() {
        let queue = Self.nativeQueue
        let transport = queue.sync { NativeMTPTransport() }
        self.init(transport: transport, queue: queue, polling: true)
    }

    init(transport: MTPTransport, queue: DispatchQueue = DispatchQueue(label: "Explorer.MTP.tests"), polling: Bool = false) {
        self.transport = transport
        self.queue = queue
        isAvailable = transport.isAvailable
        queue.setSpecific(key: queueKey, value: true)
        if polling {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(3))
            timer.setEventHandler { [weak self] in self?.refreshOnQueue() }
            self.timer = timer
            timer.resume()
        } else {
            queue.sync { refreshOnQueue() }
        }
    }

    deinit {
        timer?.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == true {
            transport.shutdown()
        } else {
            queue.sync { transport.shutdown() }
        }
    }

    private func perform<T>(_ work: () throws -> T) throws -> T {
        try queue.sync {
            do { return try work() }
            catch {
                let lost = connections.keys.filter { !transport.isConnected($0) }
                if !lost.isEmpty {
                    for id in lost { connections.removeValue(forKey: id) }
                    snapshotLock.lock()
                    writable = Set(connections.values.flatMap { device in
                        device.storages.filter(\.writable).map { writeKey(device.id, device.session, $0.id) }
                    })
                    snapshotLock.unlock()
                    publishIfChanged(lastPublished.filter { !lost.contains($0.id) })
                }
                throw error
            }
        }
    }

    /// A cache read only. Never waits for USB or the discovery queue.
    public func canWrite(_ address: MTPAddress) -> Bool {
        guard let storage = address.storageID else { return false }
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return writable.contains(writeKey(address.deviceID, address.sessionID, storage))
    }

    private func writeKey(_ device: String, _ session: String, _ storage: UInt32) -> String {
        "\(device)/\(session)/\(storage)"
    }

    func refreshDiscovery() { queue.sync { refreshOnQueue() } }

    private func refreshOnQueue() {
        let found: [MTPConnection]
        do { found = try transport.discover() }
        catch {
            connections = [:]
            snapshotLock.lock()
            writable = []
            snapshotLock.unlock()
            publishIfChanged([])
            return
        }
        connections = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var writes: Set<String> = []
        for device in found where device.error == nil {
            for storage in device.storages where storage.writable {
                writes.insert(writeKey(device.id, device.session, storage.id))
            }
        }
        snapshotLock.lock()
        writable = writes
        snapshotLock.unlock()
        let published = found.map {
            MTPDevice(id: $0.id, name: $0.name,
                      address: MTPAddress(deviceID: $0.id, sessionID: $0.session, deviceName: $0.name), errorMessage: $0.error)
        }
        publishIfChanged(published)
    }

    private func publishIfChanged(_ snapshot: [MTPDevice]) {
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        DispatchQueue.main.async { [weak self] in self?.devices = snapshot }
    }

    private func connection(_ address: MTPAddress, writing: Bool = false) throws -> MTPConnection {
        guard let device = connections[address.deviceID], device.session == address.sessionID else {
            throw OpError.message("Device disconnected or this location belongs to an old connection. Reopen the device.")
        }
        if let error = device.error { throw OpError.message(error) }
        guard address.components.count <= maxDepth, address.storageID != nil || address.components.isEmpty else {
            throw OpError.message("Invalid device location")
        }
        if let storage = address.storageID {
            guard let entry = device.storages.first(where: { $0.id == storage }) else { throw OpError.message("Storage disconnected") }
            if writing && !entry.writable { throw OpError.message("Device storage is read-only") }
        } else if writing {
            throw OpError.message("Choose a storage folder first")
        }
        return device
    }

    private func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw OpError.message("Device supplied an unsafe file name")
        }
    }

    private func children(_ address: MTPAddress) throws -> [MTPObject] {
        guard let storage = address.storageID else { throw OpError.message("Choose a storage folder first") }
        let parent = address.objectID ?? UInt32.max
        let result = try transport.list(address.deviceID, storage: storage, parent: parent)
        var ids = Set<UInt32>()
        for object in result {
            try validName(object.name)
            guard object.id != 0, object.id != UInt32.max, ids.insert(object.id).inserted,
                  object.storage == storage,
                  object.parent == parent || (parent == UInt32.max && object.parent == 0) else {
                throw OpError.message("Device supplied an invalid object listing")
            }
        }
        return result
    }

    /// Resolve every ancestor by handle, not by untrusted path text.
    private func resolve(_ address: MTPAddress) throws -> MTPObject? {
        _ = try connection(address)
        var cursor = address
        cursor.components = []
        var result: MTPObject?
        var seen = Set<UInt32>()
        for component in address.components {
            try validName(component.name)
            guard seen.insert(component.id).inserted,
                  let object = try children(cursor).first(where: { $0.id == component.id }),
                  object.name == component.name else { throw OpError.message("Device item is stale or invalid") }
            if let previous = result, !previous.folder { throw OpError.message("Device ancestor is not a folder") }
            result = object
            cursor = cursor.appending(id: object.id, name: object.name)
        }
        return result
    }

    public func list(_ address: MTPAddress) throws -> [FileItem] {
        try perform {
            let device = try connection(address)
            if address.storageID == nil {
                return try device.storages.map { storage in
                    try validName(storage.name)
                    var a = address
                    a.storageID = storage.id
                    a.storageName = storage.name
                    return item(a, folder: true, locked: !storage.writable)
                }
            }
            if let object = try resolve(address), !object.folder { throw OpError.message("Not a device folder") }
            let locked = !canWrite(address)
            return try children(address).map { object in
                item(address.appending(id: object.id, name: object.name), folder: object.folder, locked: locked,
                     size: object.folder ? nil : Int64(clamping: object.size), modified: object.modified)
            }
        }
    }

    private func item(_ address: MTPAddress, folder: Bool, locked: Bool, size: Int64? = nil, modified: Date? = nil) -> FileItem {
        let type = folder ? UTType.folder : UTType(filenameExtension: (address.title as NSString).pathExtension)
        var row = FileItem(url: address.url, name: address.title, isDirectory: folder, isHidden: address.title.hasPrefix("."),
                           isLocked: locked, size: size, modified: modified, typeIdentifier: type?.identifier,
                           kind: type?.localizedDescription ?? (folder ? "Folder" : "File"))
        row.mtpAddress = address
        return row
    }

    public func rename(_ address: MTPAddress, to name: String) throws {
        try perform {
            _ = try connection(address, writing: true)
            try validName(name)
            guard let object = try resolve(address), let parent = address.parent else { throw OpError.message("Device roots cannot be renamed") }
            let siblings = try children(parent)
            guard !siblings.contains(where: { $0.id != object.id && folded($0.name) == folded(name) }) else { throw OpError.message("An item with that name already exists") }
            try transport.rename(address.deviceID, id: object.id, name: name)
        }
    }

    public func makeDirectory(_ name: String, in address: MTPAddress) throws {
        try perform {
            _ = try connection(address, writing: true)
            try validName(name)
            if let object = try resolve(address), !object.folder { throw OpError.message("Not a device folder") }
            guard !(try children(address)).contains(where: { folded($0.name) == folded(name) }) else { throw OpError.message("An item with that name already exists") }
            _ = try transport.mkdir(address.deviceID, name: name, storage: address.storageID!, parent: address.objectID ?? 0)
        }
    }

    private struct RemoteTree {
        var address: MTPAddress
        var folder: Bool
        var size: UInt64
        var modified: Date?
        var children: [RemoteTree]
    }

    private func remoteTree(_ address: MTPAddress, seen: inout Set<String>, progress: MTPProgress, depth: Int = 0) throws -> RemoteTree {
        try checkpoint(progress, 0, address.title)
        guard depth <= maxDepth, seen.count < 100_000, seen.insert(address.deviceID + "/" + String(address.storageID ?? 0) + "/" + String(address.objectID ?? 0)).inserted else {
            throw OpError.message("Device folder cycle or nesting limit exceeded")
        }
        try validName(address.title)
        let object = try resolve(address)
        guard address.storageID != nil else { throw OpError.message("Choose a storage or item to copy") }
        let folder = object?.folder ?? true
        let descendants = folder ? try children(address) : []
        var trees: [RemoteTree] = []
        for child in descendants {
            trees.append(try remoteTree(address.appending(id: child.id, name: child.name), seen: &seen, progress: progress, depth: depth + 1))
        }
        return RemoteTree(address: address, folder: folder, size: object?.size ?? 0, modified: object?.modified, children: trees)
    }

    private func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func keepBoth(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var suffix = 2
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while used.contains(folded(candidate)) {
            candidate = "\(stem) (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
            suffix += 1
        }
        used.insert(folded(candidate))
        return candidate
    }

    private func checkpoint(_ progress: MTPProgress, _ amount: Double, _ name: String) throws {
        if !progress(min(1, max(0, amount)), name) { throw OpError.cancelled }
    }

    public func remove(_ addresses: [MTPAddress], progress: @escaping MTPProgress) throws {
        try perform {
            var seen = Set<String>()
            var trees: [RemoteTree] = []
            for address in addresses {
                _ = try connection(address, writing: true)
                guard address.objectID != nil else { throw OpError.message("Device roots cannot be deleted") }
                trees.append(try remoteTree(address, seen: &seen, progress: progress))
            }
            var deleted = 0
            func erase(_ tree: RemoteTree) throws {
                try checkpoint(progress, 0, tree.address.title)
                for child in tree.children { try erase(child) }
                try transport.remove(tree.address.deviceID, id: tree.address.objectID!)
                deleted += 1
            }
            do {
                for tree in trees { try erase(tree) }
                // Cancellation after the last committed delete cannot undo that delete.
                _ = progress(1, "")
            } catch {
                if deleted > 0 {
                    throw OpError.message("Deleted \(deleted) device items. The remaining selection was not completed: \(error.localizedDescription)")
                }
                throw error
            }
        }
    }

    public func download(_ addresses: [MTPAddress], to dir: URL, progress: @escaping MTPProgress) throws -> [URL] {
        try perform {
            try LocalFileBoundary.require([dir])
            var seen = Set<String>()
            let trees = try addresses.map { try remoteTree($0, seen: &seen, progress: progress) }
            try checkpoint(progress, 0, "")
            let root = dir.resolvingSymlinksInPath().standardizedFileURL
            let destinationFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard destinationFD >= 0 else { throw OpError.message("Download destination is not an accessible folder") }
            defer { close(destinationFD) }
            let temporaryName = ".explorer-mtp-" + UUID().uuidString
            guard mkdirat(destinationFD, temporaryName, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let stagingFD = openat(destinationFD, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stagingFD >= 0 else {
                unlinkat(destinationFD, temporaryName, AT_REMOVEDIR)
                throw OpError.message("Unable to create download staging folder")
            }
            defer {
                // The directory was exclusively created by this operation. Never remove destination items.
                cleanOwnedDirectory(stagingFD)
                close(stagingFD)
                unlinkat(destinationFD, temporaryName, AT_REMOVEDIR)
            }
            func receive(_ tree: RemoteTree, parentFD: Int32, name: String, base: Double, span: Double) throws {
                try checkpoint(progress, base, tree.address.title)
                if tree.folder {
                    guard mkdirat(parentFD, name, 0o700) == 0 else { throw OpError.message("Unable to create download folder") }
                    let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw OpError.message("Unable to open download folder") }
                    defer { close(fd) }
                    var used = Set<String>()
                    for (index, child) in tree.children.enumerated() {
                        let childName = keepBoth(child.address.title, used: &used)
                        try receive(child, parentFD: fd, name: childName, base: base + span * Double(index) / Double(max(1, tree.children.count)), span: span / Double(max(1, tree.children.count)))
                    }
                    preserveModified(tree.modified, fd: fd)
                } else {
                    let fd = openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw OpError.message("Unable to create download file") }
                    defer { close(fd) }
                    try transport.download(tree.address.deviceID, id: tree.address.objectID!, fd: fd) { sent, total in
                        progress(base + span * (total > 0 ? min(1, Double(sent) / Double(total)) : 0), tree.address.title)
                    }
                    var stat = Darwin.stat()
                    guard fstat(fd, &stat) == 0, stat.st_size >= 0, UInt64(stat.st_size) == tree.size, fsync(fd) == 0 else {
                        throw OpError.message("Downloaded file size does not match device metadata")
                    }
                    preserveModified(tree.modified, fd: fd)
                }
                try checkpoint(progress, base + span, tree.address.title)
            }
            // Finish the complete selection before publishing any destination files.
            for (index, tree) in trees.enumerated() {
                try receive(tree, parentFD: stagingFD, name: String(index), base: Double(index) / Double(max(1, trees.count)), span: 1 / Double(max(1, trees.count)))
            }
            var used = Set(try directoryNames(destinationFD).map(folded))
            var results: [URL] = []
            do {
                for (index, tree) in trees.enumerated() {
                    var name = keepBoth(tree.address.title, used: &used)
                    while renameatx_np(stagingFD, String(index), destinationFD, name, UInt32(RENAME_EXCL)) != 0 {
                        guard errno == EEXIST else { throw OpError.message("Unable to publish completed download") }
                        name = keepBoth(tree.address.title, used: &used)
                    }
                    results.append(root.appendingPathComponent(name, isDirectory: tree.folder))
                }
            } catch {
                if !results.isEmpty {
                    throw OpError.message("Completed downloads already saved: \(results.map(\.lastPathComponent).joined(separator: ", ")). Other selected items were not published: \(error.localizedDescription)")
                }
                throw error
            }
            return results
        }
    }

    private func preserveModified(_ date: Date?, fd: Int32) {
        guard let seconds = date?.timeIntervalSince1970, seconds.isFinite,
              seconds > Double(Int.min), seconds < Double(Int.max) else { return }
        var times = [timeval(tv_sec: Int(seconds), tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: 0)]
        // Some destination filesystems do not support changing timestamps.
        _ = futimes(fd, &times)
    }

    private func directoryNames(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw OpError.message("Unable to read download directory") }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw OpError.message("Unable to read download directory")
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func cleanOwnedDirectory(_ fd: Int32) {
        for name in (try? directoryNames(fd)) ?? [] {
            var st = Darwin.stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 {
                    cleanOwnedDirectory(child)
                    close(child)
                    unlinkat(fd, name, AT_REMOVEDIR)
                }
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }

    private struct LocalTree {
        var url: URL
        var name: String
        var folder: Bool
        var size: UInt64
        var device: dev_t
        var inode: ino_t
        var children: [LocalTree]
    }

    private func localTree(_ url: URL, seen: inout Set<String>, progress: MTPProgress, depth: Int = 0) throws -> LocalTree {
        try checkpoint(progress, 0, url.lastPathComponent)
        guard seen.count < 100_000 else { throw OpError.message("Upload item limit exceeded") }
        try LocalFileBoundary.require([url])
        try validName(url.lastPathComponent)
        var st = Darwin.stat()
        guard depth <= maxDepth, lstat(url.path, &st) == 0 else { throw OpError.message("Local item is inaccessible or too deeply nested") }
        let type = st.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw OpError.message("Symbolic links and special files cannot be uploaded. No files were transferred.") }
        guard seen.insert("\(st.st_dev):\(st.st_ino)").inserted else { throw OpError.message("Repeated local item or folder cycle") }
        let folder = type == S_IFDIR
        var children: [LocalTree] = []
        if folder {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                children.append(try localTree(child, seen: &seen, progress: progress, depth: depth + 1))
            }
        }
        return LocalTree(url: url, name: url.lastPathComponent, folder: folder, size: UInt64(max(0, st.st_size)), device: st.st_dev, inode: st.st_ino, children: children)
    }

    private func existingObjectIDs(_ address: MTPAddress, progress: MTPProgress) throws -> Set<UInt32> {
        let device = try connection(address)
        var ids = Set<UInt32>()
        for storage in device.storages {
            var root = address
            root.storageID = storage.id
            root.storageName = storage.name
            root.components = []
            var pending: [(MTPAddress, Int)] = [(root, 0)]
            while let (parent, depth) = pending.popLast() {
                try checkpoint(progress, 0, parent.title)
                guard depth <= maxDepth else { throw OpError.message("Device nesting limit exceeded") }
                for object in try children(parent) {
                    guard ids.count < 100_000, ids.insert(object.id).inserted else {
                        throw OpError.message("Device cycle, duplicate handle or item limit exceeded")
                    }
                    if object.folder { pending.append((parent.appending(id: object.id, name: object.name), depth + 1)) }
                }
            }
        }
        return ids
    }

    public func upload(_ files: [URL], to address: MTPAddress, progress: @escaping MTPProgress) throws {
        try perform {
            _ = try connection(address, writing: true)
            if let object = try resolve(address), !object.folder { throw OpError.message("Not a device folder") }
            var seen = Set<String>()
            let trees = try files.map { try localTree($0, seen: &seen, progress: progress) }
            var created: [UInt32] = []
            let existing = try existingObjectIDs(address, progress: progress)
            func record(_ id: UInt32) {
                if !existing.contains(id), !created.contains(id) { created.append(id) }
            }
            func send(_ tree: LocalTree, to parent: MTPAddress, name: String, base: Double, span: Double) throws {
                try checkpoint(progress, base, tree.name)
                let fd = open(tree.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (tree.folder ? O_DIRECTORY : 0))
                guard fd >= 0 else { throw OpError.message("Local source changed during upload") }
                defer { close(fd) }
                var st = Darwin.stat()
                guard fstat(fd, &st) == 0, st.st_dev == tree.device, st.st_ino == tree.inode,
                      (st.st_mode & S_IFMT) == (tree.folder ? S_IFDIR : S_IFREG), tree.folder || UInt64(max(0, st.st_size)) == tree.size else {
                    throw OpError.message("Local source changed during upload")
                }
                if tree.folder {
                    let id = try transport.mkdir(parent.deviceID, name: name, storage: parent.storageID!, parent: parent.objectID ?? 0)
                    guard !existing.contains(id), !created.contains(id) else { throw OpError.message("Device reused an existing object handle") }
                    record(id)
                    let destination = parent.appending(id: id, name: name)
                    var used = Set<String>()
                    for (index, child) in tree.children.enumerated() {
                        try send(child, to: destination, name: keepBoth(child.name, used: &used), base: base + span * Double(index) / Double(max(1, tree.children.count)), span: span / Double(max(1, tree.children.count)))
                    }
                } else {
                    let id = try transport.upload(parent.deviceID, fd: fd, name: name, size: tree.size, storage: parent.storageID!, parent: parent.objectID ?? 0, created: record) { sent, total in
                        progress(base + span * (total > 0 ? min(1, Double(sent) / Double(total)) : 0), tree.name)
                    }
                    guard !existing.contains(id) else { throw OpError.message("Device reused an existing object handle") }
                    var after = Darwin.stat()
                    guard fstat(fd, &after) == 0, after.st_size == st.st_size,
                          after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec else {
                        throw OpError.message("Local source changed during upload")
                    }
                    let metadata = try children(parent).first { $0.id == id }
                    guard metadata?.size == tree.size, metadata?.name == name, metadata?.folder == false else { throw OpError.message("Uploaded file could not be verified") }
                }
                try checkpoint(progress, base + span, tree.name)
            }
            do {
                var used = Set(try children(address).map { folded($0.name) })
                for (index, tree) in trees.enumerated() {
                    try send(tree, to: address, name: keepBoth(tree.name, used: &used), base: Double(index) / Double(max(1, trees.count)), span: 1 / Double(max(1, trees.count)))
                }
            } catch {
                // Never reconnect to roll back old-session handles.
                var remaining = 0
                for id in created.reversed() {
                    guard transport.isConnected(address.deviceID) else {
                        remaining += 1
                        continue
                    }
                    do { try transport.remove(address.deviceID, id: id) }
                    catch { remaining += 1 }
                }
                if remaining > 0 {
                    throw OpError.message("Upload stopped and \(remaining) newly created device items could not be cleaned up. Partial files may remain on the device: \(error.localizedDescription)")
                }
                throw error
            }
        }
    }
}
