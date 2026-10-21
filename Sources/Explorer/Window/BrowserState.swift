import AppKit
import Combine
import UniformTypeIdentifiers
import ExplorerKit

/// Everything one tab shows: location, history, contents, selection and view options.
final class BrowserState: ObservableObject {
    let prefs = Preferences.shared
    static let sessionStart = Date()

    @Published private(set) var location: Location
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var groups: [ItemGroup] = []
    @Published var selection: [FileItem] = [] { didSet { selectionDidChange.send() } }
    @Published var options: ViewOptions { didSet { optionsChanged(oldValue) } }
    @Published private(set) var isRemembered = false
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var warning: String?
    @Published private(set) var searchGathering = false
    @Published var tabTitle: String?
    @Published var tabColor: Int?
    @Published private(set) var recentlyChanged: Set<String> = []
    @Published private(set) var gitStatus: [String: GitStatus] = [:]
    @Published private(set) var folderSizes: [String: Int64] = [:]

    let selectionDidChange = PassthroughSubject<Void, Never>()
    /// Items to select once the next load finishes (after create/paste/reveal).
    var pendingSelection: [URL] = []
    /// Item to start renaming after the next load.
    var pendingRename: URL?

    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private(set) var archive: Archive?
    private(set) var git: Git?
    private var allItems: [FileItem] = []
    private var monitor: FolderMonitor?
    private var spotlight: SpotlightSearch?
    private var fullScan: FullScanSearch?
    private var loadToken = UUID()
    private var suppressOptionSave = false

    /// Asks the user for an archive password (shows malware warning first). nil = cancelled.
    var passwordProvider: ((URL) -> String?)?

    init(location: Location) {
        self.location = location
        self.options = Preferences.shared.defaultViewOptions
        applyRememberedOptions()
    }

    deinit { monitor?.stop(); spotlight?.stop(); fullScan?.cancel() }

    // MARK: Derived

    var currentDirectory: URL? {
        switch location {
        case .directory(let u): return u
        case .search(let s): return s.scope
        case .archive(let u, _): return u.deletingLastPathComponent()
        case .trash: return Volumes.userTrash
        default: return nil
        }
    }

    var isArchive: Bool { if case .archive = location { return true }; return false }
    var isSearch: Bool { if case .search = location { return true }; return false }
    var isSmart: Bool { if case .smart = location { return true }; return false }
    var isTrash: Bool { if case .trash = location { return true }; return false }
    var deviceLocation: (udid: String, path: String)? { if case .device(let u, let p) = location { return (u, p) }; return nil }
    var archiveInner: String { if case .archive(_, let i) = location { return i }; return "" }
    var canWrite: Bool {
        switch location {
        case .directory(let u): return FileManager.default.isWritableFile(atPath: u.path)
        case .archive: return archive?.isWritable ?? false
        default: return false
        }
    }

    var title: String {
        if let t = tabTitle, !t.isEmpty { return t }
        if case .directory(let u) = location {
            if u.standardizedFileURL.path == prefs.homeURL.standardizedFileURL.path { return "Home" }
            return FileNaming.displayName(of: u, preferPathNames: prefs.preferPathNames)
        }
        return location.title
    }

    var selectedURLs: [URL] { selection.map(\.url) }

    // MARK: Navigation

