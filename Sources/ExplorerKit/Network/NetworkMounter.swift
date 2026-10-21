import Foundation
import NetFS
import Network

public enum NetworkScheme: String, CaseIterable, Sendable {
    case smb, afp, nfs, http, https
    public var bonjourType: String? {
        switch self { case .smb: return "_smb._tcp"; case .afp: return "_afpovertcp._tcp"; case .nfs: return "_nfs._tcp"; default: return nil }
    }
}

public enum MountError: LocalizedError {
    case noGuest(String), notResponding(String), noShares(String), shareUnavailable(String)
    case passwordChange(String), permission(String), unsupported(String), cancelled, other(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noGuest(let s): return String(format: "The server “%@” does not allow guest access.", s)
        case .notResponding(let s): return String(format: "The server “%@” is not responding.", s)
        case .noShares(let s): return String(format: "The server “%@” has no shares available to you.", s)
        case .shareUnavailable(let s): return String(format: "The share “%@” is not available on this server.", s)
        case .passwordChange(let s): return String(format: "The password for “%@” must be changed before you can connect.", s)
        case .permission(let s): return String(format: "You do not have permission to connect to “%@”.", s)
        case .unsupported(let s): return String(format: "Explorer cannot connect to “%@”: the server is too old or uses an unsupported protocol.", s)
        case .cancelled: return "The operation was cancelled."
        case .other(let s, let code): return String(format: "Could not connect to “%@”.", s) + " (\(code))"
        }
    }

    static func from(code: Int32, url: URL) -> MountError {
        let host = url.host ?? url.absoluteString
        switch code {
        case ECANCELED, Int32(-128), Int32(userCanceledErr): return .cancelled
        case EAUTH: return .permission(host)
        case ENOENT: return .shareUnavailable(url.lastPathComponent)
        case ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ECONNREFUSED: return .notResponding(host)
        case EPROTONOSUPPORT, ENOTSUP, EPROGMISMATCH: return .unsupported(host)
        case EACCES, EPERM: return .permission(host)
        case Int32(-6602): return .noGuest(host)
        case Int32(-5998): return .noShares(host)
        case Int32(-6003): return .passwordChange(host)
        default: return .other(host, code)
        }
    }
}

public enum NetworkMounter {
    /// Mounts a share with the system UI for credentials. Completion on main queue with the mount points.
    public static func mount(_ url: URL, user: String? = nil, password: String? = nil, completion: @escaping (Result<[URL], MountError>) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        if user == nil && password == nil { openOptions[kNetFSUseGuestKey] = false }
        let mountOptions = NSMutableDictionary()
        var requestID: AsyncRequestID?
        let r = NetFSMountURLAsync(url as CFURL, nil, user as CFString?, password as CFString?, openOptions, mountOptions, &requestID, .main) { status, _, mountpoints in
            if status == 0 {
                let mps = (mountpoints as? [String] ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
                RecentSharesStore.remember(url.absoluteString, mountPath: mps.first?.path)
                completion(.success(mps))
            } else {
                completion(.failure(.from(code: status, url: url)))
            }
        }
        if r != 0 { completion(.failure(.from(code: r, url: url))) }
    }

    /// Finds the mounted volume for a share URL (by URL resource value), if mounted.
    public static func mountPoint(for shareURL: String) -> URL? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? []
        let target = normalizedShare(shareURL)
        for v in vols {
            if let r = try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
               normalizedShare(r.absoluteString) == target { return v }
        }
        return nil
    }

    static func normalizedShare(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s.lowercased() }
        c.user = nil; c.password = nil
        var str = c.string?.lowercased() ?? s.lowercased()
        while str.hasSuffix("/") { str.removeLast() }
        return str
    }

    public static func remountPinned(completion: @escaping (_ failures: [String: MountError]) -> Void) {
        let pinned = RecentSharesStore.shared.items.filter { $0.pinned && mountPoint(for: $0.url) == nil }
        var failures: [String: MountError] = [:]
        let group = DispatchGroup()
        for s in pinned {
            guard let u = URL(string: s.url) else { continue }
            group.enter()
            mount(u) { r in
                if case .failure(let e) = r { failures[s.url] = e }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(failures) }
    }
}

/// Discovers SMB/AFP/NFS services on the local network via Bonjour.
public final class MountableBrowser: ObservableObject {
    public struct Service: Hashable, Identifiable {
        public var id: String { "\(scheme.rawValue)://\(name)" }
        public var name: String
        public var scheme: NetworkScheme
        public var endpoint: NWEndpoint
        public static func == (a: Service, b: Service) -> Bool { a.id == b.id }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    @Published public private(set) var services: [Service] = []
    private var browsers: [NWBrowser] = []

    public init() {}

    public func start() {
        stop()
        for scheme in NetworkScheme.allCases {
            guard let type = scheme.bonjourType else { continue }
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let found = results.compactMap { r -> Service? in
                    if case let .service(name, _, _, _) = r.endpoint { return Service(name: name, scheme: scheme, endpoint: r.endpoint) }
                    return nil
                }
                DispatchQueue.main.async {
                    self.services.removeAll { $0.scheme == scheme }
                    self.services.append(contentsOf: found)
                    self.services.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
            b.start(queue: .global(qos: .utility))
            browsers.append(b)
        }
    }

    public func stop() { browsers.forEach { $0.cancel() }; browsers = [] }
    deinit { stop() }

    /// A mountable URL for a discovered service (Bonjour name resolves via .local).
    public static func url(for s: Service) -> URL? {
        let host = s.name.replacingOccurrences(of: " ", with: "-") + ".local"
        return URL(string: "\(s.scheme.rawValue)://\(host)")
    }
}
