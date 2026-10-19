import Foundation
import IOKit

/// How hard a transcription works the Mac: the helper runs mostly on the GPU, which MeetRec's own
/// `Load:` line (system CPU and MeetRec itself) does not see. Every 5 s it samples the GPU, the CPU and
/// memory of the helper's whole process tree (uv → python → model workers) and the thermal state;
/// every 30 s a `Load (transcription):` line goes to the log, and a summary when the helper exits.
@MainActor
final class TranscriptionLoadMonitor {
    private let root: pid_t
    private var timer: Timer?
    private var systemSampler = LoadSampler()
    private var lastCPU: (seconds: Double, at: Double)?
    private let began = ProcessInfo.processInfo.systemUptime
    private var lastSample: Double
    private var lastLog: Double
    private var samples: [(gpu: Int?, helperCPU: Double, memory: UInt64, systemCPU: Double?)] = []
    private var thermalSeconds: [ProcessInfo.ThermalState: Double] = [:]

    init(pid: pid_t) {
        root = pid
        lastSample = began
        lastLog = began
    }

    func start() {
        _ = systemSampler.sample()
        lastCPU = (ProcessTree.usage(of: root).cpuSeconds, began)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer?.tolerance = 1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sample()
        guard !samples.isEmpty else { return }
        let minutes = (ProcessInfo.processInfo.systemUptime - began) / 60
        let gpus = samples.compactMap(\.gpu)
        let gpu = gpus.isEmpty ? "?" : "\(gpus.reduce(0, +) / gpus.count)% (peak \(gpus.max() ?? 0)%)"
        let cpu = samples.map(\.helperCPU).reduce(0, +) / Double(samples.count)
        let memory = samples.map(\.memory).max() ?? 0
        let thermal = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical]
            .compactMap { state in thermalSeconds[state].map { "\(Self.name(state)) \(Int(($0 / 60).rounded())) min" } }
            .joined(separator: ", ")
        Log.info("Load (transcription, \(String(format: "%.1f", minutes)) min): GPU \(gpu), helper CPU \(Int(cpu.rounded()))% of one core, "
                 + "helper memory peak \(Self.format(memory)), thermal: \(thermal)", "stats")
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState
        thermalSeconds[thermal, default: 0] += now - lastSample
        lastSample = now
        let usage = ProcessTree.usage(of: root)
        var helperCPU = 0.0
        if let lastCPU, now > lastCPU.at {
            helperCPU = max(usage.cpuSeconds - lastCPU.seconds, 0) / (now - lastCPU.at) * 100
        }
        lastCPU = (usage.cpuSeconds, now)
        let gpu = GPUUsage.utilization()
        let system = systemSampler.sample()?.systemCPU
        samples.append((gpu, helperCPU, usage.footprint, system))
        guard now - lastLog >= 30 else { return }
        lastLog = now
        Log.info("Load (transcription): GPU \(gpu.map { "\($0)%" } ?? "?"), helper CPU \(Int(helperCPU.rounded()))% of one core, "
                 + "helper memory \(Self.format(usage.footprint)), system CPU \(system.map { "\(Int($0.rounded()))%" } ?? "?"), "
                 + "thermal: \(Self.name(thermal))", "stats")
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// CPU time and memory of a process and all its descendants.
enum ProcessTree {
    static func usage(of root: pid_t) -> (cpuSeconds: Double, footprint: UInt64) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var cpu = 0.0
        var footprint: UInt64 = 0
        for pid in descendants(of: root) + [root] {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard result == 0 else { continue }
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            cpu += ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
            footprint += info.ri_phys_footprint
        }
        return (cpu, footprint)
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(pid)
        }
        var result: [pid_t] = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            result.append(pid)
            queue += children[pid] ?? []
        }
        return result
    }
}

/// GPU busy share from the graphics driver's statistics (what Activity Monitor's GPU history shows);
/// no administrator rights needed.
enum GPUUsage {
    static func utilization() -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let value = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }
}
