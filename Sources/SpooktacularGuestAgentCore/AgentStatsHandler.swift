import Foundation
import Darwin
import SpooktacularCore

// MARK: - VM metrics handler
//
// Implements GET /api/v1/stats routed from AgentRouter. Kept
// separate from the router because the handler pulls in Darwin
// for host_statistics64 / host_processor_info / sysctl.

final class CPUTickSampler: @unchecked Sendable {
    struct Sample {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
        var total: UInt64 { user + system + idle + nice }
    }

    private let queue = DispatchQueue(label: "com.spooktacular.agent.stats")
    private var previous: Sample?

    func usage(current: Sample) -> Double? {
        queue.sync {
            defer { previous = current }
            guard let prev = previous else { return nil }
            let totalDelta = current.total &- prev.total
            guard totalDelta > 0 else { return 0 }
            let idleDelta = current.idle &- prev.idle
            let busyDelta = totalDelta &- idleDelta
            return min(1.0, max(0, Double(busyDelta) / Double(totalDelta)))
        }
    }
}

let cpuTickSampler = CPUTickSampler()

func handleStats() -> Data {
    let response = GuestStatsResponse(
        cpuUsage: sampleCPUUsage(),
        memoryUsedBytes: sampleMemoryUsed(),
        memoryTotalBytes: sampleMemoryTotal(),
        loadAverage1m: sampleLoadAverage(),
        processCount: sampleProcessCount(),
        uptime: sampleUptime()
    )
    return (try? JSONEncoder().encode(response)) ?? Data()
}

func sampleCPUUsage() -> Double? {
    var cpuCount: natural_t = 0
    var infoArray: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &cpuCount,
        &infoArray,
        &infoCount
    )
    guard result == KERN_SUCCESS, let info = infoArray else { return nil }
    defer {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: info),
            vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
    }
    var total = CPUTickSampler.Sample(user: 0, system: 0, idle: 0, nice: 0)
    for cpu in 0..<Int(cpuCount) {
        let base = cpu * Int(CPU_STATE_MAX)
        total = CPUTickSampler.Sample(
            user: total.user + UInt64(info[base + Int(CPU_STATE_USER)]),
            system: total.system + UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
            idle: total.idle + UInt64(info[base + Int(CPU_STATE_IDLE)]),
            nice: total.nice + UInt64(info[base + Int(CPU_STATE_NICE)])
        )
    }
    return cpuTickSampler.usage(current: total)
}

func sampleMemoryUsed() -> UInt64 {
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size /
        MemoryLayout<integer_t>.size
    )
    var stats = vm_statistics64_data_t()
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pageSize = pageSize()
    let activeBytes = UInt64(stats.active_count) * pageSize
    let wiredBytes = UInt64(stats.wire_count) * pageSize
    let compressedBytes = UInt64(stats.compressor_page_count) * pageSize
    return activeBytes + wiredBytes + compressedBytes
}

func sampleMemoryTotal() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}

func sampleLoadAverage() -> Double {
    var load = [Double](repeating: 0, count: 3)
    guard getloadavg(&load, 3) == 3 else { return 0 }
    return load[0]
}

func sampleProcessCount() -> Int {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
          size > 0 else {
        return 0
    }
    return size / MemoryLayout<kinfo_proc>.stride
}

func sampleUptime() -> TimeInterval {
    var boottime = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, u_int(mib.count), &boottime, &size, nil, 0) == 0 else {
        return 0
    }
    return Date().timeIntervalSince1970 - TimeInterval(boottime.tv_sec)
}

/// Page size via sysctl — safer under Swift 6 strict concurrency
/// than the Darwin global `vm_kernel_page_size` which the
/// compiler flags as shared mutable state.
func pageSize() -> UInt64 {
    var size: Int = 0
    var len = MemoryLayout<Int>.size
    sysctlbyname("hw.pagesize", &size, &len, nil, 0)
    return UInt64(size > 0 ? size : 16384)
}
