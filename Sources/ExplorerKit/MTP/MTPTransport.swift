import Foundation
import CMTP
import Darwin

public struct MTPDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let address: MTPAddress
    public let errorMessage: String?

    public init(id: String, name: String, address: MTPAddress, errorMessage: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.errorMessage = errorMessage
    }
}

public typealias MTPProgress = (Double, String) -> Bool

struct MTPStorage: Equatable {
    var id: UInt32
    var name: String
    var writable: Bool
}

struct MTPObject {
    var id: UInt32
    var parent: UInt32
    var storage: UInt32
    var name: String
    var size: UInt64 = 0
    var modified: Date? = nil
    var folder: Bool
}

struct MTPConnection {
    var id: String
    var session: String
    var name: String
    var storages: [MTPStorage]
    var error: String? = nil
}

/// All methods, including discovery and destruction, run on the service queue.
protocol MTPTransport: AnyObject {
    var isAvailable: Bool { get }
    func shutdown()
    func isConnected(_ device: String) -> Bool
    func discover() throws -> [MTPConnection]
    func list(_ device: String, storage: UInt32, parent: UInt32) throws -> [MTPObject]
    func download(_ device: String, id: UInt32, fd: Int32, progress: @escaping (UInt64, UInt64) -> Bool) throws
    func upload(_ device: String, fd: Int32, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                created: (UInt32) -> Void, progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32
    func mkdir(_ device: String, name: String, storage: UInt32, parent: UInt32) throws -> UInt32
    func rename(_ device: String, id: UInt32, name: String) throws
    func remove(_ device: String, id: UInt32) throws
}

extension MTPTransport {
    func shutdown() {}
    func isConnected(_ device: String) -> Bool { true }
}

private final class NativeProgress {
    let callback: (UInt64, UInt64) -> Bool
    var cancelled = false
    init(_ callback: @escaping (UInt64, UInt64) -> Bool) { self.callback = callback }
}

private let nativeProgress: @convention(c) (UInt64, UInt64, UnsafeRawPointer?) -> Int32 = { sent, total, raw in
    guard let raw else { return 1 }
    let box = Unmanaged<NativeProgress>.fromOpaque(raw).takeUnretainedValue()
    if box.cancelled || !box.callback(sent, total) {
        box.cancelled = true
        return 1
    }
    return 0
}

final class NativeMTPTransport: MTPTransport {
    private var context: OpaquePointer?
    private struct OpenDevice {
        var handle: OpaquePointer
        var id: String
        var session: String
        var name: String
    }
    private var opened: [String: OpenDevice] = [:]
    var isAvailable: Bool { context != nil }

    init() { context = cmtp_load() }
    deinit { shutdown() }

    func shutdown() {
        for device in opened.values { cmtp_close(device.handle) }
        opened = [:]
        cmtp_unload(context)
        context = nil
    }

    func discover() throws -> [MTPConnection] {
        guard let context else { return [] }
        var raw: UnsafeMutablePointer<CMTPCandidate>?
        var count = 0
        guard cmtp_detect(context, &raw, &count) == 0 else {
            for device in opened.values { cmtp_close(device.handle) }
            opened = [:]
            throw failure("Device discovery failed")
        }
        defer { cmtp_free_candidates(raw, count) }
        let candidates = (0..<count).map { (String(cString: raw![$0].key), String(cString: raw![$0].name)) }
        let present = Set(candidates.map(\.0))
        for key in Array(opened.keys) where !present.contains(key) {
            cmtp_close(opened.removeValue(forKey: key)!.handle)
        }
        var result: [MTPConnection] = []
        for (key, fallback) in candidates {
            if opened[key] == nil, let handle = cmtp_open(context, key) {
                let rawName = cmtp_name(handle)
                let name = rawName.map { String(cString: $0) } ?? fallback
                cmtp_free(rawName)
                let rawSerial = cmtp_serial(handle)
                let serial = rawSerial.map { String(cString: $0) } ?? ""
                cmtp_free(rawSerial)
                let product = key.split(separator: ":").prefix(2).joined(separator: ":")
                let serialID = serial.isEmpty ? key : "serial:" + product + ":" + serial
                // Broken devices sometimes report identical serials. Do not merge their handles.
                let id = opened.values.contains(where: { $0.id == serialID }) ? key : serialID
                opened[key] = OpenDevice(handle: handle, id: id, session: UUID().uuidString, name: name)
            }
            guard let device = opened[key] else {
                result.append(MTPConnection(id: key, session: "unavailable", name: fallback, storages: [], error: "Unlock the device and enable file transfer."))
                continue
            }
            var storages: UnsafeMutablePointer<CMTPStorage>?
            var n = 0
            let status = cmtp_storages(device.handle, &storages, &n)
            defer { cmtp_free_storages(storages, n) }
            if status != 0 {
                cmtp_close(device.handle)
                opened.removeValue(forKey: key)
                result.append(MTPConnection(id: device.id, session: "unavailable", name: device.name, storages: [], error: "Device storage is unavailable. Unlock the device and retry."))
                continue
            }
            result.append(MTPConnection(id: device.id, session: device.session, name: device.name,
                                        storages: (0..<n).map { MTPStorage(id: storages![$0].id, name: String(cString: storages![$0].name), writable: storages![$0].writable != 0) }))
        }
        return result
    }

