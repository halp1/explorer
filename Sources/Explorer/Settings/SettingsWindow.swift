import AppKit
import SwiftUI
import ExplorerKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", tree = "Folder Tree", fileViews = "File Views", sidebar = "Sidebar", contextMenu = "Context Menu", scripting = "Scripting"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"; case .tree: return "list.bullet.indent"; case .fileViews: return "square.grid.2x2"
        case .sidebar: return "sidebar.leading"; case .contextMenu: return "contextualmenu.and.cursorarrow"; case .scripting: return "terminal"
        }
    }
}

final class SettingsModel: ObservableObject { @Published var tab: SettingsTab = .general }

final class SettingsWindowController: NSWindowController {
    let model = SettingsModel()
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 828, height: 552), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.setFrameAutosaveName("ExplorerSettings")
        super.init(window: w)
        let host = NSHostingController(rootView: SettingsRoot(model: model).environmentObject(Preferences.shared)
            .frame(minWidth: 760, idealWidth: 828, minHeight: 480, idealHeight: 552))
        // Don't let SwiftUI's ideal size shrink the window to its title bar.
        if #available(macOS 13.0, *) { host.sizingOptions = [.minSize] }
        w.contentViewController = host
        w.minSize = NSSize(width: 760, height: 480)
        w.setContentSize(NSSize(width: 828, height: 552))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ t: SettingsTab) { model.tab = t }
}

/// Posts a change notification so open windows re-layout after any setting changes.
private func changed() {
    NotificationCenter.default.post(name: .viewSettingsChanged, object: nil)
    AppDelegate.shared.applyAppearance()
}

struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollView {
                Group {
                    switch model.tab {
                    case .general: GeneralSettings()
                    case .tree: TreeSettings()
                    case .fileViews: FileViewSettings()
                    case .sidebar: SidebarSettings()
                    case .contextMenu: ContextMenuSettings()
                    case .scripting: ScriptingSettings()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Binding helper writing through Preferences and broadcasting.
func pref<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: get, set: { set($0); changed() })
}

struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(.init(text)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var p: Preferences
    @State private var cacheSize = ThumbnailStore.shared.diskCacheSize
    var body: some View {
        Form {
            Picker("Appearance:", selection: pref({ p.appearance }, { p.appearance = $0 })) { ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Theme color:", selection: pref({ p.themeColor }, { p.themeColor = $0 })) { ForEach(ThemeColor.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Stepper("Font size in views: \(p.fontSizeDelta >= 0 ? "+" : "")\(p.fontSizeDelta) px", value: pref({ p.fontSizeDelta }, { p.fontSizeDelta = $0 }), in: -1...8)
            Picker("Sounds:", selection: pref({ p.sounds }, { p.sounds = $0 })) {
                Text("In-app sounds").tag(SoundsMode.inApp); Text("System sounds").tag(SoundsMode.system); Text("Mute all sounds").tag(SoundsMode.off)
            }
            Picker("Show Path Bar as:", selection: pref({ p.pathBarStyle }, { p.pathBarStyle = $0 })) {
                Text("Interactive path control").tag(PathBarStyle.interactive); Text("Path string").tag(PathBarStyle.string)
            }
            Picker("Path Bar position:", selection: pref({ p.pathBarPosition }, { p.pathBarPosition = $0 })) {
                Text("At the bottom").tag(PathBarPosition.bottom); Text("At the top").tag(PathBarPosition.top)
            }
            Toggle("Show Action Bar", isOn: pref({ p.showActionToolbar }, { p.showActionToolbar = $0 }))
            Toggle("Show Shelf", isOn: pref({ p.showShelf }, { p.showShelf = $0 }))
            Picker("Pressing return:", selection: pref({ p.returnAction }, { p.returnAction = $0 })) {
                Text("Open").tag(ReturnAction.open); Text("Rename").tag(ReturnAction.rename)
            }
            Toggle("Navigate back with ⌫ delete key", isOn: pref({ p.backWithDelete }, { p.backWithDelete = $0; if $0 { p.trashWithDelete = false } }))
            Toggle("Move to Trash with ⌫ delete key", isOn: pref({ p.trashWithDelete }, { p.trashWithDelete = $0; if $0 { p.backWithDelete = false } }))
            Section("When Explorer starts") {
                Toggle("Go to the last visited folder", isOn: pref({ p.goToLastFolder }, { p.goToLastFolder = $0 }))
                Toggle("Automatically remount all pinned shares", isOn: pref({ p.remountPinnedShares }, { p.remountPinnedShares = $0 }))
            }
            Section("File Operations") {
                Toggle("Cut via Trash", isOn: pref({ p.cutViaTrash }, { p.cutViaTrash = $0 }))
                Note("When checked, the Cut operation will immediately move files to the Trash and place their URLs to the clipboard (works with other apps). When unchecked, the Cut operation will mimic the behavior of File Explorer (works only within Explorer).")
                if p.cutViaTrash {
                    Toggle("Use internal Cut for Cloud Storage", isOn: pref({ p.internalCutForCloud }, { p.internalCutForCloud = $0 }))
                    Note("Some Cloud Storage providers omit system Trash and put trashed items in their remote trash bins, making them unavailable for paste. When checked, internal Cut will be used instead of Cut via Trash for items in Cloud Storage containers.")
                }
                Toggle("Use private Trash", isOn: pref({ p.usePrivateTrash }, { p.usePrivateTrash = $0 }))
                Note("The system Trash can be unavailable at some locations. When checked, a special folder will be used instead to create backups until the last window is closed. When unchecked, destructive file operations in such locations will not be undoable.")
                Picker("Dragging items:", selection: pref({ p.dragBehavior }, { p.dragBehavior = $0 })) {
                    Text("Always moves").tag(DragBehavior.alwaysMove); Text("Moves within a volume, copies between volumes").tag(DragBehavior.finder)
                }
                Note("Hold **⌘ command** to always move, **⌥ option** to always copy")
                Picker("Create links as:", selection: pref({ p.linking }, { p.linking = $0 })) {
                    Text("Symbolic links").tag(LinkKind.symlink); Text("Aliases (bookmark files)").tag(LinkKind.alias)
                }
                Note("Affects linking files with ⌃-drag and determines the preferred method elsewhere (the other method will be available with **⌥ option**)")
                Picker("Open archives:", selection: pref({ p.openArchives }, { p.openArchives = $0 })) {
                    Text("Within Explorer").tag(OpenArchives.within); Text("Using the default app").tag(OpenArchives.defaultApp)
                }
            }
            Section("Terminal") {
                HStack {
                    Text("Preferred Terminal app: ")
                    Text(FileManager.default.displayName(atPath: p.terminalAppPath)).bold()
                    Button("Choose...") {
                        let o = NSOpenPanel(); o.directoryURL = URL(fileURLWithPath: "/Applications"); o.allowedContentTypes = [.application]
                        if o.runModal() == .OK, let u = o.url { p.terminalAppPath = u.path }
                    }
                    Button("Restore default") { p.terminalAppPath = "/System/Applications/Utilities/Terminal.app" }
                }
            }
            Section("Remembered view options") {
                HStack {
                    Text("\(ViewOptionsStore.shared.count) folders")
                    Button("Reset for all folders") { ViewOptionsStore.shared.forgetAll(); changed() }
                }
                Toggle("Apply folder’s remembered options to all its subfolders", isOn: pref({ p.inheritViewOptions }, { p.inheritViewOptions = $0 }))
            }
            Section("Thumbnail Caching") {
                Toggle("Persistent thumbnail cache", isOn: pref({ p.persistentThumbnailCache }, { p.persistentThumbnailCache = $0 }))
                Note("When enabled, keeps thumbnails on disk after leaving a folder, up to 1 GB.")
                HStack {
                    Text("Cache size: " + SizeFormat.string(cacheSize))
                    Button("Clear Cache") { ThumbnailStore.shared.clearCache(); cacheSize = 0 }
                }
            }
            Section("Windows") {
                Toggle("Show progress stripe for file operations", isOn: pref({ p.showProgressStripe }, { p.showProgressStripe = $0 }))
                Toggle("Quit when the last window is closed", isOn: pref({ p.autoQuit }, { p.autoQuit = $0 }))
                if p.autoQuit {
                    Toggle("Restore last window on launch", isOn: pref({ p.restoreLastWindow }, { p.restoreLastWindow = $0 }))
                    Note("This setting applies only when “System Settings > Desktop & Dock > Close windows when quitting an application” is ON. Otherwise, windows and tabs will be restored automatically.")
                }
            }
            Section("iCloud") {
                Toggle("Sync Settings with iCloud", isOn: Binding(get: { p.syncWithICloud }, set: { on in
                    p.syncWithICloud = on
                    if on { PreferencesSync.shared.enableInteractively() } else { PreferencesSync.shared.stop() }
                }))
                if p.syncWithICloud {
                    HStack {
                        Button("Push to iCloud") { PreferencesSync.shared.push() }
                        Button("Pull from iCloud") { PreferencesSync.shared.pull(); changed() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Folder tree

struct TreeSettings: View {
    @EnvironmentObject var p: Preferences
    var body: some View {
        Form {
            Toggle("Allow manual reordering of Favorites", isOn: pref({ p.reorderFavorites }, { p.reorderFavorites = $0 }))
            Note("When disabled, Favorites will be ordered alphabetically. When enabled, newly added items will appear at the bottom of the list.")
            Toggle("Show text tags", isOn: pref({ p.showTextTags }, { p.showTextTags = $0 }))
            Picker("Recent files:", selection: pref({ p.recentDays }, { p.recentDays = $0 })) {
                Text("Today").tag(1); Text("Previous 7 Days").tag(7); Text("Modified last two weeks").tag(14)
                Text("Previous 30 Days").tag(30); Text("Modified last three months").tag(90)
            }
            Slider(value: pref({ p.treeSpacing }, { p.treeSpacing = $0 }), in: 0...12, step: 1) { Text("Item spacing:") }
            Toggle("Show top-level nodes in **bold**", isOn: pref({ p.boldTopLevel }, { p.boldTopLevel = $0 }))
            Picker("Truncate folder names:", selection: pref({ p.truncateFolders }, { p.truncateFolders = $0 })) {
                ForEach(Truncation.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show indent guides", isOn: pref({ p.showIndentGuides }, { p.showIndentGuides = $0 }))
            Toggle("Show custom folder icons", isOn: pref({ p.showCustomFolderIcons }, { p.showCustomFolderIcons = $0 }))
            Toggle("Show folder label color", isOn: pref({ p.showFolderLabelColor }, { p.showFolderLabelColor = $0 }))
            Toggle("Folder icons inherit their group color", isOn: pref({ p.foldersInheritColor }, { p.foldersInheritColor = $0 }))
            Section("Expanded by default") {
                ForEach(p.sidebarSections.filter { !$0.disabled }) { s in
                    Toggle(s.label, isOn: pref({ s.expandedByDefault ?? true }, { v in
                        var all = p.sidebarSections
                        if let i = all.firstIndex(where: { $0.id == s.id }) { all[i].expandedByDefault = v }
                        p.sidebarSections = all
                    }))
                }
            }
            Toggle("Auto-scroll to current folder", isOn: pref({ p.autoScrollTree }, { p.autoScrollTree = $0 }))
            Toggle("Auto-expand tree to current folder", isOn: pref({ p.autoExpandTree }, { p.autoExpandTree = $0 }))
            Toggle("Share tree expansion state across all tabs of the same window", isOn: pref({ p.shareTreeExpansion }, { p.shareTreeExpansion = $0 }))
            Section {
                HStack {
                    Text("Default folder: ").foregroundColor(.secondary)
                    Text(p.defaultURL.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reset to Home") { p.defaultPath = "" }
                }
                Note("To choose another default folder, right-click on a folder in the Folder Tree and select “Make default folder”.")
                HStack {
                    Text("Home folder: ").foregroundColor(.secondary)
                    Text(p.homeURL.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reset") { p.homePath = ""; changed() }
                }
                Note("To change the Home folder, right-click on a folder in the Folder Tree, hold ⌥ option and select “Make Home folder”. Requires relaunch.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: File views

struct FileViewSettings: View {
    @EnvironmentObject var p: Preferences
    var body: some View {
        Form {
            Picker("File extensions:", selection: pref({ p.showExtension }, { p.showExtension = $0 })) {
                Text("Respect Finder settings").tag(ExtensionVisibility.respectFinder); Text("Always show").tag(ExtensionVisibility.show); Text("Hide for all known types").tag(ExtensionVisibility.hide)
            }
            Toggle("Prefer folder path names", isOn: pref({ p.preferPathNames }, { p.preferPathNames = $0 }))
            Note("When checked, displays the last pathname component of some special folders instead of their localized named (e.g. “com~apple~CloudDocs” instead of “iCloud Drive”)")
            Picker("Truncate filenames:", selection: pref({ p.truncateFiles }, { p.truncateFiles = $0 })) {
                ForEach(Truncation.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Truncate filenames in File Info", isOn: pref({ p.truncateInfoNames }, { p.truncateInfoNames = $0 }))
            Toggle("Show recently changed files in **bold**", isOn: pref({ p.boldRecentChanges }, { p.boldRecentChanges = $0 }))
            Picker("Date length:", selection: pref({ p.dateLength }, { p.dateLength = $0 })) { ForEach(DateLength.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Date display:", selection: pref({ p.dateMode }, { p.dateMode = $0 })) { ForEach(DateDisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Text("Example: " + DateDisplay(length: p.dateLength, mode: p.dateMode, showTime: true).string(Date().addingTimeInterval(-86400))).font(.caption).foregroundColor(.secondary)
            Section("Table & Archive View") {
                Slider(value: pref({ p.rowHeight }, { p.rowHeight = $0 }), in: 16...40, step: 1) { Text("Row height: \(Int(p.rowHeight))") }
                Toggle("Use alternating background", isOn: pref({ p.alternatingRows }, { p.alternatingRows = $0 }))
            }
            Section("List View") {
                Picker("List View layout:", selection: pref({ p.listLayout }, { p.listLayout = $0 })) {
                    Text("Adaptive column width").tag(ListLayout.adaptive); Text("Fixed column width").tag(ListLayout.fixed)
                }
                Slider(value: pref({ p.listSpacing }, { p.listSpacing = $0 }), in: 0...12, step: 1) { Text("Item spacing:") }
            }
            Section("Icons & Gallery View") {
                Picker("Folder thumbnails:", selection: pref({ p.folderThumbnails }, { p.folderThumbnails = $0 })) {
                    ForEach(FolderThumbnails.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Note("Content-aware folder thumbnails are I/O-intensive and may render slow.")
                Slider(value: pref({ p.iconSpacing }, { p.iconSpacing = $0 }), in: 4...40, step: 2) { Text("Icon spacing:") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Sidebar

struct SidebarSettings: View {
    @EnvironmentObject var p: Preferences
    @State private var sections: [SidebarSection] = Preferences.shared.sidebarSections

    var body: some View {
        VStack(alignment: .leading) {
            Note("Shows or hides the top level items of respective category in the Folder Tree. Drag to rearrange.")
            List {
                ForEach($sections) { $s in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundColor(.secondary)
                        Toggle("", isOn: Binding(get: { !s.disabled }, set: { s.disabled = !$0; save() })).labelsHidden()
                        Menu {
                            ForEach(0..<TreeBuilder.palette.count, id: \.self) { i in
                                Button(i == 0 ? "Theme color" : "Color \(i)") { s.colorIndex = i; save() }
                            }
                        } label: { Image(systemName: s.icon).foregroundColor(Color(TreeBuilder.color(s.colorIndex))) }
                        .menuStyle(.borderlessButton).frame(width: 40)
                        Text(s.label)
                        if s.id == "trash" { Text("(requires Full Disk Access)").font(.caption).foregroundColor(.secondary) }
                        if s.id == "idevice" && !IDeviceRegistry.shared.isAvailable { Text("(install libimobiledevice)").font(.caption).foregroundColor(.secondary) }
                        if s.id == "mtp" && !MTPService.shared.isAvailable { Text("brew install libmtp").font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
                    }
                }
                .onMove { from, to in sections.move(fromOffsets: from, toOffset: to); save() }
            }
            .frame(minHeight: 420)
            Button("Restore Defaults") { sections = SidebarSection.defaults; save() }
            Note("Please note that **Recent files**, **Tags**, and **Star ratings** are based on Spotlight queries, and therefore only show the items located in the locations indexed by Spotlight.")
        }
    }

    func save() { p.sidebarSections = sections; NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil) }
}

// MARK: Context menu editor

struct ContextMenuSettings: View {
    @State private var entries = ContextMenuLayout.load()
    var body: some View {
        VStack(alignment: .leading) {
            Note("Drag to reorder. Items marked as alternate are initially invisible and replace the preceding item while holding **⌥ option**. Click an icon to toggle its visibility in the menu.")
            List {
                ForEach($entries) { $e in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundColor(.secondary)
                        if let c = e.command {
                            Toggle("", isOn: Binding(get: { e.visible }, set: { e.visible = $0; save() })).labelsHidden()
                            Button { e.iconVisible.toggle(); save() } label: { Image(systemName: c.symbol).opacity(e.iconVisible ? 1 : 0.3) }
                                .buttonStyle(.borderless).help("Show this command’s icon in the context menu")
                            Text(c.title).foregroundColor(e.visible ? .primary : .secondary)
                            Spacer()
                            if c.canBeAlternate {
                                Toggle("⌥", isOn: Binding(get: { e.alternate }, set: { e.alternate = $0; save() }))
                                    .toggleStyle(.button).help("Show this item only while the Option key is held, in place of the item above it.")
                            }
                        } else {
                            Divider().frame(maxWidth: .infinity)
                            Button { entries.removeAll { $0.id == e.id }; save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { f, t in entries.move(fromOffsets: f, toOffset: t); save() }
            }
            .frame(minHeight: 420)
            HStack {
                Button("Add Separator") { entries.insert(.separator(), at: 0); save() }
                Button("Restore Defaults") { entries = ContextMenuLayout.defaults; save() }
            }
        }
    }
    func save() { ContextMenuLayout.save(entries) }
}

// MARK: Scripting

struct ScriptingSettings: View {
    @ObservedObject var store = ActionsStore.shared
    @State private var installed = Privileged.shared.cliInstalled
    @State private var editing: ScriptAction?
    @State private var error: String?

    var body: some View {
        Form {
            Section("CLI Launcher") {
                Text(.init("Install the **explorer** command-line tool to open items from Terminal."))
                HStack {
                    if installed { Text("Installed at \(Privileged.cliPath)").foregroundColor(.secondary) }
                    else { Text(.init("The **explorer** command is not installed.")).foregroundColor(.secondary) }
                    Spacer()
                    Button(installed ? "Uninstall" : "Install…") {
                        let done: (Error?) -> Void = { e in
                            installed = Privileged.shared.cliInstalled
                            if let e {
                                if case OpError.cancelled = e {
                                    // User cancelled
                                } else {
                                    error = e.localizedDescription
                                }
                            } else {
                                error = nil
                            }
                        }
                        if installed { Privileged.shared.uninstallCLI(completion: done) } else { Privileged.shared.installCLI(completion: done) }
                    }
                }
                Note("Run **`explorer`** *`folder`* to open a folder in a new window, or **`explorer`** *`file`* to reveal a file. With no argument, **`explorer`** opens a new window.")
                Note("The tool will be copied to \(Privileged.cliPath). Administrator privileges are required.")
                if let error { Text(error).foregroundColor(.red).font(.caption) }
            }
            Section("Actions") {
                if store.items.isEmpty { Text("No actions yet. Add a shell or AppleScript command that receives the selected item(s).").foregroundColor(.secondary) }
                ForEach(store.items) { a in
                    HStack {
                        Toggle("", isOn: Binding(get: { a.enabled }, set: { v in if let i = store.items.firstIndex(of: a) { store.items[i].enabled = v } })).labelsHidden()
                        Image(systemName: a.kind == .shell ? "terminal" : "applescript")
                        Text(a.name)
                        Spacer()
                        Text(a.perFile ? "per file" : "batch").font(.caption).foregroundColor(.secondary)
                        Button("Edit") { editing = a }
                        Button { store.items.removeAll { $0.id == a.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Action…") { editing = ScriptAction(name: "New Action", kind: .shell, command: "", perFile: true) }
                Note("Note: these actions are not undoable.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { a in
            ActionEditView(action: a) { saved in
                if let saved {
                    if let i = store.items.firstIndex(where: { $0.id == saved.id }) { store.items[i] = saved } else { store.items.append(saved) }
                }
                editing = nil
            }
        }
    }
}

struct ActionEditView: View {
    @State var action: ScriptAction
    var done: (ScriptAction?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add / Edit Action").font(.headline)
            TextField("Name", text: $action.name)
            Picker("Kind", selection: $action.kind) { Text("Shell").tag(ScriptAction.Kind.shell); Text("AppleScript").tag(ScriptAction.Kind.appleScript) }.pickerStyle(.segmented)
            Text(action.kind == .shell ? "Action kind: a /bin/zsh shell command" : "Action kind: an AppleScript").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $action.command).font(.system(.body, design: .monospaced)).frame(minHeight: 160).border(Color.secondary.opacity(0.3))
            Toggle("Run per each selected file", isOn: $action.perFile)
            VStack(alignment: .leading, spacing: 2) {
                Text("Instructions").bold()
                Note("`{path}` – the selected item full path(s)")
                Note("`{name}` – the selected item(s) full file name (with extension)")
                Note("`{stem}` – the selected item(s) file name without extension")
                Note("`{dir}` – the current directory path")
            }
            HStack { Spacer(); Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction); Button("Save") { done(action) }.keyboardShortcut(.defaultAction).disabled(action.name.isEmpty || action.command.isEmpty) }
        }.padding(16).frame(width: 520)
    }
}
