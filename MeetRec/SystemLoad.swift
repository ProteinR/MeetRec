import Darwin
import Foundation

/// CPU and memory figures for the status panel and the log, like OBS's "CPU" indicator.
struct SystemLoad: Equatable {
    /// Whole Mac, 0…100 % of all cores.
    var systemCPU: Double
    /// MeetRec itself, % of one core (as Activity Monitor shows it).
    var appCPU: Double
    /// MeetRec's memory footprint in bytes (Activity Monitor's "Memory").
    var appMemory: UInt64

    var memoryText: String { ByteCountFormatter.string(fromByteCount: Int64(appMemory), countStyle: .memory) }

    var logText: String {
        String(format: "system CPU %.0f%%, MeetRec CPU %.1f%% of one core, memory %@", systemCPU, appCPU, memoryText)
    }
}

/// Measures load between two calls; the first call only sets the baseline and returns nil.
struct LoadSampler {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastAppTime: Double?
    private var lastWall: Double?

    mutating func sample() -> SystemLoad? {
        let wall = ProcessInfo.processInfo.systemUptime
        let ticks = Self.cpuTicks()
        let appTime = Self.appCPUTime()
        defer {
            lastTicks = ticks
            lastAppTime = appTime
            lastWall = wall
        }
        guard let ticks, let lastTicks, let lastAppTime, let lastWall, wall > lastWall,
              ticks.total > lastTicks.total else { return nil }
        let system = Double(ticks.busy - lastTicks.busy) / Double(ticks.total - lastTicks.total) * 100
        let app = (appTime - lastAppTime) / (wall - lastWall) * 100
        return SystemLoad(systemCPU: system, appCPU: max(app, 0), appMemory: Self.footprint())
    }

    /// Busy and total CPU ticks of all cores since boot.
    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// CPU seconds used by all of MeetRec's threads.
    private static func appCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
