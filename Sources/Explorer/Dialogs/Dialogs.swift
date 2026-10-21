import AppKit
import SwiftUI
import ExplorerKit

// MARK: - Mount Network Share

struct MountShareView: View {
    @ObservedObject var browser: MountableBrowser
    @ObservedObject var recents = RecentSharesStore.shared
    @State var scheme: NetworkScheme = .smb
    @State var address: String
    @State var selected: String?
    var connect: (URL) -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mount a Network Share").font(.headline)
            Text("Choose a service to connect to:").font(.caption).foregroundColor(.secondary)
            List(selection: $selected) {
                Section("This network") {
                    if browser.services.isEmpty { Text("Searching…").foregroundColor(.secondary) }
                    ForEach(browser.services) { s in
                        Label("\(s.name) (\(s.scheme.rawValue.uppercased()))", systemImage: s.scheme == .smb ? "pc" : "server.rack").tag(s.id)
                    }
                }
                Section("Recent network shares") {
                    if recents.items.filter({ !$0.hidden }).isEmpty { Text("No recent network shares").foregroundColor(.secondary) }
                    ForEach(recents.items.filter { !$0.hidden }) { r in
                        HStack {
                            Label(r.url, systemImage: r.pinned ? "pin.fill" : "externaldrive.connected.to.line.below")
                            Spacer()
                            if NetworkMounter.mountPoint(for: r.url) != nil {
                                Button { if let m = NetworkMounter.mountPoint(for: r.url) { VolumeOps.eject(m, window: nil) } } label: { Image(systemName: "eject") }.buttonStyle(.borderless).help("Eject")
                            }
                            Button { toggle(r, pin: true) } label: { Image(systemName: r.pinned ? "pin.slash" : "pin") }.buttonStyle(.borderless).help(r.pinned ? "Unpin" : "Pin")
                            Button { toggle(r, pin: false) } label: { Image(systemName: "eye.slash") }.buttonStyle(.borderless).help("Hide")
                            Button { recents.items.removeAll { $0.url == r.url } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Forget")
                        }.tag(r.url)
                    }
                }
            }
            .frame(minHeight: 220)
            .onChange(of: selected) { s in
                guard let s else { return }
                if let svc = browser.services.first(where: { $0.id == s }), let u = MountableBrowser.url(for: svc) {
                    scheme = svc.scheme; address = u.host ?? ""
                } else if let u = URL(string: s), let sc = u.scheme.flatMap(NetworkScheme.init(rawValue:)) {
                    scheme = sc; address = String(s.dropFirst(sc.rawValue.count + 3))
                }
            }
            Text("Enter address manually").font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("", selection: $scheme) {
                    ForEach(NetworkScheme.allCases, id: \.self) { Text($0.rawValue + "://").tag($0) }
                }.labelsHidden().frame(width: 110)
                TextField("server/share", text: $address)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect...") {
                    if let u = URL(string: "\(scheme.rawValue)://\(address)") { connect(u) }
                }.keyboardShortcut(.defaultAction).disabled(address.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
    }

    func toggle(_ r: RecentShare, pin: Bool) {
        guard let i = recents.items.firstIndex(where: { $0.url == r.url }) else { return }
        if pin { recents.items[i].pinned.toggle() } else { recents.items[i].hidden = true }
        NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
    }
}

enum MountShareWindow {
    static func show(prefill: URL?, host: BrowserWindowController) {
        let browser = MountableBrowser()
        browser.start()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { [weak host] in browser.stop(); host?.window?.endSheet(panel) }
        let addr = prefill.map { ($0.host ?? "") + $0.path } ?? ""
        let v = MountShareView(browser: browser, scheme: prefill?.scheme.flatMap(NetworkScheme.init(rawValue:)) ?? .smb, address: addr,
                               connect: { [weak host] u in close(); host?.mountShare(u) }, cancel: close)
        panel.contentViewController = NSHostingController(rootView: v)
        host.window?.beginSheet(panel)
    }
}

// MARK: - Tab sets & tab customization

