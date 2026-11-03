import AppKit
import Quartz
import AVKit
import ImageIO
import AVFoundation
import ExplorerKit

/// The File Info panel: preview, dates/size, EXIF & media metadata, tags/rating, comment, Open With,
/// hidden/locked, permissions, custom folder icon. Shows volume info when nothing is selected.
final class InfoPanelController: NSViewController, NSTextViewDelegate {
    weak var host: BrowserWindowController?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var shownIDs: [String] = []
    private var textEditURL: URL?
    private var textEncoding: String.Encoding = .utf8
    private weak var textView: NSTextView?
    private var saveWork: DispatchWorkItem?

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
    }

    func refresh(force: Bool = false) {
        guard isViewLoaded, let st = host?.state, st.options.showInfo else { return }
        let ids = st.selection.map { $0.id + "\($0.modified?.timeIntervalSince1970 ?? 0)\($0.tags)\($0.rating)\($0.labelNumber)" }
        if ids == shownIDs && !force && !ids.isEmpty { return }
        shownIDs = ids
        flushText()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sel = st.selection
        if sel.isEmpty { buildFolderInfo(st) }
        else if sel.count == 1 { buildSingle(sel[0], st) }
        else if sel.count <= 20 { buildMulti(sel, st) }
        else { add(label("Please select less files to see the selection details.", secondary: true)) }
    }

    // MARK: Builders

    private func buildFolderInfo(_ st: BrowserState) {
        guard let dir = st.currentDirectory, LocalFileBoundary.accepts(dir) else {
            add(title(st.title))
            add(row("Contains items: ", String(st.items.count)))
            return
        }
        add(preview(icon: NSWorkspace.shared.icon(forFile: dir.path)))
        add(title(st.title))
        if let it = FileItemLoader.load(dir) {
            addDates(it)
        }
        add(row("Contains items: ", String(st.items.count)))
        if let v = Volumes.volume(containing: dir) {
            add(header("Volume: " + v.name))
            if let c = v.capacity { add(row("Total volume capacity: ", SizeFormat.string(c))) }
            if let a = v.available { add(row("Free space on volume: ", SizeFormat.string(a))) }
            if let c = v.capacity, let a = v.available {
                let bar = NSLevelIndicator()
                bar.levelIndicatorStyle = .continuousCapacity
                bar.maxValue = Double(c)
                bar.doubleValue = Double(c - a)
                bar.warningValue = Double(c) * 0.85; bar.criticalValue = Double(c) * 0.95
                bar.widthAnchor.constraint(equalToConstant: 200).isActive = true
                add(bar)
            }
            if let f = v.format { add(row("Format: ", f)) }
        }
    }

    private func buildSingle(_ it: FileItem, _ st: BrowserState) {
        add(previewView(for: it, st))
        add(title(it.name))
        add(label(it.kind, secondary: true))
        if it.isFolder, it.isLocalFile {
            let n = FileItemLoader.childCount(it.url, includeHidden: st.options.showHidden) ?? 0
            add(row("Contains items: ", String(n)))
            let sizeRow = row("Size: ", it.size.map { SizeFormat.string($0) } ?? "···")
            add(sizeRow)
            if it.size == nil {
                let b = NSButton(title: "Calculate Size", target: host, action: #selector(BrowserWindowController.calculateFolderSize(_:)))
                b.controlSize = .small; b.bezelStyle = .rounded
                add(b)
            }
        } else if it.archivePath != nil {
            add(row("Original Size: ", SizeFormat.string(it.size)))
            if let c = it.compressedSize { add(row("Compressed Size: ", SizeFormat.string(c))) }
        } else {
            add(row("Size: ", SizeFormat.string(it.size)))
            if it.isLocalFile, let v = Volumes.volume(containing: it.url), let s = try? it.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                add(row("Space occupied on volume: ", SizeFormat.string(Int64(s)))); _ = v
            }
        }
        addDates(it)
        if it.isLocalFile {
            if it.isSymlink, let d = try? FileManager.default.destinationOfSymbolicLink(atPath: it.url.path) { add(row("Original: ", d)) }
            if let w = whereFrom(it.url) { add(row("Where from: ", w)) }
            addTagsAndRating([it])
            addComment(it)
            if !it.isFolder { addOpenWith(it) }
            addFlags(it)
            addPermissions([it.url])
            if it.isFolder { addCustomIcon(it.url) }
            let b = NSButton(title: "Show Info in Finder...", target: host, action: #selector(BrowserWindowController.showInfoInFinder(_:)))
            b.controlSize = .small
            add(b)
            addMetadata(it)
        }
    }

    private func buildMulti(_ items: [FileItem], _ st: BrowserState) {
        add(stackedPreview(items))
        add(title(String(format: "%lld Items Selected", Int64(items.count))))
        let total = items.compactMap(\.size).reduce(0, +)
        add(row("Size: ", SizeFormat.string(total)))
        for it in items {
            let line = NSTextField(labelWithString: "\(it.name) — \(it.kind), \(SizeFormat.string(it.size)), \(ItemStyle.dateDisplay().string(it.modified))")
            line.font = .systemFont(ofSize: 11)
            line.lineBreakMode = .byTruncatingMiddle
            add(line)
        }
        let real = items.filter(\.isLocalFile)
        if !real.isEmpty && real.count == items.count {
            addTagsAndRating(real)
            addPermissions(real.map(\.url))
        }
    }

    // MARK: Pieces

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        if !(v is NSButton) && !(v is NSLevelIndicator) {
            v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24).isActive = true
        }
    }

    private func title(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .boldSystemFont(ofSize: 13)
        t.isSelectable = true
        if Preferences.shared.truncateInfoNames { t.maximumNumberOfLines = 1; t.lineBreakMode = .byTruncatingMiddle }
        return t
    }

    private func label(_ s: String, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        if secondary { t.textColor = .secondaryLabelColor }
        return t
    }

    private func header(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        return t
    }

    private func row(_ k: String, _ v: String) -> NSView {
        let s = NSMutableAttributedString(string: k, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: v, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]))
        let t = NSTextField(labelWithAttributedString: s)
        t.isSelectable = true
        t.lineBreakMode = .byTruncatingMiddle
        return t
    }

    private func addDates(_ it: FileItem) {
        let dd = DateDisplay(length: Preferences.shared.dateLength, mode: Preferences.shared.dateMode, showTime: true)
        if let d = it.created { add(row("Created: ", dd.string(d))) }
        if let d = it.added { add(row("Added to folder: ", dd.string(d))) }
        if let d = it.modified { add(row("Last modified: ", dd.string(d))) }
        if let d = it.opened { add(row("Last accessed: ", dd.string(d))) }
    }

    private func whereFrom(_ u: URL) -> String? {
        guard let md = MDItemCreateWithURL(nil, u as CFURL), let arr = MDItemCopyAttribute(md, kMDItemWhereFroms) as? [String] else { return nil }
        return arr.first
    }

    // MARK: Previews

    private func preview(icon: NSImage) -> NSView {
        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.heightAnchor.constraint(equalToConstant: 128).isActive = true
        iv.widthAnchor.constraint(equalToConstant: 128).isActive = true
        return iv
    }

    private func previewView(for it: FileItem, _ st: BrowserState) -> NSView {
        var url = it.url
        if let inner = it.archivePath, let a = st.archive, !it.isDirectory {
            if let tmp = try? a.extractToTemp([inner]) { url = tmp.appendingPathComponent(inner) }
        }
        if !it.isLocalFile && it.archivePath == nil { return preview(icon: ThumbnailStore.icon(for: it, size: 128)) }
        // Editable text for small text files
        if it.isText, !it.isDirectory, it.archivePath == nil, (it.size ?? 0) < 100_000 {
            return textEditor(url)
        }
        if it.isMovie || it.isAudio {
            let p = AVPlayerView()
            p.player = AVPlayer(url: url)
            p.controlsStyle = .inline
            p.translatesAutoresizingMaskIntoConstraints = false
            p.heightAnchor.constraint(equalToConstant: it.isAudio ? 60 : 180).isActive = true
            p.widthAnchor.constraint(equalToConstant: 260).isActive = true
            return p
        }
        if it.isDirectory { return preview(icon: ThumbnailStore.icon(for: it, size: 128)) }
        let iv = NSImageView(image: ThumbnailStore.icon(for: it, size: 128))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.heightAnchor.constraint(equalToConstant: 200).isActive = true
        iv.widthAnchor.constraint(equalToConstant: 260).isActive = true
        var tItem = it; tItem.url = url; tItem.archivePath = nil
        ThumbnailStore.shared.thumbnail(for: tItem, size: 400, scale: 2, folderStyle: .systemIcon) { img in iv.image = img }
        if it.isImage, it.archivePath == nil {
            let container = NSStackView(views: [iv, imageTools()])
            container.orientation = .vertical
            return container
        }
        return iv
    }

    private func imageTools() -> NSView {
        func b(_ s: String, _ tip: String, _ sel: Selector) -> NSButton {
            let x = NSButton(image: NSImage(systemSymbolName: s, accessibilityDescription: tip)!, target: host, action: sel)
            x.isBordered = false; x.toolTip = tip
            return x
        }
        let s = NSStackView(views: [
            b("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip image horizontally", #selector(BrowserWindowController.flipH(_:))),
            b("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip image vertically", #selector(BrowserWindowController.flipV(_:))),
            b("arrow.counterclockwise", "Rotate image counterclockwise", #selector(BrowserWindowController.rotCCW(_:))),
            b("arrow.clockwise", "Rotate image clockwise", #selector(BrowserWindowController.rotCW(_:))),
        ])
        s.orientation = .horizontal
        return s
    }

    private func stackedPreview(_ items: [FileItem]) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 110).isActive = true
        v.widthAnchor.constraint(equalToConstant: 160).isActive = true
        for (i, it) in items.prefix(5).enumerated().reversed() {
            let iv = NSImageView(frame: NSRect(x: 20 + i * 10, y: 5 + i * 6, width: 90, height: 90))
            iv.image = ThumbnailStore.icon(for: it, size: 90)
            iv.frameCenterRotation = CGFloat(i * 5 - 10)
            v.addSubview(iv)
        }
        return v
    }

    private func textEditor(_ url: URL) -> NSView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.heightAnchor.constraint(equalToConstant: 200).isActive = true
        sv.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        var enc = String.Encoding.utf8
        if let data = try? Data(contentsOf: url), let s = Self.decode(data, encoding: &enc) {
            tv.string = s
            tv.isEditable = FileManager.default.isWritableFile(atPath: url.path)
            textEditURL = url
            textEncoding = enc
            tv.delegate = self
        } else {
            tv.string = "Unknown encoding. Editing is disabled."
            tv.isEditable = false
        }
        sv.documentView = tv
        textView = tv
        return sv
    }

    static func decode(_ d: Data, encoding: inout String.Encoding) -> String? {
        for e: String.Encoding in [.utf8, .utf16, .windowsCP1252, .macOSRoman] {
            if let s = String(data: d, encoding: e) { encoding = e; return s }
        }
        return nil
    }

    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushText() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func flushText() {
        saveWork?.cancel()
        guard let u = textEditURL, LocalFileBoundary.accepts(u), let tv = textView, tv.isEditable else { return }
        guard let data = tv.string.data(using: textEncoding) else {
            Alerts.error("Error saving file", "Could not encode text in the selected encoding.", window: view.window); return
        }
        if (try? Data(contentsOf: u)) != data { try? data.write(to: u, options: .atomic) }
    }

    // MARK: Tags & rating

    private func addTagsAndRating(_ items: [FileItem]) {
        add(header("Tags"))
        let dots = TagDotsView(selection: items)
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.widthAnchor.constraint(equalToConstant: 210).isActive = true
        dots.heightAnchor.constraint(equalToConstant: 26).isActive = true
        add(dots)
        let tags = Array(Set(items.flatMap(\.tags))).sorted()
        let tagRow = NSStackView()
        tagRow.orientation = .horizontal
        for t in tags {
            let b = NSButton(title: t + " ✕", target: self, action: #selector(removeTag(_:)))
            b.bezelStyle = .inline; b.controlSize = .small
            b.identifier = NSUserInterfaceItemIdentifier(t)
            tagRow.addArrangedSubview(b)
        }
        let plus = NSButton(image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add tag")!, target: self, action: #selector(addTag(_:)))
        plus.isBordered = false
        tagRow.addArrangedSubview(plus)
        add(tagRow)
        let stars = NSStackView()
        stars.orientation = .horizontal
        stars.spacing = 1
        let r = items.count == 1 ? items[0].rating : (items.allSatisfy { $0.rating == items[0].rating } ? items[0].rating : 0)
        let none = NSButton(image: NSImage(systemSymbolName: "star.slash", accessibilityDescription: "No Rating")!, target: self, action: #selector(rate(_:)))
        none.isBordered = false; none.tag = 0
        stars.addArrangedSubview(none)
        for i in 1...5 {
            let b = NSButton(image: NSImage(systemSymbolName: i <= r ? "star.fill" : "star", accessibilityDescription: "\(i)")!, target: self, action: #selector(rate(_:)))
            b.isBordered = false
            b.tag = i
            b.contentTintColor = i <= r ? .systemYellow : .tertiaryLabelColor
            stars.addArrangedSubview(b)
        }
        add(stars)
    }

    @objc private func rate(_ b: NSButton) { let mi = NSMenuItem(); mi.tag = b.tag; host?.setRating(mi) }
    @objc private func addTag(_ b: NSButton) {
        let m = Menus.textTagsMenu(selection: host?.state.selection ?? [])
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b)
    }
    @objc private func removeTag(_ b: NSButton) {
        guard let t = b.identifier?.rawValue else { return }
        let mi = NSMenuItem(); mi.representedObject = t
        host?.toggleTextTag(mi)
    }

    // MARK: Comment

    private func addComment(_ it: FileItem) {
        add(header("Comment"))
        let f = NSTextField(string: Metadata.finderComment(it.url) ?? "")
        f.placeholderString = "Finder comment"
        f.target = self
        f.action = #selector(commentChanged(_:))
        f.identifier = NSUserInterfaceItemIdentifier(it.url.path)
        f.widthAnchor.constraint(equalToConstant: 240).isActive = true
        add(f)
    }

    @objc private func commentChanged(_ f: NSTextField) {
        guard let p = f.identifier?.rawValue else { return }
        let script = "tell application \"Finder\" to set comment of (POSIX file \(ActionRunner.appleScriptQuote(p)) as alias) to \(ActionRunner.appleScriptQuote(f.stringValue))"
        DispatchQueue.global().async {
            let out = ActionRunner.runAppleScript(script)
            if out.status != 0 { DispatchQueue.main.async { Alerts.error("The AppleScript could not be completed.", out.log, window: f.window) } }
        }
    }

    // MARK: Open With

    private func addOpenWith(_ it: FileItem) {
        add(header("Open with: "))
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        let def = NSWorkspace.shared.urlForApplication(toOpen: it.url)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: it.url)
        for a in apps {
            pop.addItem(withTitle: FileManager.default.displayName(atPath: a.path) + (a == def ? " (default)" : ""))
            pop.lastItem?.representedObject = a
            let ic = NSWorkspace.shared.icon(forFile: a.path); ic.size = NSSize(width: 16, height: 16)
            pop.lastItem?.image = ic
        }
        if let def, let idx = apps.firstIndex(of: def) { pop.selectItem(at: idx) }
        pop.target = self
        pop.action = #selector(openWithChanged(_:))
        pop.identifier = NSUserInterfaceItemIdentifier(it.url.path)
        add(pop)
        let all = NSButton(title: "Set as Default...", target: self, action: #selector(setDefaultForType(_:)))
        all.controlSize = .small
        all.identifier = pop.identifier
        add(all)
    }

    @objc private func openWithChanged(_ p: NSPopUpButton) {
        guard let path = p.identifier?.rawValue, let app = p.selectedItem?.representedObject as? URL else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: URL(fileURLWithPath: path)) { _ in }
    }

    @objc private func setDefaultForType(_ b: NSButton) {
        guard let path = b.identifier?.rawValue,
              let p = (b.superview as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == path }),
              let app = p.selectedItem?.representedObject as? URL,
              let type = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]).contentType else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { e in
            if let e { DispatchQueue.main.async { Alerts.error("Set as Default", e.localizedDescription, window: nil) } }
        }
    }

    // MARK: Flags

    private func addFlags(_ it: FileItem) {
        let hidden = NSButton(checkboxWithTitle: "Hidden", target: self, action: #selector(flagChanged(_:)))
        hidden.state = it.isHidden ? .on : .off
        hidden.tag = 0
        hidden.identifier = NSUserInterfaceItemIdentifier(it.url.path)
        let locked = NSButton(checkboxWithTitle: "Locked", target: self, action: #selector(flagChanged(_:)))
        locked.state = it.isLocked ? .on : .off
        locked.tag = 1
        locked.identifier = hidden.identifier
        let s = NSStackView(views: [hidden, locked]); s.orientation = .horizontal
        add(s)
    }

    @objc private func flagChanged(_ b: NSButton) {
        guard let p = b.identifier?.rawValue else { return }
        let u = URL(fileURLWithPath: p)
        do {
            if b.tag == 0 { try Metadata.setHidden(u, b.state == .on) } else { try Metadata.setLocked(u, b.state == .on) }
            host?.state.softReload()
        } catch { Alerts.error("Change File Attribute", error.localizedDescription, window: view.window); b.state = b.state == .on ? .off : .on }
    }

    // MARK: Permissions

    private var permTargets: [URL] = []

    private func addPermissions(_ urls: [URL]) {
        permTargets = urls
        let disclosure = NSButton(title: "Permissions", target: self, action: #selector(togglePerms(_:)))
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        let lbl = header("Permissions")
        let hdr = NSStackView(views: [disclosure, lbl]); hdr.orientation = .horizontal
        add(hdr)
        let grid = permissionsGrid(urls)
        grid.isHidden = true
        grid.identifier = NSUserInterfaceItemIdentifier("permGrid")
        add(grid)
        if urls.count == 1, let o = Metadata.owner(urls[0]) {
            let ow = row("Owner: ", "\(o.user) / \(o.group)")
            ow.identifier = NSUserInterfaceItemIdentifier("permOwner")
            ow.isHidden = true
            add(ow)
        }
    }

    @objc private func togglePerms(_ b: NSButton) {
        for v in stack.arrangedSubviews where ["permGrid", "permOwner"].contains(v.identifier?.rawValue) { v.isHidden = b.state == .off }
    }

    private func permissionsGrid(_ urls: [URL]) -> NSView {
        let modes = urls.compactMap(Metadata.posixPermissions)
        let rows = [("Owner", 6), ("Group", 3), ("Others", 0)]
        var views: [[NSView]] = [[NSTextField(labelWithString: ""), NSTextField(labelWithString: "Read"), NSTextField(labelWithString: "Write"), NSTextField(labelWithString: "Execute")]]
        for (name, shift) in rows {
            var r: [NSView] = [NSTextField(labelWithString: name)]
            for (bit, _) in [(4, "r"), (2, "w"), (1, "x")] {
                let mask = bit << shift
                let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(permChanged(_:)))
                cb.allowsMixedState = true
                let on = modes.filter { $0 & mask != 0 }.count
                cb.state = on == 0 ? .off : (on == modes.count ? .on : .mixed)
                cb.tag = mask
                r.append(cb)
            }
            views.append(r)
        }
        let g = NSGridView(views: views)
        g.columnSpacing = 10
        g.rowSpacing = 2
        for v in g.subviews { (v as? NSTextField)?.font = .systemFont(ofSize: 11) }
        return g
    }

    @objc private func permChanged(_ cb: NSButton) {
        if cb.state == .mixed { cb.state = .on }
        var failed: [URL] = []
        for u in permTargets {
            guard var m = Metadata.posixPermissions(u) else { continue }
            if cb.state == .on { m |= cb.tag } else { m &= ~cb.tag }
            do { try Metadata.setPosixPermissions(u, m) } catch { failed.append(u) }
        }
        if !failed.isEmpty {
            let a = NSAlert()
            a.messageText = "Change File Permissions"
            a.informativeText = "You don’t have permission to change the permissions of some items."
            a.addButton(withTitle: "Retry as Administrator"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                let ops = failed.compactMap { u -> Privileged.Op? in
                    guard var m = Metadata.posixPermissions(u) else { return nil }
                    if cb.state == .on { m |= cb.tag } else { m &= ~cb.tag }
                    return .chmod(m, u.path)
                }
                Privileged.shared.run(ops) { [weak self] e in
                    if let e, !(e is OpError) { Alerts.error("The operation could not be completed.", e.localizedDescription, window: self?.view.window) }
                    self?.refresh(force: true)
                }
            } else { refresh(force: true) }
        }
    }

    // MARK: Custom folder icon

    private func addCustomIcon(_ u: URL) {
        let b = NSButton(title: "Customize Folder Icon...", target: self, action: #selector(customizeIcon(_:)))
        b.controlSize = .small
        b.identifier = NSUserInterfaceItemIdentifier(u.path)
        add(b)
    }

    @objc private func customizeIcon(_ b: NSButton) {
        guard let p = b.identifier?.rawValue else { return }
        IconPicker.show(for: URL(fileURLWithPath: p), window: view.window) { [weak self] in
            NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
            self?.host?.state.softReload()
        }
    }

    // MARK: Metadata (EXIF / media)

    private func addMetadata(_ it: FileItem) {
        if it.isImage, let src = CGImageSourceCreateWithURL(it.url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            add(header("Image Metadata"))
            if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] { add(row("Pixel size: ", "\(w) × \(h)")) }
            if let dpi = props[kCGImagePropertyDPIWidth] { add(row("DPI: ", "\(dpi)")) }
            if let cm = props[kCGImagePropertyColorModel] { add(row("Color model: ", "\(cm)")) }
            if let prof = props[kCGImagePropertyProfileName] { add(row("Color profile: ", "\(prof)")) }
            if let a = props[kCGImagePropertyHasAlpha] as? Bool { add(row("Has alpha channel: ", a ? "Yes" : "No")) }
            if let o = props[kCGImagePropertyOrientation] as? Int { add(row("Orientation: ", Self.orientationName(o))) }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                if let mk = tiff[kCGImagePropertyTIFFMake] { add(row("Make: ", "\(mk)")) }
                if let md = tiff[kCGImagePropertyTIFFModel] { add(row("Model: ", "\(md)")) }
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                add(header("EXIF Data"))
                let keys: [(CFString, String)] = [
                    (kCGImagePropertyExifDateTimeOriginal, "Recording date"), (kCGImagePropertyExifExposureTime, "Exposure time"),
                    (kCGImagePropertyExifFNumber, "F number"), (kCGImagePropertyExifISOSpeedRatings, "ISO speed"),
                    (kCGImagePropertyExifFocalLength, "Focal length (mm)"), (kCGImagePropertyExifFocalLenIn35mmFilm, "Focal length (~35 mm)"),
                    (kCGImagePropertyExifLensModel, "Lens"), (kCGImagePropertyExifExposureProgram, "Exposure program"),
                    (kCGImagePropertyExifMeteringMode, "Metering mode"), (kCGImagePropertyExifFlash, "Flash"),
                    (kCGImagePropertyExifWhiteBalance, "White balance"), (kCGImagePropertyExifVersion, "EXIF version"),
                ]
                for (k, n) in keys { if let v = exif[k] { add(row(n + ": ", Self.format(v))) } }
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let la = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
                let lo = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
                add(row("Latitude: ", String(format: "%.6f", la)))
                add(row("Longitude: ", String(format: "%.6f", lo)))
                if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { add(row("Altitude: ", String(format: "%.1f m", alt))) }
                let b = NSButton(title: "Open in Maps", target: self, action: #selector(openMaps(_:)))
                b.controlSize = .small
                b.identifier = NSUserInterfaceItemIdentifier("\(la),\(lo)")
                add(b)
            }
        } else if it.isMovie || it.isAudio {
            let asset = AVURLAsset(url: it.url)
            add(header(it.isAudio ? "Audio Metadata" : "Video Metadata"))
            let dur = CMTimeGetSeconds(asset.duration)
            if dur.isFinite && dur > 0 {
                let f = DateComponentsFormatter(); f.allowedUnits = dur >= 3600 ? [.hour, .minute, .second] : [.minute, .second]; f.zeroFormattingBehavior = .pad
                add(row("Duration: ", f.string(from: dur) ?? ""))
            }
            for t in asset.tracks {
                if t.mediaType == .video { add(row("Pixel size: ", "\(Int(abs(t.naturalSize.width))) × \(Int(abs(t.naturalSize.height)))")); add(row("Video bit rate: ", "\(Int(t.estimatedDataRate / 1000)) kbps")) }
                if t.mediaType == .audio { add(row("Audio bit rate: ", "\(Int(t.estimatedDataRate / 1000)) kbps")) }
            }
            for md in asset.commonMetadata {
                guard let k = md.commonKey?.rawValue, let v = md.stringValue, !v.isEmpty else { continue }
                add(row(k.capitalized + ": ", v))
            }
        } else {
            let vals = MetadataValues.values(for: it.url, keys: ["kMDItemNumberOfPages", "kMDItemAuthors", "kMDItemTitle", "kMDItemVersion", "kMDItemPageWidth", "kMDItemPageHeight"])
            if !vals.isEmpty {
                add(header("Common Metadata"))
                let names = Dictionary(uniqueKeysWithValues: MetadataValues.renameKeys.map { ($0.key, $0.title) })
                for (k, v) in vals.sorted(by: { $0.key < $1.key }) { add(row((names[k] ?? k.replacingOccurrences(of: "kMDItem", with: "")) + ": ", v)) }
            }
        }
    }

    @objc private func openMaps(_ b: NSButton) {
        guard let ll = b.identifier?.rawValue, let u = URL(string: "maps://?ll=\(ll)&q=\(ll)") else { return }
        NSWorkspace.shared.open(u)
    }

    static func format(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        if let d = v as? Double {
            if d < 1 && d > 0 { return "1/\(Int((1 / d).rounded()))" }
            return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
        }
        return "\(v)"
    }

    static func orientationName(_ o: Int) -> String {
        ["", "Normal", "Mirrored horizontally", "Rotated 180°", "Mirrored vertically", "Mirrored horizontally, rotated 90° CCW",
         "Rotated 90° CW", "Mirrored horizontally, rotated 90° CW", "Rotated 90° CCW"][max(0, min(8, o))]
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
