import Foundation
import CoreServices

/// FSEvents-based watcher for one or more directories. Coalesces events and calls back on the main queue.
public final class FolderMonitor {
    public typealias Handler = (_ changedPaths: [String]) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let paths: [String]
    private let latency: CFTimeInterval
    public private(set) var failure: String?

    public init(paths: [String], latency: CFTimeInterval = 0.25, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        stop()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(arr.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            failure = "FSEventStreamCreate failed"
            return false
        }
        FSEventStreamSetDispatchQueue(s, .main)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            failure = "FSEventStreamStart failed"
            return false
        }
        stream = s
        failure = nil
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