enum TabSetsUI {
    static func customizeTab(_ c: BrowserWindowController) {
        let colors = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        colors.addItem(withTitle: "No color")
        for (i, name) in ["Theme", "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink", "Brown", "Gray"].enumerated() where i > 0 {
            colors.addItem(withTitle: name)
            let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in TreeBuilder.color(i).setFill(); NSBezierPath(ovalIn: r).fill(); return true }
            colors.lastItem?.image = img
        }
        colors.selectItem(at: c.state.tabColor ?? 0)
        guard let title = Alerts.prompt("Customize This Tab", message: "Supplementary title (leave empty to use the folder name):", defaultValue: c.state.tabTitle ?? "", ok: "OK", selectStem: false, accessory: colors) else { return }
        c.state.tabTitle = title.isEmpty ? nil : title
        c.state.tabColor = colors.indexOfSelectedItem == 0 ? nil : colors.indexOfSelectedItem
        c.window?.title = c.state.title
        let attr = NSMutableAttributedString(string: c.state.title)
        if let col = c.state.tabColor { attr.addAttribute(.foregroundColor, value: TreeBuilder.color(col), range: NSRange(location: 0, length: attr.length)) }
        c.window?.tab.attributedTitle = attr
    }

    static func save(_ c: BrowserWindowController) {
        guard let name = Alerts.prompt("Save This Tab Set", message: "Name:", defaultValue: "Tab Set", ok: "Save", selectStem: false), !name.isEmpty else { return }
        if TabSetStore.shared.items.contains(where: { $0.name == name }),
           !Alerts.confirm(String(format: "A tab set named “%@” already exists.", name), "Do you want to replace it?", ok: "Replace") { return }
        let windows = c.window?.tabbedWindows ?? [c.window].compactMap { $0 }
        let tabs = windows.compactMap { $0.windowController as? BrowserWindowController }.compactMap { w -> SavedTab? in
            guard let u = w.state.location.url ?? w.state.currentDirectory else { return nil }
            return SavedTab(path: u.path, title: w.state.tabTitle, colorIndex: w.state.tabColor)
        }
        TabSetStore.shared.items.removeAll { $0.name == name }
        TabSetStore.shared.items.append(TabSet(name: name, tabs: tabs))
    }

    static func load(_ set: TabSet) {
        var first: BrowserWindowController?
        for t in set.tabs {
            let u = URL(fileURLWithPath: t.path, isDirectory: true)
            let c = first == nil ? AppDelegate.shared.openWindow(.directory(u)) : AppDelegate.shared.openTab(.directory(u), from: first)
            if first == nil { first = c }
            c.state.tabTitle = t.title
            c.state.tabColor = t.colorIndex
        }
    }

    static func manage(window: NSWindow?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        let v = ManageTabSetsView(close: { window?.endSheet(panel) })
        panel.contentViewController = NSHostingController(rootView: v)
        window?.beginSheet(panel)
    }
}

struct ManageTabSetsView: View {
    @ObservedObject var store = TabSetStore.shared
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Text("Manage Tab Sets").font(.headline)
            if store.items.isEmpty { Text("No saved tab sets.").foregroundColor(.secondary) }
            List {
                ForEach($store.items) { $set in
                    HStack {
                        TextField("Name", text: $set.name)
                        Text("\(set.tabs.count) tabs").foregroundColor(.secondary)
                        Button { store.items.removeAll { $0.id == set.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete this tab set")
                    }
                }
            }
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 400, height: 320)
    }
}

// MARK: - Log / commit

enum LogSheet {
    static func show(title: String, text: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let tv = NSTextView(frame: sv.bounds)
        tv.string = text
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        a.accessoryView = sv
        a.addButton(withTitle: "OK")
        Alerts.present(a, window)
    }
}

