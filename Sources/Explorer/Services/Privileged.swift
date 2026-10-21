import AppKit
import ServiceManagement
import Security
import ExplorerKit

/// Runs file operations as root. Prefers the SMAppService launch daemon (XPC); falls back to an
/// `osascript … with administrator privileges` prompt when the daemon cannot be registered
/// (e.g. ad-hoc signed development builds).
final class Privileged {
    static let shared = Privileged()

    enum Status { case enabled, requiresApproval, notRegistered, unavailable }

    var daemon: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    var status: Status {
        switch daemon.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        default: return .unavailable
        }
    }

    /// Registers the daemon. Returns false when the user must approve it in System Settings.
    @discardableResult
    func register() -> Bool {
        do {
            try daemon.register()
        } catch {
            NSLog("Explorer helper registration failed: \(error)")
        }
        return daemon.status == .enabled
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Authorization

    private var authRef: AuthorizationRef?

    private func authorizationData() throws -> Data {
        if authRef == nil {
            var ref: AuthorizationRef?
            let st = AuthorizationCreate(nil, nil, [], &ref)
            guard st == errAuthorizationSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
            authRef = ref
        }
        let st = HelperConstants.authRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { ip in
                var rights = AuthorizationRights(count: 1, items: ip)
                return AuthorizationCopyRights(authRef!, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard st == errAuthorizationSuccess else {
            if st == errAuthorizationCanceled { throw OpError.cancelled }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(st))
        }
        var ext = AuthorizationExternalForm()
        AuthorizationMakeExternalForm(authRef!, &ext)
        return withUnsafeBytes(of: &ext) { Data($0) }
    }

    private func proxy(_ errorHandler: @escaping (Error) -> Void) -> ExplorerHelperProtocol? {
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ExplorerHelperProtocol.self)
        c.resume()
        return c.remoteObjectProxyWithErrorHandler { e in errorHandler(e); c.invalidate() } as? ExplorerHelperProtocol
    }

    enum Op {
        case copy(String, String), move(String, String), remove(String), chmod(Int, String)
        var shell: String {
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            switch self {
            case .copy(let a, let b): return "/bin/cp -Rp \(q(a)) \(q(b))"
            case .move(let a, let b): return "/bin/mv \(q(a)) \(q(b))"
            case .remove(let p): return "/bin/rm -rf \(q(p))"
            case .chmod(let m, let p): return "/bin/chmod \(String(m, radix: 8)) \(q(p))"
            }
        }
    }

    /// Performs operations as root. Completion on main queue.
    func run(_ ops: [Op], completion: @escaping (Error?) -> Void) {
        if status != .enabled { register() }
        if status == .enabled, let auth = try? authorizationData() {
            runViaHelper(ops, auth: auth, completion: completion)
        } else {
            runViaOsascript(ops, completion: completion)
        }
    }

    private func runViaHelper(_ ops: [Op], auth: Data, completion: @escaping (Error?) -> Void) {
        var remaining = ops[...]
        func next() {
            guard let op = remaining.popFirst() else { DispatchQueue.main.async { completion(nil) }; return }
            var finished = false
            let done: (NSError?) -> Void = { e in
                guard !finished else { return }
                finished = true
                if let e { DispatchQueue.main.async { completion(e) } } else { next() }
            }
            guard let p = proxy({ e in done(e as NSError) }) else { done(NSError(domain: "Explorer", code: 1)); return }
            p.version { v in
                guard v == HelperConstants.version else {
                    done(NSError(domain: "Explorer", code: 2, userInfo: [NSLocalizedDescriptionKey: "The privileged helper is out of date. Please relaunch Explorer and retry."]))
                    return
                }
                switch op {
                case .copy(let a, let b): p.copyItem(atPath: a, toPath: b, authorization: auth, reply: done)
                case .move(let a, let b): p.moveItem(atPath: a, toPath: b, authorization: auth, reply: done)
                case .remove(let a): p.removeItem(atPath: a, authorization: auth, reply: done)
                case .chmod(let m, let a): p.setPermissions(m, atPath: a, authorization: auth, reply: done)
                }
            }
        }
        next()
    }

    private func runViaOsascript(_ ops: [Op], completion: @escaping (Error?) -> Void) {
        let script = ops.map(\.shell).joined(separator: " && ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            let out = ActionRunner.runAppleScript("do shell script \"\(escaped)\" with administrator privileges")
            DispatchQueue.main.async {
                if out.status == 0 { completion(nil) }
                else if out.log.contains("-128") { completion(OpError.cancelled) }
                else { completion(OpError.message(out.log.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
        }
    }

    // MARK: CLI launcher

    static let cliPath = "/usr/local/bin/explorer"

    var cliInstalled: Bool { FileManager.default.fileExists(atPath: Self.cliPath) }

    func installCLI(completion: @escaping (Error?) -> Void) {
        guard let src = Bundle.main.url(forResource: "explorer", withExtension: nil) else {
            completion(OpError.message("The launcher script is missing from the app bundle.")); return
        }
        let q: (String) -> String = { "'" + $0 + "'" }
        let script = "mkdir -p /usr/local/bin && cp -f \(q(src.path)) \(q(Self.cliPath)) && chmod 755 \(q(Self.cliPath))"
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            let out = ActionRunner.runAppleScript("do shell script \"\(escaped)\" with administrator privileges")
            DispatchQueue.main.async { completion(out.status == 0 ? nil : OpError.message(out.log)) }
        }
    }

    func uninstallCLI(completion: @escaping (Error?) -> Void) {
        run([.remove(Self.cliPath)], completion: completion)
    }
}