    func go(_ loc: Location, recordHistory: Bool = true, select: [URL] = []) {
        if loc == location && !select.isEmpty {
            pendingSelection = select
            applySelection()
            return
        }
        if recordHistory && loc != location {
            backStack.append(location)
            if backStack.count > 200 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        location = loc
        pendingSelection = select
        selection = []
        if case .directory(let u) = loc { prefs.addToHistory(u.path) }
        if case .device = loc, case .search = location {}
        applyRememberedOptions()
        reload()
    }

    func goBack() {
        guard let l = backStack.popLast() else { return }
        forwardStack.append(location)
        let prev = location
        location = l
        pendingSelection = prev.url.map { [$0] } ?? []
        selection = []
        applyRememberedOptions()
        reload()
    }

    func goForward() {
        guard let l = forwardStack.popLast() else { return }
        backStack.append(location)
        location = l
        selection = []
        applyRememberedOptions()
        reload()
    }

    func goUp() {
        guard let p = location.parent else { return }
        go(p, select: location.url.map { [$0] } ?? [])
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { location.parent != nil }

    /// Opens an item: folders navigate, archives browse (per setting), packages/files open externally.
    /// Returns false if the item should be opened by the system instead.
    func navigateInto(_ item: FileItem) -> Bool {
        if item.archivePath != nil {
            if item.isDirectory, case .archive(let u, _) = location {
                go(.archive(u, inner: item.archivePath!)); return true
            }
            return false
        }
        if let (udid, path) = IDeviceRegistry.parseVirtual(item.url) {
            if item.isDirectory { go(.device(udid: udid, path: path)); return true }
            return false
        }
        if item.isFolder || (item.isSymlink && item.isDirectory) {
            go(.directory(item.url.resolvingSymlinksInPath()))
            return true
        }
        if item.isAlias, let target = try? URL(resolvingAliasFileAt: item.url), target.hasDirectoryPath {
            go(.directory(target)); return true
        }
        if item.isArchive && prefs.openArchives == .within {
            go(.archive(item.url, inner: "")); return true
        }
        return false
    }

    // MARK: View options

    private func applyRememberedOptions() {
        suppressOptionSave = true
        defer { suppressOptionSave = false }
        if isArchive {
            options = prefs.archiveViewOptions
            isRemembered = false
            return
        }
        guard let path = location.url?.path else { return }
        if let o = ViewOptionsStore.shared.options(for: path, inherit: prefs.inheritViewOptions) {
            if o != options { options = o }
            isRemembered = true
        } else {
            let d = prefs.defaultViewOptions
            if d != options { options = d }
            isRemembered = false
        }
    }

    private func optionsChanged(_ old: ViewOptions) {
        guard !suppressOptionSave else { return }
        if isArchive {
            prefs.archiveViewOptions = options
        } else if isRemembered, let path = location.url?.path {
            let folder = ViewOptionsStore.shared.rememberingFolder(for: path, inherit: prefs.inheritViewOptions) ?? path
            ViewOptionsStore.shared.remember(options, for: folder)
        } else {
            prefs.defaultViewOptions = options
        }
        if old.showHidden != options.showHidden {
            reload()
        } else if old.sortKey != options.sortKey || old.sortOrder != options.sortOrder || old.folders != options.folders || old.grouping != options.grouping {
            rebuild()
        }
    }

    func toggleRemember() {
        guard let path = location.url?.path, !isArchive else { return }
        if isRemembered {
            ViewOptionsStore.shared.forget(ViewOptionsStore.shared.rememberingFolder(for: path, inherit: prefs.inheritViewOptions) ?? path)
            isRemembered = false
        } else {
            ViewOptionsStore.shared.remember(options, for: path)
            isRemembered = true
        }
    }

    // MARK: Loading

    func reload() {
        let token = UUID()
        loadToken = token
        monitor?.stop(); monitor = nil
        spotlight?.stop(); spotlight = nil
        fullScan?.cancel(); fullScan = nil
        errorMessage = nil
        warning = nil
        loading = true
        let loc = location
        let hidden = options.showHidden
        let preferPath = prefs.preferPathNames

        switch loc {
        case .directory(let dir):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let list = try FileItemLoader.list(dir, includeHidden: hidden, preferPathNames: preferPath)
                    DispatchQueue.main.async { self?.finishLoad(token, list) }
                } catch {
                    DispatchQueue.main.async { self?.failLoad(token, error) }
                }
            }
            startMonitor([dir.path])
            refreshGit(dir)
        case .trash:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let list = (try? FileItemLoader.list(Volumes.userTrash, includeHidden: hidden)) ?? []
                let err: Error? = Volumes.hasFullDiskAccess ? nil : OpError.message("Trash is only browsable when Explorer has Full Disk Access. Grant access in System Settings > Privacy & Security > Full Disk Access.")
                DispatchQueue.main.async {
                    if let err { self?.failLoad(token, err) } else { self?.finishLoad(token, list) }
                }
            }
            startMonitor([Volumes.userTrash.path])
        case .archive(let url, let inner):
            loadArchive(url, inner: inner, token: token)
        case .device(let udid, let path):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let list = try IDeviceRegistry.shared.list(udid: udid, path: path).filter { hidden || !$0.isHidden }
                    DispatchQueue.main.async { self?.finishLoad(token, list) }
                } catch {
                    DispatchQueue.main.async { self?.failLoad(token, error) }
                }
            }
        case .search(let spec):
            startSearch(spec, token: token)
        case .smart(let node):
            startSmart(node, token: token)
        }
    }

    private func finishLoad(_ token: UUID, _ list: [FileItem]) {
        guard token == loadToken else { return }
        allItems = list
        if prefs.boldRecentChanges {
            // Like the original: items modified since Explorer was launched are shown in bold.
            let cutoff = BrowserState.sessionStart
            recentlyChanged = Set(list.filter { !$0.isFolder && ($0.modified ?? .distantPast) >= cutoff }.map(\.id))
        } else {
            recentlyChanged = []
        }
        loading = false
        rebuild()
        applySelection()
    }

    private func failLoad(_ token: UUID, _ error: Error) {
        guard token == loadToken else { return }
        loading = false
        allItems = []
        errorMessage = error.localizedDescription
        rebuild()
    }

    /// Re-sorts/groups without hitting the disk.
    func rebuild() {
        var list = allItems
        if !gitStatus.isEmpty, let git {
            for i in list.indices { list[i].gitStatus = gitStatus[git.relative(list[i].url)] }
        }
        for i in list.indices where list[i].isFolder {
            if let s = folderSizes[list[i].url.path] { list[i].size = s }
        }
        let sorted = Sorter.sort(list, by: options.sortKey, order: options.sortOrder, folders: options.folders)
        items = sorted
        if options.grouping != .none && options.grouping != .kind && options.folders != .mixed {
            // Folders first/last: folders get their own group instead of being bucketed by date/size/…
            let folders = sorted.filter(\.isFolder), files = sorted.filter { !$0.isFolder }
            var g = Sorter.group(files, by: options.grouping)
            if !folders.isEmpty {
                let fg = ItemGroup(id: "folders", title: "Folders", order: 0, items: folders)
                if options.folders == .first { g.insert(fg, at: 0) } else { g.append(fg) }
            }
            groups = g
            items = g.flatMap(\.items)
        } else {
            groups = Sorter.group(sorted, by: options.grouping)
        }
        // Keep selection pointing at fresh values
        let ids = Set(selection.map(\.id))
        if !ids.isEmpty { selection = sorted.filter { ids.contains($0.id) } }
    }

    private func applySelection() {
        guard !pendingSelection.isEmpty else { return }
        let paths = Set(pendingSelection.map { $0.standardizedFileURL.path })
        let sel = items.filter { paths.contains($0.url.standardizedFileURL.path) }
        if !sel.isEmpty || !loading {
            selection = sel
            pendingSelection = []
        }
    }

    private func startMonitor(_ paths: [String]) {
        let m = FolderMonitor(paths: paths) { [weak self] _ in self?.softReload() }
        if !m.start() {
            warning = String(format: "The folder contents will not be updated automatically. File system event monitor failed to start (%@).", m.failure ?? "?")
        }
        monitor = m
    }

    /// Reload triggered by FS events: keeps selection and monitors.
    func softReload() {
        guard case .directory(let dir) = location else {
            if isTrash { reload() }
            return
        }
        let token = loadToken
        let hidden = options.showHidden
        let preferPath = prefs.preferPathNames
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = (try? FileItemLoader.list(dir, includeHidden: hidden, preferPathNames: preferPath)) ?? []
            DispatchQueue.main.async { self?.finishLoad(token, list) }
        }
        refreshGit(dir)
    }

    // MARK: Git

    private var gitWork: DispatchWorkItem?
    func refreshGit(_ dir: URL) {
        guard let root = Git.repositoryRoot(for: dir) else {
            git = nil
            if !gitStatus.isEmpty { gitStatus = [:] }
            return
        }
        let g = git?.root == root ? git! : Git(root: root)
        git = g
        gitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let st = (try? g.status()) ?? [:]
            DispatchQueue.main.async {
                guard let self, self.git === g else { return }
                if st != self.gitStatus { self.gitStatus = st; self.rebuild() }
            }
        }
        gitWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Folder sizes

    func calculateSizes(_ urls: [URL]) {
        for u in urls {
            FolderSizeCalculator.shared.calculate(u) { [weak self] size in
                self?.folderSizes[u.path] = size
                self?.rebuild()
            }
        }
    }

    // MARK: Archives

    private func loadArchive(_ url: URL, inner: String, token: UUID) {
        let existing = archive?.url == url ? archive : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let a = try existing ?? Archive(url: url)
                if existing == nil {
                    do { try a.load() } catch ArchiveError.passwordRequired {
                        var pw: String?
                        DispatchQueue.main.sync { pw = self?.passwordProvider?(url) }
                        guard let pw else { throw OpError.cancelled }
                        a.password = pw
                        try a.load()
                    }
                }
                let items = a.children(of: inner).map { Self.item(for: $0, in: a) }
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken else { return }
                    self.archive = a
                    self.finishLoad(token, items)
                }
            } catch OpError.cancelled {
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken else { return }
                    self.loading = false
                    if self.canGoBack { self.goBack() }
                }
            } catch {
                DispatchQueue.main.async { self?.failLoad(token, error) }
            }
        }
    }

    /// Reloads the archive TOC after modification.
    func reloadArchive() {
        guard case .archive(let u, _) = location else { return }
        if let a = archive, a.url == u { try? a.load() }
        reload()
    }

    static func item(for e: ArchiveEntry, in a: Archive) -> FileItem {
        let (size, csize) = a.totalSize(of: e)
        let ext = (e.name as NSString).pathExtension
        let type = e.isDirectory ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
        return FileItem(url: a.url.appendingPathComponent(e.path, isDirectory: e.isDirectory), archivePath: e.path, name: e.name,
                        isDirectory: e.isDirectory, isSymlink: e.isSymlink, isHidden: e.name.hasPrefix("."),
                        size: size, compressedSize: csize, modified: e.modified,
                        typeIdentifier: type.identifier, kind: type.localizedDescription ?? "")
    }

    // MARK: Search

    func search(_ text: String) {
        let scope: URL
        if case .search(let s) = location { scope = s.scope } else { scope = currentDirectory ?? prefs.homeURL }
        guard !text.isEmpty else {
            if case .search(let s) = location { go(.directory(s.scope)) }
            return
        }
        // iOS devices / non-indexed: full scan; otherwise the remembered preference.
        if let (udid, path) = deviceLocation {
            // Spotlight cannot index iOS devices: always a full scan over AFC, default unchanged.
            startDeviceSearch(text, udid: udid, path: path)
            return
        }
        let spec = SearchSpec(text: text, scope: scope, useSpotlight: prefs.searchWithSpotlight)
        if case .search = location { location = .search(spec); reload() } else { go(.search(spec)) }
    }

    func setSearchMode(spotlight: Bool) {
        prefs.searchWithSpotlight = spotlight
        guard case .search(var s) = location else { return }
        s.useSpotlight = spotlight
        location = .search(s)
        reload()
    }

    private func startSearch(_ spec: SearchSpec, token: UUID) {
        allItems = []
        searchGathering = true
        if spec.useSpotlight {
            let s = SpotlightSearch()
            spotlight = s
            let pred = spec.rawQuery.flatMap(SpotlightSearch.rawQueryPredicate) ?? SpotlightSearch.namePredicate(spec.text)
            s.start(predicate: pred, scopes: [spec.scope]) { [weak self] urls, gathering in
                self?.searchResults(token, urls, gathering: gathering)
            }
        } else {
            let f = FullScanSearch()
            fullScan = f
            var acc: [URL] = []
            f.run(text: spec.text, in: spec.scope, includeHidden: options.showHidden, found: { [weak self] batch in
                acc += batch
                self?.searchResults(token, acc, gathering: true)
            }, done: { [weak self] in
                self?.searchResults(token, acc, gathering: false)
            })
        }
    }

    private func searchResults(_ token: UUID, _ urls: [URL], gathering: Bool) {
        guard token == loadToken else { return }
        searchGathering = gathering
        let hidden = options.showHidden
        let capped = Array(urls.prefix(20000))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = capped.compactMap { FileItemLoader.load($0) }.filter { hidden || !$0.isHidden }
            DispatchQueue.main.async { self?.finishLoad(token, list) }
        }
    }

    private func startDeviceSearch(_ text: String, udid: String, path: String) {
        let token = UUID()
        loadToken = token
        loading = true
        searchGathering = true
        let needle = text.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileItem] = []
            var queue = [path]
            while let p = queue.popLast() {
                guard self?.loadToken == token else { return }
                for it in (try? IDeviceRegistry.shared.list(udid: udid, path: p)) ?? [] {
                    if it.name.lowercased().contains(needle) { found.append(it) }
                    if it.isDirectory, let (_, sub) = IDeviceRegistry.parseVirtual(it.url) { queue.append(sub) }
                }
            }
            DispatchQueue.main.async {
                self?.searchGathering = false
                self?.finishLoad(token, found)
            }
        }
    }

    private func startSmart(_ node: SmartNode, token: UUID) {
        allItems = []
        searchGathering = true
        let pred: NSPredicate
        var scopes: [Any] = [NSMetadataQueryLocalComputerScope]
        switch node {
        case .recent(let days): pred = SpotlightSearch.recentPredicate(days: days)
        case .colorTag(let i): pred = SpotlightSearch.tagPredicate(FinderColor(rawValue: i)?.name ?? "")
        case .textTag(let t): pred = SpotlightSearch.tagPredicate(t)
        case .rating(let r): pred = SpotlightSearch.ratingPredicate(r)
        case .savedSearch(let u):
            guard let f = SavedSearchFile.read(u), let p = SpotlightSearch.rawQueryPredicate(f.rawQuery) else {
                failLoad(token, OpError.message("Could not read the saved search.")); return
            }
            pred = p; scopes = f.queryScopes
        }
        let s = SpotlightSearch()
        spotlight = s
        s.start(predicate: pred, scopes: scopes) { [weak self] urls, gathering in
            self?.searchResults(token, urls, gathering: gathering)
        }
    }

    // MARK: Selection helpers

    func select(urls: [URL]) {
        pendingSelection = urls
        applySelection()
    }

    func item(at url: URL) -> FileItem? { items.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path } }
}
