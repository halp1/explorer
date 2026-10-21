import ExplorerHelperProtocol
import Foundation
import Security

/// Privileged helper (launch daemon). Performs file operations that need root on behalf of Explorer.app.
/// Every request must carry an AuthorizationExternalForm that grants `HelperConstants.authRight`,
/// and the XPC peer must be signed with the same team/identity as this helper.

final class HelperService: NSObject, ExplorerHelperProtocol {
    func version(withReply reply: @escaping (String) -> Void) { reply(HelperConstants.version) }

    private func authorize(_ data: Data) -> NSError? {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(errAuthorizationInvalidRef))
        }
        var ext = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &ext) { $0.copyBytes(from: data) }
        var ref: AuthorizationRef?
        var st = AuthorizationCreateFromExternalForm(&ext, &ref)
        guard st == errAuthorizationSuccess, let ref else { return NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        defer { AuthorizationFree(ref, []) }
        st = HelperConstants.authRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { ip in
                var rights = AuthorizationRights(count: 1, items: ip)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        return st == errAuthorizationSuccess ? nil : NSError(domain: NSOSStatusErrorDomain, code: Int(st))
    }

    private func perform(_ auth: Data, _ reply: (NSError?) -> Void, _ body: () throws -> Void) {
        if let e = authorize(auth) { reply(e); return }
        do { try body(); reply(nil) } catch { reply(error as NSError) }
    }

    func copyItem(atPath src: String, toPath dst: String, authorization: Data, reply: @escaping (NSError?) -> Void) {
        perform(authorization, reply) { try FileManager.default.copyItem(atPath: src, toPath: dst) }
    }

    func moveItem(atPath src: String, toPath dst: String, authorization: Data, reply: @escaping (NSError?) -> Void) {
        perform(authorization, reply) { try FileManager.default.moveItem(atPath: src, toPath: dst) }
    }

    func removeItem(atPath path: String, authorization: Data, reply: @escaping (NSError?) -> Void) {
        perform(authorization, reply) {
            guard path != "/", !path.isEmpty else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func setPermissions(_ mode: Int, atPath path: String, authorization: Data, reply: @escaping (NSError?) -> Void) {
        perform(authorization, reply) {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    /// Requirement the connecting app must satisfy: same bundle id, signed with the same certificate leaf as us.
    lazy var peerRequirement: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
            return "identifier \"\(HelperConstants.appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        // Ad-hoc/local signing: identifier match only.
        return "identifier \"\(HelperConstants.appBundleID)\""
    }()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        if #available(macOS 13.0, *) {
            c.setCodeSigningRequirement(peerRequirement)
        }
        c.exportedInterface = NSXPCInterface(with: ExplorerHelperProtocol.self)
        c.exportedObject = HelperService()
        c.resume()
        return true
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
