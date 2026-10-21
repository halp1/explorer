import AppKit
import QuickLookThumbnailing
import ExplorerKit

/// Icon & thumbnail provider with an in-memory LRU cache and an optional on-disk cache.
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: [(NSImage) -> Void]] = [:]
    private let lock = NSLock()
    private let diskQueue = DispatchQueue(label: "thumb.disk", qos: .utility)

    init() { memory.countLimit = 3000 }

    static func icon(for item: FileItem, size: CGFloat = 64) -> NSImage {
        let img: NSImage
        if item.archivePath != nil {
            if item.isDirectory { img = NSWorkspace.shared.icon(for: .folder) }
            else { img = NSWorkspace.shared.icon(for: item.utType ?? .data) }
        } else {
            img = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        img.size = NSSize(width: size, height: size)
        return img
    }

    private func key(_ url: URL, _ px: Int, _ mod: Date?) -> String { "\(url.path)|\(px)|\(mod?.timeIntervalSince1970 ?? 0)" }

    func cached(_ item: FileItem, size: CGFloat) -> NSImage? {
        memory.object(forKey: key(item.url, Int(size), item.modified) as NSString)
    }

    /// Asynchronously generates a thumbnail; completion on main queue.
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, folderStyle: FolderThumbnails, completion: @escaping (NSImage) -> Void) {
        guard item.archivePath == nil else { return }
        let k = key(item.url, Int(size), item.modified)
        if let img = memory.object(forKey: k as NSString) { completion(img); return }
        lock.lock()
        if inflight[k] != nil { inflight[k]!.append(completion); lock.unlock(); return }
        inflight[k] = [completion]
        lock.unlock()

        let finish: (NSImage?) -> Void = { [weak self] img in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lock.lock(); let cbs = self.inflight.removeValue(forKey: k) ?? []; self.lock.unlock()
                guard let img else { return }
                self.memory.setObject(img, forKey: k as NSString)
                cbs.forEach { $0(img) }
            }
        }

        if item.isFolder && !item.isPackage {
            guard folderStyle != .systemIcon else { finish(nil); return }
            DispatchQueue.global(qos: .utility).async {
                finish(FolderThumb.render(item.url, size: size, style: folderStyle))
            }
            return
        }

        if Preferences.shared.persistentThumbnailCache, let img = loadDisk(k) { finish(img); return }

        // Packages (apps, bundles) keep their system icon: QL "thumbnails" of bundles are often blank.
        if item.isPackage || item.isDirectory { finish(nil); return }  // keep NSWorkspace icon
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep, rep.type == .thumbnail || !Self.isEmpty(rep.nsImage) else { finish(nil); return }
            let img = rep.nsImage
            if Preferences.shared.persistentThumbnailCache { self?.saveDisk(k, img) }
            finish(img)
        }
    }

    /// Detects fully transparent/blank representations (seen for some bundle types).
    static func isEmpty(_ img: NSImage) -> Bool {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        return cg.width < 2 || cg.height < 2
    }

    // MARK: Disk cache (≤ 1 GB, LRU by access date)

    private var diskDir: URL {
        let u = AppPaths.caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func diskURL(_ k: String) -> URL {
        let h = k.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return diskDir.appendingPathComponent(String(h, radix: 16) + ".png")
    }

    private func loadDisk(_ k: String) -> NSImage? {
        let u = diskURL(k)
        guard let img = NSImage(contentsOf: u) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return img
    }

    private func saveDisk(_ k: String, _ img: NSImage) {
        diskQueue.async {
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: self.diskURL(k))
        }
    }

    var diskCacheSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func trimDiskCache(limit: Int64 = 1_000_000_000) {
        diskQueue.async {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            var files = ((try? FileManager.default.contentsOfDirectory(at: self.diskDir, includingPropertiesForKeys: keys)) ?? [])
                .compactMap { u -> (URL, Int64, Date)? in
                    guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
                    return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
                }
            var total = files.reduce(0) { $0 + $1.1 }
            files.sort { $0.2 < $1.2 }
            for f in files where total > limit { try? FileManager.default.removeItem(at: f.0); total -= f.1 }
        }
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
    }
}

/// Content-aware folder icons ("Content grid" / "Content fan").
enum FolderThumb {
    static func render(_ dir: URL, size: CGFloat, style: FolderThumbnails) -> NSImage? {
        let children = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(style == .contentGrid ? 4 : 3)
        guard !children.isEmpty else { return nil }
        let thumbs: [NSImage] = children.map { u in
            let sem = DispatchSemaphore(value: 0)
            var out: NSImage = NSWorkspace.shared.icon(forFile: u.path)
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: size / 2, height: size / 2), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                if let rep { out = rep.nsImage }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2)
            return out
        }
        let folder = NSWorkspace.shared.icon(for: .folder)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            folder.draw(in: r)
            let inner = r.insetBy(dx: r.width * 0.2, dy: r.height * 0.25).offsetBy(dx: 0, dy: -r.height * 0.04)
            switch style {
            case .contentGrid:
                let w = inner.width / 2, h = inner.height / 2
                for (i, t) in thumbs.enumerated() {
                    let cell = NSRect(x: inner.minX + CGFloat(i % 2) * w, y: inner.maxY - CGFloat(i / 2 + 1) * h, width: w, height: h).insetBy(dx: 2, dy: 2)
                    t.draw(in: aspectFit(t.size, cell))
                }
            case .contentFan:
                guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                for (i, t) in thumbs.enumerated().reversed() {
                    ctx.saveGState()
                    ctx.translateBy(x: inner.midX, y: inner.minY)
                    ctx.rotate(by: CGFloat(i - 1) * -0.25)
                    let cell = NSRect(x: -inner.width * 0.3, y: 0, width: inner.width * 0.6, height: inner.height * 0.9)
                    t.draw(in: aspectFit(t.size, cell))
                    ctx.restoreGState()
                }
            case .systemIcon: break
            }
            return true
        }
    }

    static func aspectFit(_ s: NSSize, _ r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}
