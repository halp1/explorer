import Foundation

/// Object handles are valid only for the connection session that issued them.
public struct MTPComponent: Codable, Hashable, Sendable {
    public var id: UInt32
    public var name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MTPAddress: Codable, Hashable, Sendable {
    public var deviceID: String
    public var sessionID: String
    public var deviceName: String
    public var storageID: UInt32?
    public var storageName: String?
    public var components: [MTPComponent]

    public init(deviceID: String, sessionID: String, deviceName: String,
                storageID: UInt32? = nil, storageName: String? = nil, components: [MTPComponent] = []) {
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.deviceName = deviceName
        self.storageID = storageID
        self.storageName = storageName
        self.components = components
    }

    public var objectID: UInt32? { components.last?.id }
    public var isRoot: Bool { components.isEmpty }
    public var title: String { components.last?.name ?? storageName ?? deviceName }
    public var id: String {
        let parts = [deviceID, sessionID, storageID.map(String.init) ?? "root"] + components.map { String($0.id) }
        return "mtp:" + (try! JSONEncoder().encode(parts)).base64EncodedString()
    }
    public var parent: MTPAddress? {
        var result = self
        if !components.isEmpty {
            result.components.removeLast()
        } else if storageID != nil {
            result.storageID = nil
            result.storageName = nil
        } else {
            return nil
        }
        return result
    }
    public func appending(id: UInt32, name: String) -> MTPAddress {
        var result = self
        result.components.append(MTPComponent(id: id, name: name))
        return result
    }

    /// Non-file identity URL. Never pass this to local filesystem operations.
    public var url: URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "mtp://device/" + payload)!
    }

    public init?(url: URL) {
        guard url.scheme == "mtp", url.host == "device", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2, url.absoluteString.utf8.count < 65536 else { return nil }
        var payload = url.lastPathComponent.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let address = try? JSONDecoder().decode(Self.self, from: data),
              !address.deviceID.isEmpty, !address.sessionID.isEmpty,
              address.components.count <= 256,
              address.storageID != nil || address.components.isEmpty,
              address.components.allSatisfy({ $0.id != 0 && $0.id != UInt32.max }) else { return nil }
        self = address
    }
}

/// Local file operations must also reject the legacy AFC virtual file URLs.
public enum LocalFileBoundary {
    public static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        return path != "/.explorer-device" && !path.hasPrefix("/.explorer-device/")
            && path != "/.explorer-mtp" && !path.hasPrefix("/.explorer-mtp/")
    }

    public static func require(_ urls: [URL]) throws {
        guard urls.allSatisfy(accepts) else {
            throw OpError.message("Device items must use device file operations.")
        }
    }
}
