import AppKit
import ExplorerKit

/// Table view (and Archive view when `archiveMode`): sortable, configurable columns, group rows,
/// inline rename, type-select, drag & drop.
final class TableViewController: NSViewController, FileViewing, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    var state: BrowserState!
    weak var host: BrowserWindowController?
    let archiveMode: Bool

    let table = FileTableView()
    private let scroll = NSScrollView()
    /// Flattened rows: group headers (String) or items.
    private var rows: [Row] = []
    private var suppressSelection = false
    private var renaming: URL?

    enum Row { case group(ItemGroup), item(FileItem) }

    init(archiveMode: Bool) {
        self.archiveMode = archiveMode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.drawsBackground = false
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.gridStyleMask = []
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.registerForDraggedTypes(DropIn.types)
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.headerView?.menu = headerMenu()
        table.owner = self
        buildColumns()
        view = scroll
    }

    // MARK: Columns

    private var settingsKey: [String: ColumnSetting] {
        get { archiveMode ? Preferences.shared.archiveColumns : Preferences.shared.tableColumns }
        set { if archiveMode { Preferences.shared.archiveColumns = newValue } else { Preferences.shared.tableColumns = newValue } }
    }

    private var availableColumns: [TableColumnID] {
        archiveMode ? [.fileName, .dateModified, .originalSize, .compressedSize, .fileType]
                    : [.fileName, .dateModified, .dateCreated, .dateAdded, .dateOpened, .size, .fileType, .tags, .rating, .git]
    }

    private func buildColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        let settings = settingsKey
        let defaults = archiveMode ? TableColumnID.archiveDefaults : TableColumnID.tableDefaults
        let ordered = availableColumns.sorted { (settings[$0.rawValue] ?? defaults[$0.rawValue])?.order ?? 99 < (settings[$1.rawValue] ?? defaults[$1.rawValue])?.order ?? 99 }
        for id in ordered {
            let s = settings[id.rawValue] ?? defaults[id.rawValue] ?? ColumnSetting(order: 99, isHidden: true, width: 100)
            let c = NSTableColumn(identifier: .init(id.rawValue))
            c.title = id.title
            c.headerCell = InsetHeaderCell(textCell: id.title)
            c.headerCell.attributedStringValue = NSAttributedString(string: id.title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            c.width = s.width
            c.minWidth = id == .fileName ? 120 : (id == .git ? 24 : 40)
            c.isHidden = id == .fileName ? false : s.isHidden
            if let key = id.sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true) }
            if [.rating, .compressedSize].contains(id) { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        updateSortIndicator()
    }

    private func saveColumns() {
        var s = settingsKey
        for (i, c) in table.tableColumns.enumerated() {
            s[c.identifier.rawValue] = ColumnSetting(order: i, isHidden: c.isHidden, width: c.width)
        }
        settingsKey = s
    }

    func tableViewColumnDidMove(_ notification: Notification) { saveColumns() }
    func tableViewColumnDidResize(_ notification: Notification) { saveColumns() }

    private func headerMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.headerView?.menu else { return }
        menu.removeAllItems()
        for c in table.tableColumns where c.identifier.rawValue != TableColumnID.fileName.rawValue {
            let i = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = c
            i.state = c.isHidden ? .off : .on
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let r = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns), keyEquivalent: "")
        r.target = self
        menu.addItem(r)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? NSTableColumn else { return }
        c.isHidden.toggle()
        saveColumns()
    }

    @objc private func resetColumns() {
        settingsKey = archiveMode ? TableColumnID.archiveDefaults : TableColumnID.tableDefaults
        buildColumns()
    }

    private func updateSortIndicator() {
        guard let o = state?.options else { return }
        table.sortDescriptors = [NSSortDescriptor(key: o.sortKey.rawValue, ascending: o.sortOrder == .ascending)]
        for c in table.tableColumns {
            let id = TableColumnID(rawValue: c.identifier.rawValue)
            let sorted = id.map { $0.sortKey == o.sortKey } ?? false
            c.headerCell.attributedStringValue = NSAttributedString(string: c.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: sorted ? .bold : .medium),
                .foregroundColor: sorted ? NSColor.labelColor : NSColor.secondaryLabelColor])
        }
        table.headerView?.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
        if state.options.sortKey != key || (state.options.sortOrder == .ascending) != d.ascending {
            state.options.sortKey = key
            state.options.sortOrder = d.ascending ? .ascending : .descending
        }
    }

    // MARK: Data

    func reloadItems() {
        guard isViewLoaded else { return }
        table.slowRename.cancel()
        let p = Preferences.shared
        table.rowHeight = CGFloat(p.rowHeight) + 1 + CGFloat(p.fontSizeDelta)
        table.usesAlternatingRowBackgroundColors = false   // FileRowView draws stripes per group
        if state.options.grouping == .none {
            rows = state.items.map { .item($0) }
        } else {
            rows = state.groups.flatMap { [Row.group($0)] + $0.items.map { Row.item($0) } }
        }
        updateSortIndicator()
        suppressSelection = true
        table.reloadData()
        suppressSelection = false
        syncSelection()
        if let r = state.pendingRename { state.pendingRename = nil; beginRename(r) }
    }

    func syncSelection() {
        let ids = Set(state.selection.map(\.id))
        var set = IndexSet()
        for (i, r) in rows.enumerated() { if case .item(let it) = r, ids.contains(it.id) { set.insert(i) } }
        if set != table.selectedRowIndexes {
            suppressSelection = true
            table.selectRowIndexes(set, byExtendingSelection: false)
            suppressSelection = false
            if let f = set.first { table.scrollRowToVisible(f) }
        }
    }

    var keyboardView: NSView { table }
    func focus() { view.window?.makeFirstResponder(table) }

    func item(at row: Int) -> FileItem? {
        guard rows.indices.contains(row), case .item(let it) = rows[row] else { return nil }
        return it
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(at: row) != nil }

    /// Group headers are taller with breathing room above (Folders Pro: ~30 pt header after a ~20 pt gap).
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // Measured from the original: first header 27 pt, later headers 41.5 pt (includes the gap above).
        if case .group = rows[row] { return row == 0 ? 28 : 42 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = FileRowView()
        if case .group = rows[row] { v.isGroupHeader = true; v.isFirstGroup = row == 0; return v }
        // Global alternation where header rows count too (row 0 = first header): even rows are striped.
        let grouped = state.options.grouping != .none
        v.stripe = Preferences.shared.alternatingRows && (grouped ? row % 2 == 0 : row % 2 == 1)
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let g):
            // Full-width group rows span all columns via isGroupRow; guard against per-column calls.
            if let col = tableColumn, col !== tableView.tableColumns.first(where: { !$0.isHidden }) { return nil }
            let a = NSMutableAttributedString(string: g.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor])
            a.append(NSAttributedString(string: "   \(g.items.count)", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.quaternaryLabelColor]))
            let v = GroupHeaderCell(text: a, topInset: row == 0 ? 5 : 24)
            return v
        case .item(let it):
            guard let col = tableColumn, let id = TableColumnID(rawValue: col.identifier.rawValue) else { return nil }
            return cell(for: it, column: id, table: tableView)
        }
    }

    private func cell(for it: FileItem, column: TableColumnID, table: NSTableView) -> NSView {
        let ident = NSUserInterfaceItemIdentifier("cell-\(column.rawValue)")
        let cell = (table.makeView(withIdentifier: ident, owner: self) as? FileCellView) ?? FileCellView(icon: column == .fileName)
        cell.identifier = ident
        let bold = Preferences.shared.boldRecentChanges && state.recentlyChanged.contains(it.id)
        let font = ItemStyle.font(12, bold: false)
        let dd = ItemStyle.dateDisplay()
        var text = ""
        var align: NSTextAlignment = .left
        switch column {
        case .fileName:
            let nameColor: NSColor = it.isHidden ? .tertiaryLabelColor : .labelColor
            let para = NSMutableParagraphStyle(); para.lineBreakMode = ItemStyle.truncation(Preferences.shared.truncateFiles)
            let s = NSMutableAttributedString(string: ItemStyle.displayName(it), attributes: [.font: ItemStyle.font(12, bold: bold), .foregroundColor: nameColor, .paragraphStyle: para])
            s.append(ItemStyle.badges(it))
            cell.text.attributedStringValue = s
            cell.text.lineBreakMode = ItemStyle.truncation(Preferences.shared.truncateFiles)
            cell.setIcon(for: it, state: state, size: 16)
            cell.text.delegate = self
            return cell
        case .dateModified: text = dd.string(it.modified); align = .right
        case .dateCreated: text = dd.string(it.created); align = .right
        case .dateAdded: text = dd.string(it.added); align = .right
        case .dateOpened: text = dd.string(it.opened); align = .right
        case .size, .originalSize:
            text = it.isFolder && it.archivePath == nil ? (it.size.map { SizeFormat.string($0) } ?? "--") : SizeFormat.string(it.size)
            align = .right
        case .compressedSize: text = it.isDirectory && it.compressedSize == nil ? "--" : SizeFormat.string(it.compressedSize); align = .right
        case .fileType: text = it.kind
        case .tags: text = (it.tags + (FinderColor(rawValue: it.labelNumber).map { [$0.name] } ?? [])).joined(separator: ", ")
        case .rating: text = it.rating > 0 ? String(repeating: "★", count: it.rating) : ""; align = .right
        case .git: text = it.gitStatus.map { String($0.rawValue) } ?? ""; align = .center
        }
        cell.text.font = bold && !it.isHidden ? ItemStyle.font(12, bold: true) : font
        cell.text.stringValue = text
        cell.text.alignment = align
        // Like the original: recently changed rows in full-strength text, older ones a step dimmer, hidden ones dimmest.
        cell.text.textColor = it.isHidden ? .tertiaryLabelColor : .labelColor
        cell.text.lineBreakMode = .byTruncatingTail
        if column == .git, let g = it.gitStatus { cell.text.textColor = ItemStyle.gitColor(g) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.slowRename.cancel()
        guard !suppressSelection else { return }
        state.selection = table.selectedRowIndexes.compactMap(item(at:))
    }

    // MARK: Actions

    @objc private func doubleClick() {
        table.slowRename.cancel()
        let r = table.clickedRow
        guard r >= 0, let it = item(at: r) else { return }
        host?.open([it], newWindow: false)
    }

    // MARK: Rename

    /// Second click on the selected row's name: rename after the double-click interval unless the
    /// selection, focus or window changed in the meantime.
    func armSlowRename(row: Int) {
        guard renaming == nil, let it = item(at: row), host?.canRenameInline(it) == true else { return }
        let id = it.id
        table.slowRename.schedule { [weak self] in
            guard let self, self.renaming == nil, let w = self.table.window, w.firstResponder === self.table,
                  self.state.selection.count == 1, self.state.selection.first?.id == id else { return }
            self.beginRename(it.url)
        }
    }

    func beginRename(_ url: URL) {
        table.slowRename.cancel()
        guard let row = rows.firstIndex(where: { if case .item(let i) = $0 { return i.url.standardizedFileURL == url.standardizedFileURL }; return false }),
              let colIdx = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == TableColumnID.fileName.rawValue }) else { return }
        table.scrollRowToVisible(row)
        table.selectRowIndexes([row], byExtendingSelection: false)
        guard let cell = table.view(atColumn: colIdx, row: row, makeIfNecessary: true) as? FileCellView, let it = item(at: row) else { return }
        renaming = it.url
        cell.text.isEditable = true
        cell.text.stringValue = it.name
        view.window?.makeFirstResponder(cell.text)
        if let ed = cell.text.currentEditor() {
            let stem = it.isFolder ? it.name : (it.name as NSString).deletingPathExtension
            ed.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let url = renaming else { return }
        renaming = nil
        field.isEditable = false
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.cancel.rawValue { reloadItems(); return }
        host?.commitRename(url, to: field.stringValue)
        focus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renaming = nil
            (control as? NSTextField)?.isEditable = false
            reloadItems(); focus()
            return true
        }
        return false
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        table.slowRename.dragBegan = true
        table.slowRename.cancel()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(at: row).flatMap { DragOut.writer(for: $0, state: state) }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on, let it = item(at: row), it.isDirectory {
            if state.isArchive { return (state.archive?.isWritable ?? false) ? .copy : [] }
            return DropIn.validate(info, dest: it.url, state: state)
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return DropIn.validate(info, dest: state.isArchive ? nil : state.currentDirectory, state: state)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        if op == .on, let it = item(at: row), it.isDirectory {
            return DropIn.perform(info, dest: it.url, archiveInner: it.archivePath, state: state, window: view.window)
        }
        return DropIn.perform(info, dest: state.currentDirectory, state: state, window: view.window)
    }

    // MARK: Context menu

    func menuFor(row: Int) -> NSMenu? {
        if row >= 0, let it = item(at: row) {
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            _ = it
        } else {
            table.deselectAll(nil)
        }
        return host?.contextMenu(for: state.selection, inTree: false)
    }

}