enum CommitSheet {
    static func ask(branch: String?, window: NSWindow?) -> String? {
        let a = NSAlert()
        a.messageText = "Commit Changes"
        a.informativeText = branch.map { "Commits all staged changes to “\($0)”." } ?? "Commits all staged changes."
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let tv = NSTextView(frame: sv.bounds)
        tv.font = .systemFont(ofSize: 12)
        tv.isRichText = false
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.addButton(withTitle: "Commit")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tv
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Custom folder icon picker (SF Symbols + emoji)

struct IconPickerView: View {
    enum Mode: String, CaseIterable { case emoji = "Emoji", symbol = "Symbol" }
    @State var mode: Mode = .emoji
    @State var query = ""
    let emoji: [(String, String)]
    let symbols: [String]
    var pick: (String, Mode) -> Void
    var remove: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented).labelsHidden()
            TextField("Search", text: $query)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 10)) {
                    if mode == .emoji {
                        ForEach(filteredEmoji, id: \.0) { e in Button(e.0) { pick(e.0, .emoji) }.buttonStyle(.borderless).font(.title2).help(e.1) }
                    } else {
                        ForEach(filteredSymbols, id: \.self) { s in Button { pick(s, .symbol) } label: { Image(systemName: s).font(.title3) }.buttonStyle(.borderless).help(s) }
                    }
                }
            }
            HStack {
                Button("Restore default", action: remove)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }.padding(14).frame(width: 440, height: 420)
    }
    var filteredEmoji: [(String, String)] { query.isEmpty ? Array(emoji.prefix(600)) : emoji.filter { $0.1.localizedCaseInsensitiveContains(query) } }
    var filteredSymbols: [String] { query.isEmpty ? Array(symbols.prefix(600)) : Array(symbols.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(600)) }
}

enum IconPicker {
    /// Emoji with names from CoreText/Unicode character names (no bundled data).
    static func emojiList() -> [(String, String)] {
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x26FF, 0x2700...0x27BF]
        var out: [(String, String)] = []
        for r in ranges {
            for v in r {
                guard let sc = UnicodeScalar(v), sc.properties.isEmojiPresentation else { continue }
                out.append((String(sc), sc.properties.name?.lowercased() ?? ""))
            }
        }
        return out
    }

    /// SF Symbol names, read from the system's CoreGlyphs bundle.
    static func symbolNames() -> [String] {
        let p = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_order.plist"
        if let arr = NSArray(contentsOfFile: p) as? [String] { return arr }
        return ["folder", "star", "heart", "house", "doc", "photo", "music.note", "film", "gear", "briefcase"]
    }

    static func show(for folder: URL, window: NSWindow?, done: @escaping () -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { window?.endSheet(panel) }
        let v = IconPickerView(emoji: emojiList(), symbols: symbolNames(), pick: { s, mode in
            let img = render(s, symbol: mode == .symbol)
            NSWorkspace.shared.setIcon(img, forFile: folder.path, options: [])
            close(); done()
        }, remove: {
            NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
            close(); done()
        }, cancel: close)
        panel.contentViewController = NSHostingController(rootView: v)
        window?.beginSheet(panel)
    }

    /// Draws a folder icon with the emoji/symbol badge on top.
    static func render(_ s: String, symbol: Bool) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { r in
            NSWorkspace.shared.icon(for: .folder).draw(in: r)
            let inner = NSRect(x: r.width * 0.28, y: r.height * 0.2, width: r.width * 0.44, height: r.height * 0.44)
            if symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 200, weight: .regular)) {
                let tinted = img.copy() as! NSImage
                tinted.lockFocus(); NSColor.white.withAlphaComponent(0.9).set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(in: FolderThumb.aspectFit(tinted.size, inner))
            } else {
                let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: inner.height * 0.85)]
                let str = NSAttributedString(string: s, attributes: attr)
                let b = str.size()
                str.draw(at: NSPoint(x: inner.midX - b.width / 2, y: inner.midY - b.height / 2))
            }
            return true
        }
    }
}

// MARK: - Help & acknowledgments

enum HelpWindow {
    static var window: NSWindow?

    static func show(title: String, text: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 14, height: 14)
        if let d = text.data(using: .utf8), let a = try? NSAttributedString(markdown: d, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let m = NSMutableAttributedString(attributedString: a)
            m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: m.length))
            m.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: m.length))
            tv.textStorage?.setAttributedString(m)
        } else { tv.string = text }
        w.contentView = sv
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func showShortcuts() { show(title: "Keyboard Shortcuts", text: HelpText.shortcuts) }
    static func showGuide() { show(title: "User’s Guide", text: HelpText.guide) }
}

enum AcknowledgmentsWindow {
    static func show() { HelpWindow.show(title: "Acknowledgments", text: HelpText.acknowledgments) }
}
