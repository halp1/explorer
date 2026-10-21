import AppKit
import ExplorerKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    static weak var lastActive: BrowserWindowController?
    let prefs = Preferences.shared
    private var settingsWindow: SettingsWindowController?
    private var launchedWithRequest = false

    static func main() {
        MemoryGuard.startIfRequested()
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSApp.mainMenu = MainMenu.build()
        NSApp.servicesProvider = self
        applyAppearance()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        Trasher.emptyPrivateTrash()
        if prefs.remountPinnedShares { NetworkMounter.remountPinned { _ in NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil) } }
        if prefs.syncWithICloud { PreferencesSync.shared.start() }
        ThumbnailStore.shared.trimDiskCache()
        DispatchQueue.main.async { [self] in
            if BrowserWindowController.all.isEmpty && !launchedWithRequest {
                var start = prefs.defaultURL
                if prefs.goToLastFolder, let last = prefs.history.first, FileManager.default.fileExists(atPath: last) {
                    start = URL(fileURLWithPath: last, isDirectory: true)
                }
                openWindow(.directory(start))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.scheduleIfRequested()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(.directory(prefs.defaultURL)) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { prefs.autoQuit }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if FileOps.shared.running.contains(where: { !$0.isFinished }) {
            let a = NSAlert()
            a.messageText = "Are you sure you want to quit now?"
            a.informativeText = "There are ongoing file operations. Quitting now may damage your files."
            a.addButton(withTitle: "Quit Now"); a.addButton(withTitle: "Cancel")
            a.alertStyle = .critical
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            FileOps.shared.running.forEach { $0.cancel() }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Trasher.emptyPrivateTrash()
        try? FileManager.default.removeItem(at: AppPaths.temp)
    }

    func windowClosed() {
        if BrowserWindowController.all.isEmpty {
            Trasher.emptyPrivateTrash()
        }
    }

    func applyAppearance() {
        switch prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Windows

    var activeController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? Self.lastActive ?? BrowserWindowController.all.last
    }

    @discardableResult
    func openWindow(_ loc: Location, select: [URL] = []) -> BrowserWindowController {
        let c = BrowserWindowController(location: loc, select: select)
        c.window?.tabbingMode = .disallowed
        if let ref = activeController?.window, ref.isVisible {
            c.window?.setFrame(ref.frame.offsetBy(dx: 24, dy: -24), display: false)
        } else {
            c.window?.center()
        }
        c.showWindow(nil)
        c.window?.tabbingMode = .preferred
        c.fileView?.focus()
        return c
    }

    @discardableResult
    func openTab(_ loc: Location, from host: BrowserWindowController?) -> BrowserWindowController {
        guard let host, let hw = host.window else { return openWindow(loc) }
        let c = BrowserWindowController(location: loc)
        if let w = c.window {
            hw.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
        }
        if prefs.shareTreeExpansion { c.tree.expanded = host.tree.expanded; c.tree.rebuild() }
        return c
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func newWindow(_ sender: Any?) { openWindow(.directory(prefs.defaultURL)) }
    @objc func newTabGlobal(_ sender: Any?) {
        if let c = activeController { c.newTab(sender) } else { openWindow(.directory(prefs.defaultURL)) }
    }
    @objc func closeAllWindows(_ sender: Any?) { for c in BrowserWindowController.all { c.window?.close() } }

    @objc func loadTabSet(_ sender: NSMenuItem) {
        guard let set = sender.representedObject as? TabSet else { return }
        TabSetsUI.load(set)
    }

    // MARK: URL scheme / Services / open documents

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        launchedWithRequest = true
        handle(AppURLScheme.parse(url))
    }

    func handle(_ req: AppURLScheme.Request?) {
        switch req {
        case .newWindow: openWindow(.directory(prefs.defaultURL))
        case .open(let u): openFolderOrArchive(u)
        case .reveal(let u): reveal(u)
        case nil: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithRequest = true
        for u in urls {
            if let r = AppURLScheme.parse(u), u.scheme != "file" { handle(r); continue }
            openFolderOrArchive(u)
        }
    }

    func openFolderOrArchive(_ u: URL) {
        var d: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &d) else { return }
        if d.boolValue && !(u.pathExtension == "app") { openWindow(.directory(u)) }
        else if ArchiveFormat.detect(fileName: u.lastPathComponent) != nil { openWindow(.archive(u, inner: "")) }
        else { reveal(u) }
    }

    func reveal(_ u: URL) {
        let dir = u.deletingLastPathComponent()
        if let c = activeController, c.window?.isVisible == true, !c.state.isArchive {
            c.state.go(.directory(dir), select: [u])
            c.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(.directory(dir), select: [u])
        }
    }

    @objc func openInExplorer(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        urls.forEach(openFolderOrArchive)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func revealInExplorer(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if let u = urls.first {
            let dir = u.deletingLastPathComponent()
            openWindow(.directory(dir), select: urls.filter { $0.deletingLastPathComponent() == dir })
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Settings & help

    @objc func showSettings(_ sender: Any?) { showSettingsTab(.general) }
    @objc func showTreeSettings(_ sender: Any?) { showSettingsTab(.tree) }
    @objc func showSidebarSettings(_ sender: Any?) { showSettingsTab(.sidebar) }
    @objc func showScriptingSettings(_ sender: Any?) { showSettingsTab(.scripting) }

    func showSettingsTab(_ tab: SettingsTab) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.select(tab)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAcknowledgments(_ sender: Any?) { AcknowledgmentsWindow.show() }
    @objc func showKeyboardShortcuts(_ sender: Any?) { HelpWindow.showShortcuts() }
    @objc func showUserGuide(_ sender: Any?) { HelpWindow.showGuide() }

    @objc func emptyPrivateTrashGlobal(_ sender: Any?) { activeController?.emptyPrivateTrash(sender) }
}

// MARK: - AppleScript commands (see Explorer.sdef)

@objc(ExplorerNewWindowCommand)
final class ExplorerNewWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared.openWindow(.directory(Preferences.shared.defaultURL))
        return nil
    }
}

@objc(ExplorerRevealCommand)
final class ExplorerRevealCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let u = directParameter as? URL else { return nil }
        AppDelegate.shared.reveal(u)
        return nil
    }
}

@objc(ExplorerOpenCommand)
final class ExplorerOpenCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let u = directParameter as? URL else { return nil }
        AppDelegate.shared.openFolderOrArchive(u)
        return nil
    }
}
