import Foundation

/// Which part of a file name a rename step applies to.
public enum RenameTarget: String, Codable, CaseIterable, Sendable {
    case name = "File name", fileExtension = "File extension", both = "File name with extension"
}

public enum CaseStyle: String, Codable, CaseIterable, Sendable {
    case upper = "UPPERCASE", lower = "lowercase", title = "Title Case", sentence = "Sentence case"
}

public enum InsertPosition: String, Codable, CaseIterable, Sendable {
    case beginning = "At the beginning", end = "At the end", custom = "Custom position"
}

public enum DateSource: String, Codable, CaseIterable, Sendable {
    case created = "Creation date", modified = "Modification date", added = "Date Added", opened = "Date Last Opened", now = "Now", metadata = "Recording date"
}

public enum NumberOrder: String, Codable, CaseIterable, Sendable {
    case current = "Current order", name = "Name", created = "Creation date", modified = "Modification date", size = "File size"
}

/// One step of the rename pipeline.
public enum RenameStep: Codable, Hashable, Sendable {
    case replaceText(find: String, replace: String, caseSensitive: Bool, target: RenameTarget)
    case replaceRegex(pattern: String, template: String, caseSensitive: Bool, target: RenameTarget)
    case changeCase(CaseStyle, target: RenameTarget)
    case addText(String, position: InsertPosition, offset: Int, fromEnd: Bool, target: RenameTarget)
    case addDate(source: DateSource, format: String, position: InsertPosition, offset: Int, fromEnd: Bool, delimiter: String, target: RenameTarget)
    case addNumber(start: Int, step: Int, padding: Int, order: NumberOrder, descending: Bool, position: InsertPosition, offset: Int, fromEnd: Bool, delimiter: String, target: RenameTarget)
    case addMetadata(key: String, position: InsertPosition, offset: Int, fromEnd: Bool, delimiter: String, target: RenameTarget)

    public var title: String {
        switch self {
        case .replaceText: return "Replace text"
        case .replaceRegex: return "Replace RegEx"
        case .changeCase: return "Change case"
        case .addText: return "Add text"
        case .addDate: return "Add date"
        case .addNumber: return "Add number sequence"
        case .addMetadata: return "Add metadata value"
        }
    }

    public var target: RenameTarget {
        switch self {
        case .replaceText(_, _, _, let t), .replaceRegex(_, _, _, let t), .changeCase(_, let t), .addText(_, _, _, _, let t),
             .addDate(_, _, _, _, _, _, let t), .addNumber(_, _, _, _, _, _, _, _, _, let t), .addMetadata(_, _, _, _, _, let t):
            return t
        }
    }
}

/// Input to the rename engine: an item plus the values steps might need.
public struct RenameInput: Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var created: Date?
    public var modified: Date?
    public var added: Date?
    public var opened: Date?
    public var size: Int64
    public var metadata: [String: String]
    public init(url: URL, isDirectory: Bool = false, created: Date? = nil, modified: Date? = nil, added: Date? = nil,
                opened: Date? = nil, size: Int64 = 0, metadata: [String: String] = [:]) {
        self.url = url; self.isDirectory = isDirectory; self.created = created; self.modified = modified
        self.added = added; self.opened = opened; self.size = size; self.metadata = metadata
    }

    public static func load(_ url: URL, metadataKeys: [String] = []) -> RenameInput {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey, .fileSizeKey])
        var md: [String: String] = [:]
        if !metadataKeys.isEmpty { md = MetadataValues.values(for: url, keys: metadataKeys) }
        return RenameInput(url: url, isDirectory: v?.isDirectory ?? false, created: v?.creationDate, modified: v?.contentModificationDate,
                           added: v?.addedToDirectoryDate, opened: v?.contentAccessDate, size: Int64(v?.fileSize ?? 0), metadata: md)
    }
}

public struct RenameResult: Hashable, Sendable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var newName: String
    public var error: String?
    public var changed: Bool { url.lastPathComponent != newName }
}

public enum BatchRenamer {
    /// Computes new names. Errors (invalid regex, empty name, collisions) are reported per item.
    public static func preview(_ inputs: [RenameInput], steps: [RenameStep], calendar: Calendar = .current, now: Date = Date()) -> [RenameResult] {
        var names = inputs.map { $0.url.lastPathComponent }
        for step in steps {
            let ordering = numberingOrder(inputs, step: step)
            for (idx, input) in inputs.enumerated() {
                let seq = ordering[idx]
                names[idx] = apply(step, to: names[idx], input: input, sequenceIndex: seq, calendar: calendar, now: now)
            }
        }
        var results = zip(inputs, names).map { RenameResult(url: $0.url, newName: $1, error: FileNaming.validate($1)) }
        // Collision detection: among new names in the same directory, and against untouched existing files.
        var seen: [String: Int] = [:]
        let sourcePaths = Set(inputs.map { $0.url.standardizedFileURL.path })
        for i in results.indices where results[i].error == nil {
            let dir = results[i].url.deletingLastPathComponent()
            let key = dir.appendingPathComponent(results[i].newName).standardizedFileURL.path.lowercased()
            if let j = seen[key] {
                results[i].error = "Another renamed item has this name; one of them will be renamed."
                results[j].error = results[j].error ?? "Another renamed item has this name; one of them will be renamed."
            } else {
                seen[key] = i
                let target = dir.appendingPathComponent(results[i].newName)
                if results[i].changed, !sourcePaths.contains(target.standardizedFileURL.path),
                   results[i].newName.lowercased() != results[i].url.lastPathComponent.lowercased(),
                   FileNaming.defaultExists(target) {
                    results[i].error = "An item with this name already exists; it will be renamed."
                }
            }
        }
        return results
    }

