import AppKit
import ExplorerKit

// MARK: - Path bar

/// Interactive path control (Finder-like) or editable path string; ⇧⌘G focuses it for typing,
/// with folder-name completions.
final class PathBarView: NSView, NSPathControlDelegate, NSTextFieldDelegate {
    weak var host: BrowserWindowController?
    private let control = NSPathControl()   // kept for its click/menu behaviour on string-mode fallback
    private let crumbs = NSStackView()
    private let field = NSTextField()
    private let suggestions = PathSuggestions()
    private var editing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        control.pathStyle = .standard
        control.isEditable = false
        control.target = self
        control.action = #selector(componentClicked)
        control.delegate = self
        control.focusRingType = .none
        control.backgroundColor = .clear
        control.alignment = .left
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        let sep = NSBox(); sep.boxType = .separator
        crumbs.orientation = .horizontal
        crumbs.spacing = 4
        crumbs.alignment = .centerY
        crumbs.setHuggingPriority(.required, for: .horizontal)
        crumbs.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        [control, field, sep, crumbs].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        control.isHidden = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), control.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(beginEditingFromClick))
        click.numberOfClicksRequired = 2
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let st = host?.state else { return }
        let interactive = Preferences.shared.pathBarStyle == .interactive && !editing
        control.isHidden = true
        crumbs.isHidden = !interactive
        field.isHidden = interactive
        field.isEditable = editing
        let url: URL?
        switch st.location {
        case .archive(let a, let inner): url = a.appendingPathComponent(inner)
        case .device(let udid, let p): url = nil; field.stringValue = IDeviceRegistry.shared.deviceName(udid) + ":" + p
        default: url = st.location.url ?? st.currentDirectory
        }
        if let url {
            buildCrumbs(url)
            if !editing { field.stringValue = url.path }
        } else if case .device = st.location {} else {
            control.url = nil
            field.stringValue = st.title
        }
        if !interactive && !editing { field.isHidden = false; crumbs.isHidden = true }
    }

    /// Path items from the volume root down, with a trailing chevron item (Folders Pro shows "›" after the last component).
    static func items(for url: URL) -> [NSPathControlItem] {
        var urls = url.standardizedFileURL.selfAndAncestors.reversed().map { $0 }
        // Start at the volume (e.g. "Macintosh HD") rather than "/" + "System/Volumes/Data"
        if let vol = try? url.resourceValues(forKeys: [.volumeURLKey]).volume, vol.path != "/" {
            urls = urls.filter { $0.path.count >= vol.path.count }
        }
        return urls.map { u in
            let i = NSPathControlItem()
            let name = u.path == "/" ? ((try? u.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD") : FileManager.default.displayName(atPath: u.path)
            i.attributedTitle = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            let icon = NSWorkspace.shared.icon(forFile: u.path); icon.size = NSSize(width: 16, height: 16)
            i.image = icon
            pathURLs[ObjectIdentifier(i)] = u
            return i
        }
    }
    static var pathURLs: [ObjectIdentifier: URL] = [:]

    private func buildCrumbs(_ url: URL) {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = PathBarView.items(for: url)
        for (idx, it) in items.enumerated() {
            let b = CrumbButton(title: it.attributedTitle.string, image: it.image, target: self, action: #selector(crumbClicked(_:)))
            b.url = PathBarView.pathURLs[ObjectIdentifier(it)]
            b.isLast = idx == items.count - 1
            crumbs.addArrangedSubview(b)
            let chev = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!)
            chev.contentTintColor = .secondaryLabelColor
            crumbs.addArrangedSubview(chev)
            crumbs.setCustomSpacing(10, after: chev)
            crumbs.setCustomSpacing(8, after: b)
        }
    }

    @objc private func crumbClicked(_ b: CrumbButton) {
        guard let u = b.url else { return }
        if NSEvent.modifierFlags.contains(.command) { AppDelegate.shared.openTab(.directory(u), from: host); return }
        host?.state.go(.directory(u))
    }

    @objc private func componentClicked() {
        guard let item = control.clickedPathItem, let u = item.url ?? PathBarView.pathURLs[ObjectIdentifier(item)], let st = host?.state else { return }
        if case .archive(let a, _) = st.location, u.path.hasPrefix(a.path), u.path != a.path {
            let inner = String(u.path.dropFirst(a.path.count + 1)) + "/"
            st.go(.archive(a, inner: inner))
        } else if case .archive(let a, _) = st.location, u.path == a.path {
            st.go(.archive(a, inner: ""))
        } else {
            st.go(.directory(u))
        }
    }

    func pathControl(_ pathControl: NSPathControl, willPopUp menu: NSMenu) {}

    @objc private func beginEditingFromClick() { beginEditing() }

    func beginEditing() {
        editing = true
        isHidden = false
        refresh()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard editing else { return }
        suggestions.show(for: field.stringValue, below: field) { [weak self] picked in
            self?.field.stringValue = picked
            self?.field.currentEditor()?.moveToEndOfLine(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.moveDown(_:)) { suggestions.moveSelection(1); return true }
        if sel == #selector(NSResponder.moveUp(_:)) { suggestions.moveSelection(-1); return true }
        if sel == #selector(NSResponder.insertTab(_:)), let s = suggestions.current { field.stringValue = s; textView.moveToEndOfLine(nil); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endEditing(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if let s = suggestions.current, suggestions.isVisible { field.stringValue = s }
            go(field.stringValue)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { if editing { endEditing() } }

    private func endEditing() {
        editing = false
        suggestions.hide()
        refresh()
        host?.fileView.focus()
        if !Preferences.shared.showPathBar { isHidden = true }
    }

    private func go(_ text: String) {
        let p = (text as NSString).expandingTildeInPath
        var d: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &d) {
            let u = URL(fileURLWithPath: p, isDirectory: d.boolValue)
            if d.boolValue { host?.state.go(.directory(u)) } else { host?.state.go(.directory(u.deletingLastPathComponent()), select: [u]) }
            endEditing()
        } else {
            NSSound.beep()
        }
    }
}

/// Popup list of folder completions under the path field.
final class PathSuggestions {
    private var panel: NSPanel?
    private let table = NSTableView()
    private var items: [String] = []
    private var onPick: ((String) -> Void)?
    private lazy var source = Source(owner: self)
    var isVisible: Bool { panel?.isVisible ?? false }
    var current: String? { let r = table.selectedRow; return items.indices.contains(r) ? items[r] : nil }

    final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var owner: PathSuggestions?
        init(owner: PathSuggestions) { self.owner = owner }
        func numberOfRows(in tableView: NSTableView) -> Int { owner?.items.count ?? 0 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let t = NSTextField(labelWithString: owner?.items[row] ?? "")
            t.lineBreakMode = .byTruncatingHead
            return t
        }
        @objc func clicked() { if let o = owner, let c = o.current { o.onPick?(c); o.hide() } }
    }

    func show(for text: String, below field: NSView, pick: @escaping (String) -> Void) {
        onPick = pick
        let expanded = (text as NSString).expandingTildeInPath
        let dir = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        items = names.filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(prefix) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0), isDirectory: &d) && d.boolValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(12).map { (dir as NSString).appendingPathComponent($0) + "/" }
        guard !items.isEmpty, let w = field.window else { hide(); return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.hasShadow = true
            p.level = .popUpMenu
            let scroll = NSScrollView()
            table.addTableColumn(NSTableColumn(identifier: .init("s")))
            table.headerView = nil
            table.dataSource = source
            table.delegate = source
            table.target = source
            table.action = #selector(Source.clicked)
            scroll.documentView = table
            p.contentView = scroll
            panel = p
        }
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        let r = w.convertToScreen(field.convert(field.bounds, to: nil))
        let h = CGFloat(items.count) * (table.rowHeight + 2) + 6
        panel!.setFrame(NSRect(x: r.minX, y: r.minY - h - 2, width: max(r.width, 300), height: h), display: true)
        if panel!.parent == nil { w.addChildWindow(panel!, ordered: .above) }
        panel!.orderFront(nil)
    }

    func moveSelection(_ d: Int) {
        guard !items.isEmpty else { return }
        let r = max(0, min(items.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func hide() {
        if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil) }
    }
}

