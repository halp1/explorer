import AppKit
import ExplorerKit

/// Mirrors whitelisted settings to iCloud Key-Value storage. Needs the iCloud KV entitlement
/// (team-signed build); when unavailable, push/pull do nothing and sync reports the error.
final class PreferencesSync {
    static let shared = PreferencesSync()
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    /// Keys worth syncing (UI settings, not per-machine state).
    static let keys = [
        "appearance", "themeColor", "fontSizeDelta", "sounds", "pathBarStyle", "pathBarPosition", "showShelf", "showActionToolbar", "returnAction",
        "backWithDelete", "trashWithDelete", "cutViaTrash", "internalCutForCloud", "usePrivateTrash3", "dragBehavior", "linking",
        "openArchives", "inheritViewOptions", "autoQuit", "reorderFavorites", "showTextTags", "recentDays", "treeSpacing",
        "boldTopLevel", "truncateFolders", "showIndentGuides", "showCustomFolderIcons", "showFolderLabelColor", "foldersInheritColor",
        "autoScrollTree", "autoExpandTree", "shareTreeExpansion", "showExtension", "preferPathNames", "truncateFiles",
        "truncateInfoNames", "boldRecentChanges", "dateLength", "dateMode", "rowHeight", "alternatingTableBackground",
        "listLayout", "listSpacing", "folderThumbnails", "iconSpacing", "treeOrderByType2", "contextMenuOrder",
        "tableSettings", "archiveTableSettings", "defaultViewOptions",
    ]

    var signedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
            self?.pull()
            NotificationCenter.default.post(name: .viewSettingsChanged, object: nil)
        }
        store.synchronize()
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }

    func push() {
        let d = UserDefaults.standard
        for k in Self.keys { if let v = d.object(forKey: k) { store.set(v, forKey: k) } else { store.removeObject(forKey: k) } }
        store.synchronize()
    }

    func pull() {
        let d = UserDefaults.standard
        for k in Self.keys { if let v = store.object(forKey: k) { d.set(v, forKey: k) } }
    }

    /// First enable: ask whether to pull existing iCloud settings or upload ours.
    func enableInteractively() {
        guard signedIn else {
            Alerts.info("Sync error", "Sign in to iCloud in System Settings to enable sync.", window: nil)
            Preferences.shared.syncWithICloud = false
            return
        }
        let a = NSAlert()
        a.messageText = "Sync Explorer Settings with iCloud"
        a.informativeText = "Choose whether to start by downloading preferences from iCloud or uploading from this Mac."
        a.addButton(withTitle: "Pull from iCloud")
        a.addButton(withTitle: "Push to iCloud")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: pull(); start()
        case .alertSecondButtonReturn: push(); start()
        default: Preferences.shared.syncWithICloud = false
        }
        NotificationCenter.default.post(name: .viewSettingsChanged, object: nil)
    }
}