    private func handle(_ device: String) throws -> OpaquePointer {
        guard let handle = opened.values.first(where: { $0.id == device })?.handle else { throw failure("Device disconnected") }
        return handle
    }
    func isConnected(_ device: String) -> Bool { opened.values.contains { $0.id == device } }

    private func failure(_ text: String) -> OpError { .message(text) }

    private func nativeFailure(_ device: String, _ fallback: String) -> Error {
        guard let pair = opened.first(where: { $0.value.id == device }) else { return failure(fallback) }
        let raw = cmtp_error(pair.value.handle)
        let detail = raw.map { String(cString: $0) }
        cmtp_free(raw)
        let cancelled = cmtp_cancelled(pair.value.handle) != 0
        if cmtp_connection_failed(pair.value.handle) != 0 {
            cmtp_close(pair.value.handle)
            opened.removeValue(forKey: pair.key)
        }
        if cancelled { return OpError.cancelled }
        return failure(detail.map { fallback + ": " + $0 } ?? fallback)
    }

    func list(_ device: String, storage: UInt32, parent: UInt32) throws -> [MTPObject] {
        let h = try handle(device)
        var raw: UnsafeMutablePointer<CMTPObject>?
        var n = 0
        guard cmtp_list(h, storage, parent, &raw, &n) == 0 else { throw nativeFailure(device, "Unable to list device folder") }
        defer { cmtp_free_objects(raw, n) }
        return (0..<n).map {
            let o = raw![$0]
            return MTPObject(id: o.id, parent: o.parent, storage: o.storage, name: String(cString: o.name), size: o.size,
                             modified: o.modified > 0 ? Date(timeIntervalSince1970: Double(o.modified)) : nil, folder: o.folder != 0)
        }
    }

    func download(_ device: String, id: UInt32, fd: Int32, progress: @escaping (UInt64, UInt64) -> Bool) throws {
        let box = NativeProgress(progress)
        let raw = Unmanaged.passUnretained(box).toOpaque()
        let status = cmtp_download(try handle(device), id, fd, nativeProgress, raw)
        if status != 0 {
            let error = nativeFailure(device, "Download failed")
            if box.cancelled { throw OpError.cancelled }
            throw error
        }
        if box.cancelled { throw OpError.cancelled }
    }

    func upload(_ device: String, fd: Int32, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                created: (UInt32) -> Void, progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        let box = NativeProgress(progress)
        let raw = Unmanaged.passUnretained(box).toOpaque()
        var id: UInt32 = 0
        let status = cmtp_upload(try handle(device), fd, name, size, storage, parent, &id, nativeProgress, raw)
        if id != 0 && id != UInt32.max { created(id) }
        if status != 0 || id == 0 || id == UInt32.max {
            let error = nativeFailure(device, "Upload failed")
            if box.cancelled { throw OpError.cancelled }
            throw error
        }
        if box.cancelled { throw OpError.cancelled }
        return id
    }

    func mkdir(_ device: String, name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let id = cmtp_mkdir(try handle(device), name, storage, parent)
        guard id != 0, id != UInt32.max else { throw nativeFailure(device, "Unable to create device folder") }
        return id
    }
    func rename(_ device: String, id: UInt32, name: String) throws {
        guard cmtp_rename(try handle(device), id, name) == 0 else { throw nativeFailure(device, "Rename failed") }
    }
    func remove(_ device: String, id: UInt32) throws {
        guard cmtp_remove(try handle(device), id) == 0 else { throw nativeFailure(device, "Delete failed") }
    }
}
