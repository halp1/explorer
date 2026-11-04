import AppKit
import ExplorerKit

/// Development aid: `EXPLORER_SNAPSHOT=/path/out.png` (env) renders the key window's content view into a PNG
/// a few seconds after launch, and `EXPLORER_SNAPSHOT_SCRIPT` can drive simple steps
/// (e.g. "view:table;go:/Applications;select:0"). Inert unless the env var is set.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["EXPLORER_SNAPSHOT"] else { return }
        let steps = (env["EXPLORER_SNAPSHOT_SCRIPT"] ?? "").split(separator: ";").map(String.init)
        var delay = 2.0
        for s in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(s) }
            delay += 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) {
            // "/dev/null" = drive the script only (external screencapture); cacheDisplay can drop system materials.
            if out != "/dev/null" { snapshot(to: out) }
            if env["EXPLORER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }

    static func run(_ step: String) {
        guard let c = AppDelegate.shared.activeController else { return }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "view": if let k = ViewKind(rawValue: arg.capitalized) { c.state.options.view = k }
        case "go": c.state.go(.directory(URL(fileURLWithPath: arg, isDirectory: true)))
        case "archive": c.state.go(.archive(URL(fileURLWithPath: arg), inner: ""))
        case "select": if let i = Int(arg), c.state.items.indices.contains(i) { c.state.selection = [c.state.items[i]] }
        case "selectext": if let it = c.state.items.first(where: { $0.fileExtension.lowercased() == arg.lowercased() }) { c.state.selection = [it] }
        case "info": c.state.options.showInfo = arg == "1"
        case "group": if let g = GroupKey(rawValue: arg) { c.state.options.grouping = g }
        case "settings": AppDelegate.shared.showSettingsTab(SettingsTab(rawValue: arg) ?? .general)
        case "shelf": c.shelf.open()
        case "search": c.state.search(arg)
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let w = c.window { var f = w.frame; f.size = NSSize(width: wh[0], height: wh[1]); w.setFrame(f, display: true) }
        case "dumprows":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let t = c.window?.contentView?.descendants(of: NSTableView.self).first else { return }
                var out = ""
                for r in 0..<min(t.numberOfRows, 14) { let f = t.rect(ofRow: r); out += "row \(r) y=\(f.minY) h=\(f.height)\n" }
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "dumptree":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let o = c.tree.outline
                var out = "insets=\(o.enclosingScrollView?.contentInsets as Any) clip=\(o.enclosingScrollView?.contentView.bounds as Any) style=\(o.selectionHighlightStyle.rawValue)\n"
                out += "outline=\(o.frame) col=\(o.tableColumns.first?.width ?? 0) colRect=\(o.rect(ofColumn: 0)) spacing=\(o.intercellSpacing) scroll=\(o.enclosingScrollView?.frame as Any) scroller=\(o.enclosingScrollView?.verticalScroller?.frame as Any) style=\(o.enclosingScrollView?.scrollerStyle.rawValue ?? -1)\n"
                for r in 0..<min(o.numberOfRows, 40) {
                    let f = o.rect(ofRow: r)
                    let n = o.item(atRow: r) as? TreeNode
                    var extra = ""
                    if let rv = o.rowView(atRow: r, makeIfNecessary: false) {
                        extra = " rv=\(rv.frame) sub=\(rv.subviews.map { String(describing: type(of: $0)) + "\($0.frame)" })"
                    }
                    out += "row \(r) y=\(f.minY) h=\(f.height) \(n?.title ?? "?")\(extra)\n"
                }
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "origin":
            let xy = arg.split(separator: "x").compactMap { Double($0) }
            if xy.count == 2, let w = c.window, let scr = w.screen ?? NSScreen.main {
                // top-left in screen coordinates (like CGWindow bounds)
                w.setFrameTopLeftPoint(NSPoint(x: xy[0], y: scr.frame.maxY - xy[1]))
            }
        case "sort": if let k = SortKey(rawValue: arg) { c.state.options.sortKey = k }
        case "hidden": c.state.options.showHidden = arg == "1"
        default: break
        }
    }

    static func snapshot(to path: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        for (i, w) in windows.enumerated() {
            guard let v = w.contentView?.superview ?? w.contentView else { continue }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let p = windows.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
        }
    }
}


extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        var out: [T] = []
        for v in subviews { if let t = v as? T { out.append(t) }; out += v.descendants(of: type) }
        return out
    }
}
