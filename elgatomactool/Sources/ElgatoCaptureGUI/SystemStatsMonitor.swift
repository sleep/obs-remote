import Foundation
import Darwin
import IOKit

struct SystemSample {
    let cpu: Double       // 0–N% (can exceed 100 on multi-core)
    let ramMB: Double     // process resident memory in MB
    let diskFreeGB: Double // free disk space in GB
    let gpu: Double       // 0–100% GPU utilization
}

final class SystemStatsMonitor {
    private(set) var samples: [SystemSample] = []
    private let maxSamples = 60

    private var lastCPUTime: Double = 0
    private var lastWallTime: Double = 0

    var latestCPU: Double { samples.last?.cpu ?? 0 }
    var latestRAM: Double { samples.last?.ramMB ?? 0 }
    var latestDisk: Double { samples.last?.diskFreeGB ?? 0 }
    var latestGPU: Double { samples.last?.gpu ?? 0 }

    var cpuHistory: [Double] { samples.map(\.cpu) }
    var ramHistory: [Double] { samples.map(\.ramMB) }
    var diskHistory: [Double] { samples.map(\.diskFreeGB) }
    var gpuHistory: [Double] { samples.map(\.gpu) }

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
        let gpu = Self.gpuUtilization()

        let s = SystemSample(cpu: cpuPercent, ramMB: ram, diskFreeGB: disk, gpu: gpu)
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

    private static func gpuUtilization() -> Double {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var entry: io_registry_entry_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                entry = IOIteratorNext(iterator)
                continue
            }

            // Look for PerformanceStatistics or similar GPU stats dictionary
            if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                // Try common keys for GPU utilization
                if let util = perfStats["GPU Activity(%)"] as? Double {
                    return util
                }
                if let util = perfStats["Device Utilization %"] as? Int {
                    return Double(util)
                }
                // Apple Silicon: look for in-use ratio
                if let inUse = perfStats["hardwareWaitTime"] as? Int64,
                   let total = perfStats["totalWaitTime"] as? Int64, total > 0 {
                    return Double(inUse) / Double(total) * 100
                }
            }

            entry = IOIteratorNext(iterator)
        }
        return 0
    }
}
