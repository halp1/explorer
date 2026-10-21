import Foundation

/// Thin wrapper around the user's own `git` (Command Line Tools), as the original does.
public final class Git {
    public let root: URL
    public static var gitPath = "/usr/bin/git"

    public init(root: URL) { self.root = root }

    /// The repository root containing `url`, if any.
    public static func repositoryRoot(for url: URL) -> URL? {
        // Fast path: walk up looking for .git without spawning a process.
        let fm = FileManager.default
        return url.standardizedFileURL.selfAndAncestors.first { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    public static var isAvailable: Bool {
        // /usr/bin/git is a shim that fails without the CLT; check xcode-select.
        let r = try? run(["xcode-select", "-p"], executable: "/usr/bin/env", cwd: URL(fileURLWithPath: "/"))
        return r?.status == 0
    }

    public struct Result { public var status: Int32; public var stdout: String; public var stderr: String }

    @discardableResult
    static func run(_ args: [String], executable: String, cwd: URL, input: String? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        if let input {
            let inp = Pipe(); p.standardInput = inp
            try p.run()
            inp.fileHandleForWriting.write(input.data(using: .utf8)!)
            try? inp.fileHandleForWriting.close()
        } else {
            p.standardInput = FileHandle.nullDevice
            try p.run()
        }
        // Read before wait to avoid pipe deadlock
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    @discardableResult
    public func git(_ args: [String], input: String? = nil) throws -> Result {
        try Self.run(args, executable: Self.gitPath, cwd: root, input: input)
    }

    func check(_ r: Result) throws {
        if r.status != 0 { throw GitError.failed(r.stderr.isEmpty ? r.stdout : r.stderr) }
    }

    /// Status by path relative to the root. Folders get the most significant status of anything beneath them.
    public func status() throws -> [String: GitStatus] {
        let r = try git(["status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all"])
        try check(r)
        return Self.parsePorcelain(r.stdout)
    }

    /// Parses `git status --porcelain=v1 -z` output.
    public static func parsePorcelain(_ s: String) -> [String: GitStatus] {
        var result: [String: GitStatus] = [:]
        let parts = s.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < parts.count {
            let rec = parts[i]
            guard rec.count >= 4 else { i += 1; continue }
            let x = rec[rec.startIndex], y = rec[rec.index(after: rec.startIndex)]
            let path = String(rec.dropFirst(3))
            let st = classify(x, y)
            if x == "R" || x == "C" { i += 1 }  // next record is the original path
            if let st { add(&result, path, st) }
            i += 1
        }
        return result
    }

    static func classify(_ x: Character, _ y: Character) -> GitStatus? {
        let pair = String([x, y])
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) { return .conflicted }
        if x == "?" { return .untracked }
        if x == "!" { return .ignored }
        for c in [y, x] {
            switch c {
            case "M", "T": return .modified
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            case "A": return .added
            default: continue
            }
        }
        return nil
    }

    static func add(_ map: inout [String: GitStatus], _ path: String, _ st: GitStatus) {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        map[clean] = max(map[clean], st)
        // roll up to ancestors (ignored items don't propagate)
        guard st != .ignored else { return }
        var p = (clean as NSString).deletingLastPathComponent
        while !p.isEmpty {
            map[p] = max(map[p], st)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    static func max(_ a: GitStatus?, _ b: GitStatus) -> GitStatus {
        guard let a else { return b }
        return a.significance >= b.significance ? a : b
    }

    public func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        if p == r { return "." }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    public func stage(_ urls: [URL]) throws { try check(try git(["add", "--"] + urls.map(relative))) }
    public func unstage(_ urls: [URL]) throws { try check(try git(["restore", "--staged", "--"] + urls.map(relative))) }
    public func stageAll() throws { try check(try git(["add", "-A"])) }
    public func unstageAll() throws { try check(try git(["reset", "-q"])) }
    public func discard(_ urls: [URL]) throws {
        let rels = urls.map(relative)
        let st = try status()
        let untracked = rels.filter { st[$0] == .untracked }
        let tracked = rels.filter { st[$0] != .untracked }
        if !tracked.isEmpty { try check(try git(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + tracked)) }
        if !untracked.isEmpty { try check(try git(["clean", "-fdq", "--"] + untracked)) }
    }
    public func commit(message: String) throws -> String {
        let r = try git(["commit", "-F", "-"], input: message)
        try check(r); return r.stdout
    }
    public func pull() throws -> String { let r = try git(["pull", "--no-edit"]); try check(r); return r.stdout + r.stderr }
    public func push() throws -> String { let r = try git(["push"]); try check(r); return r.stdout + r.stderr }
    public func hasStagedChanges() -> Bool { ((try? git(["diff", "--cached", "--quiet"]))?.status ?? 0) == 1 }
    public func currentBranch() -> String? {
        guard let r = try? git(["rev-parse", "--abbrev-ref", "HEAD"]), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum GitError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let s): return "The git command failed.\n\n" + s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