    /// Maps each input index to its 0-based position in the numbering order for `step`.
    static func numberingOrder(_ inputs: [RenameInput], step: RenameStep) -> [Int] {
        guard case let .addNumber(_, _, _, order, desc, _, _, _, _, _) = step else { return Array(inputs.indices) }
        var idx = Array(inputs.indices)
        switch order {
        case .current: break
        case .name: idx.sort { inputs[$0].url.lastPathComponent.localizedStandardCompare(inputs[$1].url.lastPathComponent) == .orderedAscending }
        case .created: idx.sort { (inputs[$0].created ?? .distantPast) < (inputs[$1].created ?? .distantPast) }
        case .modified: idx.sort { (inputs[$0].modified ?? .distantPast) < (inputs[$1].modified ?? .distantPast) }
        case .size: idx.sort { inputs[$0].size < inputs[$1].size }
        }
        if desc { idx.reverse() }
        var pos = [Int](repeating: 0, count: inputs.count)
        for (p, i) in idx.enumerated() { pos[i] = p }
        return pos
    }

    /// Splits "name.ext" respecting directories (no extension split for folders).
    static func split(_ full: String, isDirectory: Bool) -> (String, String) {
        if isDirectory { return (full, "") }
        let ext = (full as NSString).pathExtension
        if ext.isEmpty || full.hasPrefix(".") && full.dropFirst().contains(".") == false { return (full, "") }
        return (String(full.dropLast(ext.count + 1)), ext)
    }

    static func join(_ stem: String, _ ext: String) -> String { ext.isEmpty ? stem : stem + "." + ext }

    static func transform(_ full: String, isDirectory: Bool, target: RenameTarget, _ f: (String) -> String) -> String {
        switch target {
        case .both: return f(full)
        case .name:
            let (s, e) = split(full, isDirectory: isDirectory)
            return join(f(s), e)
        case .fileExtension:
            let (s, e) = split(full, isDirectory: isDirectory)
            if isDirectory { return full }
            return join(s, f(e))
        }
    }

    static func insert(_ text: String, into s: String, position: InsertPosition, offset: Int, fromEnd: Bool) -> String {
        switch position {
        case .beginning: return text + s
        case .end: return s + text
        case .custom:
            let n = s.count
            var o = max(0, min(n, offset))
            if fromEnd { o = n - o }
            let i = s.index(s.startIndex, offsetBy: o)
            return String(s[..<i]) + text + String(s[i...])
        }
    }

    static func withDelimiter(_ value: String, _ delim: String, position: InsertPosition) -> String {
        guard !delim.isEmpty, !value.isEmpty else { return value }
        switch position {
        case .beginning: return value + delim
        case .end: return delim + value
        case .custom: return value
        }
    }

    public static func apply(_ step: RenameStep, to name: String, input: RenameInput, sequenceIndex: Int, calendar: Calendar = .current, now: Date = Date()) -> String {
        let dir = input.isDirectory
        switch step {
        case let .replaceText(find, rep, cs, t):
            guard !find.isEmpty else { return name }
            return transform(name, isDirectory: dir, target: t) {
                $0.replacingOccurrences(of: find, with: rep, options: cs ? [] : [.caseInsensitive])
            }
        case let .replaceRegex(pattern, template, cs, t):
            guard !pattern.isEmpty, let re = try? NSRegularExpression(pattern: pattern, options: cs ? [] : [.caseInsensitive]) else { return name }
            return transform(name, isDirectory: dir, target: t) {
                re.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: template)
            }
        case let .changeCase(style, t):
            return transform(name, isDirectory: dir, target: t) { s in
                switch style {
                case .upper: return s.uppercased()
                case .lower: return s.lowercased()
                case .title: return s.capitalized
                case .sentence:
                    let l = s.lowercased()
                    guard let f = l.firstIndex(where: { $0.isLetter }) else { return l }
                    return String(l[..<f]) + l[f...].prefix(1).uppercased() + String(l[l.index(after: f)...])
                }
            }
        case let .addText(text, pos, off, fromEnd, t):
            return transform(name, isDirectory: dir, target: t) { insert(text, into: $0, position: pos, offset: off, fromEnd: fromEnd) }
        case let .addDate(source, fmt, pos, off, fromEnd, delim, t):
            let date: Date?
            switch source {
            case .created: date = input.created
            case .modified: date = input.modified
            case .added: date = input.added
            case .opened: date = input.opened
            case .now: date = now
            case .metadata: date = input.metadata["kMDItemContentCreationDate"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? input.created
            }
            guard let date else { return name }
            let f = DateFormatter()
            f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt.isEmpty ? "yyyy-MM-dd" : fmt
            let value = withDelimiter(f.string(from: date), delim, position: pos)
            return transform(name, isDirectory: dir, target: t) { insert(value, into: $0, position: pos, offset: off, fromEnd: fromEnd) }
        case let .addNumber(start, stepBy, pad, _, _, pos, off, fromEnd, delim, t):
            let n = start + sequenceIndex * stepBy
            var s = String(abs(n))
            if s.count < pad { s = String(repeating: "0", count: pad - s.count) + s }
            if n < 0 { s = "-" + s }
            let value = withDelimiter(s, delim, position: pos)
            return transform(name, isDirectory: dir, target: t) { insert(value, into: $0, position: pos, offset: off, fromEnd: fromEnd) }
        case let .addMetadata(key, pos, off, fromEnd, delim, t):
            guard let raw = input.metadata[key], !raw.isEmpty else { return name }
            let clean = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let value = withDelimiter(clean, delim, position: pos)
            return transform(name, isDirectory: dir, target: t) { insert(value, into: $0, position: pos, offset: off, fromEnd: fromEnd) }
        }
    }

