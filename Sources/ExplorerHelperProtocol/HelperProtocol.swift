import Foundation

/// XPC interface of the privileged helper daemon (`com.halp.explorer.Helper`).
/// Each call carries an `AuthorizationExternalForm` blob that the helper verifies
/// against the `com.halp.explorer.admin-file-op` right before touching the disk.
@objc(ExplorerHelperProtocol)
public protocol ExplorerHelperProtocol {
    func version(withReply reply: @escaping (String) -> Void)
    func copyItem(atPath src: String, toPath dst: String, authorization: Data, reply: @escaping (NSError?) -> Void)
    func moveItem(atPath src: String, toPath dst: String, authorization: Data, reply: @escaping (NSError?) -> Void)
    func removeItem(atPath path: String, authorization: Data, reply: @escaping (NSError?) -> Void)
    func setPermissions(_ mode: Int, atPath path: String, authorization: Data, reply: @escaping (NSError?) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "com.halp.explorer.Helper"
    public static let plistName = "com.halp.explorer.Helper.plist"
    public static let authRight = "system.privilege.admin"
    public static let version = "1"
    public static let appBundleID = "com.halp.explorer"
}
