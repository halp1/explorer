import Foundation
import Darwin

/// Development safety net. With `EXPLORER_MEMORY_LIMIT_MB=<n>` a background thread aborts the process
/// once its physical footprint exceeds the limit, so the crash report captures every thread's stack.
/// `EXPLORER_TIME_LIMIT_S=<n>` exits after n seconds. Inert unless the variables are set.
enum MemoryGuard {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let limit = env["EXPLORER_MEMORY_LIMIT_MB"].flatMap(Int.init)
        let timeLimit = env["EXPLORER_TIME_LIMIT_S"].flatMap(Double.init)
        let logPath = env["EXPLORER_MEMORY_LOG"]
        guard limit != nil || timeLimit != nil else { return }
        let start = Date()
        let t = Thread {
            var lastLog = Date.distantPast
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                let mb = footprintMB()
                if let logPath, Date().timeIntervalSince(lastLog) > 0.5 {
                    lastLog = Date()
                    let line = String(format: "t=%.1fs footprint=%dMB\n", Date().timeIntervalSince(start), mb)
                    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath)) }
                }
                if let limit, mb > limit {
                    FileHandle.standardError.write(Data("MemoryGuard: footprint \(mb)MB > \(limit)MB, aborting\n".utf8))
                    abort()
                }
                if let timeLimit, Date().timeIntervalSince(start) > timeLimit { exit(0) }
            }
        }
        t.name = "MemoryGuard"
        t.qualityOfService = .userInteractive
        t.start()
    }
}