// MARK: - Status bar

final class StatusBarView: NSView {
    weak var host: BrowserWindowController?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = ThemeColors.theme.withAlphaComponent(dark ? 0.09 : 0.05).cgColor
    }
    /// The per-view toggle buttons live on the left of the bottom bar, like the original.
    weak var toggles: ActionToolbarView? {
        didSet {
            guard let t = toggles, t.superview !== self else { return }
            t.removeFromSuperview()
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), t.centerYAnchor.constraint(equalTo: centerYAnchor),
                t.trailingAnchor.constraint(lessThanOrEqualTo: opLabel.leadingAnchor, constant: -8),
            ])
            label.isHidden = true
        }
    }
    private let label = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let opLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        viewDidChangeEffectiveAppearance()
        for l in [label, right, opLabel] { l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor; l.lineBreakMode = .byTruncatingMiddle }
        right.textColor = .labelColor
        right.font = .systemFont(ofSize: 12, weight: .medium)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        for b in [pauseButton, cancelButton] { b.isBordered = false; b.target = self }
        pauseButton.action = #selector(togglePause)
        cancelButton.action = #selector(cancelOp)
        let sep = NSBox(); sep.boxType = .separator
        [label, right, progress, opLabel, pauseButton, cancelButton, sep].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            sep.topAnchor.constraint(equalTo: topAnchor), sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            opLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            opLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: opLabel.trailingAnchor, constant: 6), progress.widthAnchor.constraint(equalToConstant: 120),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            pauseButton.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 4), pauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 2), cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshProgress() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    func refresh() {
        guard let st = host?.state else { return }
        let n = st.items.count
        let selCount = st.selection.count
        let text: String
        if selCount > 0 {
            let size = st.selection.compactMap(\.size).reduce(0, +)
            text = String(format: "%lld of %lld selected", Int64(selCount), Int64(n)) + (size > 0 ? ", " + SizeFormat.string(size) : "")
        } else {
            let size = st.items.filter { !$0.isFolder || $0.isPackage }.compactMap(\.size).reduce(0, +)
            text = String(format: n == 1 ? "%lld item" : "%lld items", Int64(n)) + (size > 0 ? ", " + SizeFormat.string(size) : "") + (st.loading ? " — Loading..." : "")
        }
        label.stringValue = text
        right.stringValue = text
        right.toolTip = st.currentDirectory.flatMap { Volumes.volume(containing: $0)?.available }.map { SizeFormat.string($0) + " available" }
        refreshProgress()
    }

    private var currentOp: FileOperation? { FileOps.shared.running.last }

    private func refreshProgress() {
        let show = currentOp != nil && Preferences.shared.showProgressStripe
        for v in [progress, opLabel, pauseButton, cancelButton] as [NSView] { v.isHidden = !show }
        guard let op = currentOp, show else { return }
        progress.doubleValue = op.fractionCompleted
        let state = op.state == .paused ? "Operation paused" : op.kind.progressTitle
        opLabel.stringValue = op.totalItems > 1 ? "\(state) \(min(op.completedItems + 1, op.totalItems))/\(op.totalItems) \(op.currentName)" : "\(state) \(op.currentName)"
        pauseButton.image = NSImage(systemSymbolName: op.state == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    @objc private func togglePause() { guard let op = currentOp else { return }; op.state == .paused ? op.resume() : op.pause() }
    @objc private func cancelOp() { currentOp?.cancel() }
}

// MARK: - Banner (errors, warnings, search mode)

final class BannerView: NSView {
    enum Style { case info, warning, error }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11)
        buttons.orientation = .horizontal
        [label, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, style: Style, actions: [(String, () -> Void)] = []) {
        label.stringValue = text
        let c: NSColor = style == .error ? .systemRed : style == .warning ? .systemOrange : .systemBlue
        layer?.backgroundColor = c.withAlphaComponent(0.12).cgColor
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        self.actions = actions.map(\.1)
        for (i, a) in actions.enumerated() {
            let b = NSButton(title: a.0, target: self, action: #selector(tap(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.tag = i
            buttons.addArrangedSubview(b)
        }
        isHidden = false
    }

    func hide() { isHidden = true }
    @objc private func tap(_ b: NSButton) { if actions.indices.contains(b.tag) { actions[b.tag]() } }
}

// MARK: - Title view in toolbar

final class TitleView: NSView {
    weak var host: BrowserWindowController? { didSet { refresh() } }
    var showsIcon = true { didSet { icon.isHidden = !showsIcon; iconWidth?.constant = showsIcon ? 16 : 0; gap?.constant = showsIcon ? 5 : 0 } }
    private var iconWidth: NSLayoutConstraint?
    private var gap: NSLayoutConstraint?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var observer: Any?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        label.font = .boldSystemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        [icon, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 80), widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16); iconWidth?.isActive = true
        gap = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5); gap?.isActive = true
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        observer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let st = host?.state else { return }
        if label.stringValue != st.title { label.stringValue = st.title }
        if let u = st.location.url { icon.image = NSWorkspace.shared.icon(forFile: u.path) }
        else { icon.image = NSImage(systemSymbolName: st.isSearch ? "magnifyingglass" : "tray.full", accessibilityDescription: nil) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Path popup like Finder's title menu
        guard let u = host?.state.currentDirectory else { return nil }
        let m = NSMenu()
        for p in u.selfAndAncestors {
            let it = Menus.item(FileNaming.displayName(of: p), #selector(BrowserWindowController.goRecent(_:)), represented: p.path)
            let ic = NSWorkspace.shared.icon(forFile: p.path); ic.size = NSSize(width: 16, height: 16); it.image = ic
            m.addItem(it)
        }
        return m
    }
}