final class FileTableView: NSTableView {
    weak var owner: TableViewController?
    private let typeSelect = TypeSelect()
    let slowRename = SlowClickRename()

    override func mouseDown(with event: NSEvent) {
        slowRename.mouseDown(event)
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p), c = column(at: p)
        // Only a click on the name text of the one selected row in an already focused list arms a rename.
        var armed = false
        if r >= 0, c >= 0, selectedRowIndexes == IndexSet(integer: r),
           tableColumns[c].identifier.rawValue == TableColumnID.fileName.rawValue,
           window?.firstResponder === self,
           let cell = view(atColumn: c, row: r, makeIfNecessary: false) as? FileCellView {
            let text = cell.text
            let used = text.attributedStringValue.size().width
            var hit = text.frame
            hit.size.width = min(hit.width, used + 4)
            armed = hit.insetBy(dx: -2, dy: -3).contains(cell.convert(event.locationInWindow, from: nil))
        }
        super.mouseDown(with: event)   // tracks until mouse up (or a drag begins)
        if armed, slowRename.isPlainClick(event, in: window), let window {
            owner?.armSlowRename(row: r)
            slowRename.cancelWhenWindowResigns(window)
        }
    }

    override func rightMouseDown(with event: NSEvent) { slowRename.cancel(); super.rightMouseDown(with: event) }
    override func resignFirstResponder() -> Bool { slowRename.cancel(); return super.resignFirstResponder() }
    override func scrollWheel(with event: NSEvent) { slowRename.cancel(); super.scrollWheel(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        slowRename.cancel()
        let p = convert(event.locationInWindow, from: nil)
        return owner?.menuFor(row: row(at: p))
    }

    override func keyDown(with event: NSEvent) {
        slowRename.cancel()
        if let owner, let host = owner.host, host.handleKey(event) { return }
        if let ch = event.characters, !ch.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) || $0 == " " && typeSelect.active }) {
            if let owner, let idx = typeSelect.match(ch, in: (0..<numberOfRows).map { owner.item(at: $0).map { ItemStyle.displayName($0) } ?? "" }) {
                selectRowIndexes([idx], byExtendingSelection: false)
                scrollRowToVisible(idx)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Finder-style type-to-select.
final class TypeSelect {
    private var buffer = ""
    private var last = Date.distantPast
    var active: Bool { Date().timeIntervalSince(last) < 1 && !buffer.isEmpty }

    func match(_ chars: String, in names: [String]) -> Int? {
        if Date().timeIntervalSince(last) > 1 { buffer = "" }
        last = Date()
        buffer += chars.lowercased()
        if let exact = names.firstIndex(where: { $0.lowercased().hasPrefix(buffer) }) { return exact }
        // Otherwise the alphabetically closest name at or after the typed text.
        return names.indices.filter { names[$0].lowercased() >= buffer }.min { names[$0].lowercased() < names[$1].lowercased() }
    }
}

/// Icon + label cell used by table and list.
final class FileCellView: NSTableCellView {
    let iconView = NSImageView()
    let text = NSTextField(labelWithString: "")
    private var representedID: String?

    init(icon: Bool) {
        super.init(frame: .zero)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.usesSingleLineMode = true
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        addSubview(text)
        textField = text
        if icon {
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iconView)
            imageView = iconView
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.heightAnchor.constraint(equalToConstant: 17),
                iconView.widthAnchor.constraint(equalToConstant: 17),
                text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setIcon(for it: FileItem, state: BrowserState, size: CGFloat) {
        representedID = it.id
        iconView.image = ThumbnailStore.icon(for: it, size: size)
        iconView.alphaValue = it.isHidden ? 0.5 : 1
        // At list/table row sizes the original keeps plain document icons; thumbnails start at ≥32 pt.
        guard size >= 32, state.options.showThumbnails, !it.isFolder || Preferences.shared.folderThumbnails != .systemIcon, it.archivePath == nil else { return }
        if let c = ThumbnailStore.shared.cached(it, size: size) { iconView.image = c; return }
        let id = it.id
        ThumbnailStore.shared.thumbnail(for: it, size: size, scale: window?.backingScaleFactor ?? 2, folderStyle: Preferences.shared.folderThumbnails) { [weak self] img in
            guard self?.representedID == id else { return }
            self?.iconView.image = img
        }
    }
}


/// Row background: subtle stripes restarting per group; group headers get a hairline under them.
final class FileRowView: NSTableRowView {
    override var isFlipped: Bool { true }
    var stripe = false
    var isGroupHeader = false
    var isFirstGroup = false
    override func drawBackground(in dirtyRect: NSRect) {
        if stripe && !isGroupHeader {
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.minX + 11, y: bounds.minY, width: bounds.width - 11, height: bounds.height), xRadius: 5, yRadius: 5).fill()
        }
        if isGroupHeader && isFirstGroup {
            // Only the top group gets a rule (6 pt above its bottom), as in the original.
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.minY + 22, width: bounds.width, height: 1).fill()
        }
    }
}

/// Group title pinned to the bottom of its (tall) row.
final class GroupHeaderCell: NSView {
    override var isFlipped: Bool { true }
    init(text: NSAttributedString, topInset: CGFloat) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithAttributedString: text)
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            l.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}


/// Header labels inset like the original (≈18 pt in the first column, 10 pt in the others).
final class InsetHeaderCell: NSTableHeaderCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        let inset: CGFloat = rect.minX < 1 ? 17 : 6
        r.origin.x += inset; r.size.width -= inset
        return r
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
}