    /// Performs renames safely (two-phase via temporary names to allow swaps). Returns the undo record.
    public static func commit(_ results: [RenameResult]) throws -> UndoAction {
        let fm = FileManager.default
        let todo = results.filter { $0.changed && FileNaming.validate($0.newName) == nil }
        var temps: [(URL, URL, String)] = []  // original, temp, desired name
        var done: [MovePair] = []
        do {
            for r in todo {
                let tmp = r.url.deletingLastPathComponent().appendingPathComponent(".explorer-rename-\(UUID().uuidString)")
                try fm.moveItem(at: r.url, to: tmp)
                temps.append((r.url, tmp, r.newName))
            }
            for (orig, tmp, name) in temps {
                let dir = orig.deletingLastPathComponent()
                var dest = dir.appendingPathComponent(name)
                // Case-only rename of same item is fine; otherwise avoid clobbering.
                if FileNaming.defaultExists(dest) {
                    dest = FileNaming.uniqueURL(in: dir, name: name, isDirectory: tmp.hasDirectoryPath)
                }
                try fm.moveItem(at: tmp, to: dest)
                done.append(MovePair(from: orig, to: dest))
            }
        } catch {
            // Roll back temps that were not finalized
            for (orig, tmp, _) in temps where FileNaming.defaultExists(tmp) { try? fm.moveItem(at: tmp, to: orig) }
            for p in done.reversed() { try? fm.moveItem(at: p.to, to: p.from) }
            throw error
        }
        return .moved(done)
    }
}

/// Spotlight / ImageIO metadata values for "Add metadata value" and the Info panel.
public enum MetadataValues {
    /// Common keys offered in the rename UI, with titles.
    public static let renameKeys: [(key: String, title: String)] = [
        ("kMDItemPixelWidth", "Pixel width"), ("kMDItemPixelHeight", "Pixel height"),
        ("kMDItemAcquisitionMake", "Device make"), ("kMDItemAcquisitionModel", "Device model"),
        ("kMDItemContentCreationDate", "Recording date"), ("kMDItemISOSpeed", "ISO speed"),
        ("kMDItemFNumber", "F number"), ("kMDItemExposureTimeSeconds", "Exposure time"),
        ("kMDItemFocalLength", "Focal length (mm)"), ("kMDItemLatitude", "GPS latitude"), ("kMDItemLongitude", "GPS longitude"),
        ("kMDItemAuthors", "Authors"), ("kMDItemTitle", "Title"), ("kMDItemAlbum", "Album"),
        ("kMDItemComposer", "Composer"), ("kMDItemMusicalGenre", "Musical genre"),
        ("kMDItemAudioTrackNumber", "Audio track number"), ("kMDItemRecordingYear", "Recording year"),
        ("kMDItemDurationSeconds", "Duration (seconds)"), ("kMDItemNumberOfPages", "Number of pages"),
        ("kMDItemVersion", "Version"), ("kMDItemCopyright", "Copyright"),
    ]

    public static func values(for url: URL, keys: [String]) -> [String: String] {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return [:] }
        var out: [String: String] = [:]
        for k in keys {
            guard let v = MDItemCopyAttribute(item, k as CFString) else { continue }
            out[k] = stringify(v)
        }
        return out
    }

    static func stringify(_ v: CFTypeRef) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
        }
        if let d = v as? Date { return ISO8601DateFormatter().string(from: d) }
        if let a = v as? [Any] { return a.map { stringify($0 as CFTypeRef) }.joined(separator: ", ") }
        return "\(v)"
    }
}
