import Foundation

/// A user-defined Action (Settings › Scripting).
public struct ScriptAction: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case shell = "Shell", appleScript = "AppleScript" }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var command: String
    public var perFile: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, command: String, perFile: Bool, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.command = command; self.perFile = perFile; self.enabled = enabled
    }

    /// An action that only references {dir} needs no selection.
    public var needsSelection: Bool {
        ["{path}", "{name}", "{stem}"].contains { command.contains($0) }
    }

    public static let samples: [ScriptAction] = [
        ScriptAction(name: "Convert image to JPEG", kind: .shell,
                     command: "sips -s format jpeg {path} --out {dir}/{stem}.jpg", perFile: true),
        ScriptAction(name: "Convert image to PNG", kind: .shell,
                     command: "sips -s format png {path} --out {dir}/{stem}.png", perFile: true),
        ScriptAction(name: "Trash All Duplicates", kind: .appleScript, command: """
            -- Keeps the shortest-named copy of each set of identical files in the current folder.
            set theFolder to {dir}
            set listing to do shell script "cd " & quoted form of theFolder & " && for f in *; do [ -f \\"$f\\" ] && printf '%s\\\\t%s\\\\t%s\\\\n' \\"$(shasum -a 256 \\"$f\\" | cut -d' ' -f1)\\" \\"${#f}\\" \\"$f\\"; done | sort -t$'\\\\t' -k1,1 -k2,2n | awk -F'\\\\t' 'seen[$1]++ {print $3}'"
            set victims to {}
            repeat with n in paragraphs of listing
                if (n as text) is not "" then set end of victims to (POSIX file (theFolder & "/" & n)) as alias
            end repeat
            if victims is not {} then tell application "Finder" to delete victims
            """, perFile: false),
    ]
}

public enum ActionRunner {
    /// Shell-quotes a value for /bin/zsh.
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// AppleScript string literal.
    public static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Substitutes {path} {name} {stem} {dir}. For batch runs, multi-valued tokens expand to space-separated
    /// shell words (or an AppleScript list).
    public static func substitute(_ template: String, kind: ScriptAction.Kind, items: [URL], dir: URL) -> String {
        let q: (String) -> String = kind == .shell ? shellQuote : appleScriptQuote
        func multi(_ values: [String]) -> String {
            if values.count == 1 { return q(values[0]) }
            return kind == .shell ? values.map(q).joined(separator: " ") : "{" + values.map(q).joined(separator: ", ") + "}"
        }
        var s = template
        s = s.replacingOccurrences(of: "{path}", with: multi(items.map(\.path)))
        s = s.replacingOccurrences(of: "{name}", with: multi(items.map(\.lastPathComponent)))
        s = s.replacingOccurrences(of: "{stem}", with: multi(items.map { $0.deletingPathExtension().lastPathComponent }))
        s = s.replacingOccurrences(of: "{dir}", with: q(dir.path))
        return s
    }

    /// The concrete scripts to run for a selection.
    public static func scripts(for action: ScriptAction, items: [URL], dir: URL) -> [String] {
        if action.perFile && !items.isEmpty {
            return items.map { substitute(action.command, kind: action.kind, items: [$0], dir: dir) }
        }
        return [substitute(action.command, kind: action.kind, items: items, dir: dir)]
    }

    public struct Output { public var status: Int32; public var log: String }

    /// Runs a shell script with /bin/zsh in `dir`.
    public static func runShell(_ script: String, in dir: URL) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Output(status: -1, log: error.localizedDescription) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, log: String(decoding: d, as: UTF8.self))
    }

    /// Runs AppleScript out of process (keeps the app responsive and avoids NSAppleScript thread rules).
    public static func runAppleScript(_ script: String) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return Output(status: -1, log: error.localizedDescription) }
        inp.fileHandleForWriting.write(script.data(using: .utf8)!)
        try? inp.fileHandleForWriting.close()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, log: String(decoding: d, as: UTF8.self))
    }
}

// MARK: - URL scheme handling (CLI + Services)

public enum AppURLScheme {
    public static let open = "explorer"
    public static let reveal = "explorerreveal"

    public enum Request: Equatable {
        case newWindow
        case open(URL)
        case reveal(URL)
    }

    /// Parses explorer:///%23 (new window), explorer://<dir>/ (open), explorerreveal://<path> (reveal).
    public static func parse(_ url: URL) -> Request? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // Hostless form "explorer:///path" or host-as-first-component "explorer://Users/..."
        var raw = url.absoluteString
        guard let r = raw.range(of: "://") else { return nil }
        raw = String(raw[r.upperBound...])
        let decoded = raw.removingPercentEncoding ?? raw
        if decoded == "/#" || decoded == "#" { return scheme == open ? .newWindow : nil }
        let path = decoded.hasPrefix("/") ? decoded : "/" + decoded
        let fileURL = URL(fileURLWithPath: path, isDirectory: path.hasSuffix("/"))
        switch scheme {
        case open:
            if path.hasSuffix("/") { return .open(fileURL) }
            return .reveal(fileURL)
        case reveal: return .reveal(fileURL)
        default: return nil
        }
    }

    public static func encode(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".~_/-")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
