import Foundation
import Darwin

struct SystemSample {
    let cpu: Double       // 0–N% (can exceed 100 on multi-core)
    let ramMB: Double     // process resident memory in MB
    let diskFreeGB: Double // free disk space in GB
}

final class SystemStatsMonitor {
    private(set) var samples: [SystemSample] = []
    private let maxSamples = 60

    private var lastCPUTime: Double = 0
    private var lastWallTime: Double = 0

    var latestCPU: Double { samples.last?.cpu ?? 0 }
    var latestRAM: Double { samples.last?.ramMB ?? 0 }
    var latestDisk: Double { samples.last?.diskFreeGB ?? 0 }

    var cpuHistory: [Double] { samples.map(\.cpu) }
    var ramHistory: [Double] { samples.map(\.ramMB) }
    var diskHistory: [Double] { samples.map(\.diskFreeGB) }

    init() {
        // Prime the CPU baseline so the first real sample has a delta
        lastCPUTime = Self.cpuTime()
        lastWallTime = ProcessInfo.processInfo.systemUptime
    }

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuNow = Self.cpuTime()

        let wallDelta = now - lastWallTime
        let cpuDelta = cpuNow - lastCPUTime
        let cpuPercent = wallDelta > 0 ? (cpuDelta / wallDelta) * 100 : 0

        lastCPUTime = cpuNow
        lastWallTime = now

        let ram = Self.residentMemoryMB()
        let disk = Self.diskFreeGB()

        let s = SystemSample(cpu: cpuPercent, ramMB: ram, diskFreeGB: disk)
        samples.append(s)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    // MARK: - System queries

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys  = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    private static func diskFreeGB() -> Double {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let free = attrs[.systemFreeSize] as? Int64 else { return 0 }
        return Double(free) / 1_073_741_824
    }
}