// MARK: - Action toolbar (bottom of file view)

/// Per-view toggles: hidden files, thumbnails, time in dates, item traits, Live Text, info panel; Gallery tools.
final class ActionToolbarView: NSView {
    weak var host: BrowserWindowController?
    private let stack = NSStackView()
    private let gallery = NSStackView()
    private let zoomLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        gallery.orientation = .horizontal
        stack.spacing = 4; gallery.spacing = 2
        [stack, gallery].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            gallery.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 12), gallery.centerYAnchor.constraint(equalTo: centerYAnchor),
            gallery.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ tip: String, _ sel: Selector, on: Bool? = nil) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
        let b = NSButton(image: img, target: nil, action: sel)
        b.isBordered = false
        b.toolTip = tip
        b.imageScaling = .scaleNone
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.contentTintColor = (on ?? false) ? .controlAccentColor : .secondaryLabelColor
        return b
    }

    func refresh() {
        guard let st = host?.state else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        gallery.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let o = st.options
        stack.addArrangedSubview(button("eye.slash", "Show hidden files (⌘.)", #selector(BrowserWindowController.toggleHidden(_:)), on: o.showHidden))
        stack.addArrangedSubview(button("photo.on.rectangle.angled", "Show thumbnails", #selector(BrowserWindowController.toggleThumbnails(_:)), on: o.showThumbnails))
        if o.view == .table || st.isArchive {
            stack.addArrangedSubview(button("clock.badge.xmark", "Show/Hide Time in Dates", #selector(BrowserWindowController.toggleTimeInDates(_:)), on: !st.prefs.showTimeInDates))
        }
        if o.view == .icons || o.view == .gallery {
            stack.addArrangedSubview(button("tag", "Show item traits", #selector(BrowserWindowController.toggleTraits(_:)), on: o.showTraits))
        }
        if o.view == .gallery {
            stack.addArrangedSubview(button("character.cursor.ibeam", "Use Live Text", #selector(BrowserWindowController.toggleLiveText(_:)), on: o.liveText))
        }
        stack.addArrangedSubview(button("info.circle", "Show File Info (⌘I)", #selector(BrowserWindowController.toggleInfo(_:)), on: o.showInfo))
        if o.view == .icons {
            gallery.addArrangedSubview(button("minus.magnifyingglass", "Zoom out (⌘-)", #selector(BrowserWindowController.zoomOut(_:))))
            gallery.addArrangedSubview(button("plus.magnifyingglass", "Zoom in (⌘=)", #selector(BrowserWindowController.zoomIn(_:))))
        }
        if o.view == .gallery, let g = host?.fileView as? GalleryViewController {
            gallery.addArrangedSubview(button(g.preview.lockZoom ? "lock" : "lock.open", "Lock zoom", #selector(GalleryActions.lockZoom(_:))))
            gallery.addArrangedSubview(button("minus.magnifyingglass", "Zoom out (⌘-)", #selector(BrowserWindowController.zoomOut(_:))))
            gallery.addArrangedSubview(button("plus.magnifyingglass", "Zoom in (⌘=)", #selector(BrowserWindowController.zoomIn(_:))))
            gallery.addArrangedSubview(button("rectangle", "White background", #selector(GalleryActions.bgWhite(_:))))
            gallery.addArrangedSubview(button("rectangle.fill", "Black background", #selector(GalleryActions.bgBlack(_:))))
            gallery.addArrangedSubview(button("rectangle.pattern.checkered", "Transparent background", #selector(GalleryActions.bgClear(_:))))
            gallery.addArrangedSubview(button("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip image horizontally", #selector(GalleryActions.flipH(_:))))
            gallery.addArrangedSubview(button("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip image vertically", #selector(GalleryActions.flipV(_:))))
            gallery.addArrangedSubview(button("arrow.counterclockwise", "Rotate image counterclockwise", #selector(GalleryActions.rotCCW(_:))))
            gallery.addArrangedSubview(button("arrow.clockwise", "Rotate image clockwise", #selector(GalleryActions.rotCW(_:))))
        }
        if st.selection.contains(where: { $0.cloud == .notDownloaded }) {
            gallery.addArrangedSubview(button("icloud.and.arrow.down", "Download Now", #selector(BrowserWindowController.downloadNow(_:))))
        }
        for case let b as NSButton in stack.arrangedSubviews + gallery.arrangedSubviews { b.target = host }
    }
}

/// Gallery-specific actions routed through the window controller.
@objc protocol GalleryActions {
    func lockZoom(_ sender: Any?)
    func bgWhite(_ sender: Any?)
    func bgBlack(_ sender: Any?)
    func bgClear(_ sender: Any?)
    func flipH(_ sender: Any?)
    func flipV(_ sender: Any?)
    func rotCW(_ sender: Any?)
    func rotCCW(_ sender: Any?)
}

extension BrowserWindowController: GalleryActions {
    private var gallery: GalleryViewController? { fileView as? GalleryViewController }
    @objc func lockZoom(_ sender: Any?) { gallery?.preview.lockZoom.toggle(); actionBar.refresh() }
    @objc func bgWhite(_ sender: Any?) { gallery?.preview.background = .white }
    @objc func bgBlack(_ sender: Any?) { gallery?.preview.background = .black }
    @objc func bgClear(_ sender: Any?) { gallery?.preview.background = .transparent }
    @objc func flipH(_ sender: Any?) { imageTransform(.flipH) }
    @objc func flipV(_ sender: Any?) { imageTransform(.flipV) }
    @objc func rotCW(_ sender: Any?) { imageTransform(.rotateCW) }
    @objc func rotCCW(_ sender: Any?) { imageTransform(.rotateCCW) }

    func imageTransform(_ t: ImageTransform) {
        if let g = gallery { g.transform(t); return }
        guard let it = state.selection.first, it.isImage, it.archivePath == nil else { return }
        do { try ImageEditor.apply(t, to: it.url); ThumbnailStore.shared.clearCache(); state.softReload(); info.refresh(force: true) }
        catch { Alerts.error("Error transforming image", error.localizedDescription, window: window) }
    }
}


/// Row under the path bar with the Actions pull-down (⚡︎), like the original.
final class ActionsRowView: NSView {
    weak var host: BrowserWindowController?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        popup.bezelStyle = .push
        popup.controlSize = .regular
        popup.isBordered = true
        if #available(macOS 26.0, *) { popup.bezelStyle = .glass }
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        popup.menu?.delegate = self
        let sep = NSBox(); sep.boxType = .separator
        [popup, sep].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        let m = popup.menu ?? NSMenu()
        m.removeAllItems()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Actions")?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        m.addItem(title)
        let sel = host?.state.selection ?? []
        for i in Menus.actionsMenu(selection: sel).items {
            m.addItem(i.copy() as! NSMenuItem)
        }
        for i in m.items where i.action == #selector(BrowserWindowController.runAction(_:)) { i.target = host }
    }
}

extension ActionsRowView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
}


/// One breadcrumb: small icon + medium-weight name, borderless, with a hover highlight.
final class CrumbButton: NSButton {
    var url: URL?
    var isLast = false
    private var tracking: NSTrackingArea?

    convenience init(title: String, image: NSImage?, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        self.imagePosition = .imageLeading
        self.imageHugsTitle = true
        self.isBordered = false
        self.target = target
        self.action = action
        self.font = .systemFont(ofSize: 13, weight: .regular)
        self.contentTintColor = .labelColor
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        let menu = NSMenu()
        self.menu = menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override var intrinsicContentSize: NSSize { let s = super.intrinsicContentSize; return NSSize(width: s.width + 8, height: max(s.height, 22)) }
}


/// The "view | sort | group | remember" capsule from the original's toolbar.
final class ViewOptionsControl: NSSegmentedControl {
    weak var host: BrowserWindowController?

    convenience init(host: BrowserWindowController) {
        self.init(frame: .zero)
        self.host = host
        segmentCount = 4
        trackingMode = .momentary
        segmentStyle = .separated
        if #available(macOS 26.0, *) { segmentStyle = .automatic; segmentDistribution = .fit }
        controlSize = .large
        target = self
        action = #selector(clicked)
        let tips = ["Choose File View", "Sorting", "Grouping", "Remember view options for this folder (⌘J)"]
        for (i, t) in tips.enumerated() { setToolTip(t, forSegment: i); setWidth(i == 3 ? 40 : 52, forSegment: i) }
        refresh()
    }

    private func img(_ name: String, chevron: Bool, updown: Bool = false) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        guard chevron else { return base }
        let chev = NSImage(systemSymbolName: updown ? "chevron.up.chevron.down" : "chevron.down", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!
        let size = NSSize(width: base.size.width + chev.size.width + 4, height: max(base.size.height, chev.size.height))
        let out = NSImage(size: size, flipped: false) { _ in
            base.draw(at: NSPoint(x: 0, y: (size.height - base.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            chev.draw(at: NSPoint(x: base.size.width + 4, y: (size.height - chev.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        out.isTemplate = true
        return out
    }

    func refresh() {
        guard let st = host?.state else { return }
        setImage(img(ViewKind.toolbarSymbol(st.options.view), chevron: true, updown: true), forSegment: 0)
        setImage(img("arrow.up.arrow.down", chevron: true), forSegment: 1)
        setImage(img("square.grid.3x1.below.line.grid.1x2", chevron: true), forSegment: 2)
        setImage(img(st.isRemembered ? "bookmark.fill" : "bookmark", chevron: false), forSegment: 3)
    }

    @objc private func clicked() {
        guard let host else { return }
        let seg = selectedSegment
        let menu: NSMenu?
        switch seg {
        case 0: menu = Menus.viewKindMenu(target: host)
        case 1: menu = Menus.sortMenu(target: host)
        case 2: menu = Menus.groupMenu(target: host)
        default: host.toggleRemember(nil); refresh(); return
        }
        guard let menu else { return }
        var x: CGFloat = 0
        for i in 0..<seg { x += width(forSegment: i) }
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: bounds.height + 4), in: self)
        refresh()
    }
}
