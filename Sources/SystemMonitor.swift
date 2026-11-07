import Foundation
import Darwin

/// 一次系统状态快照。所有比例均为 0.0 ~ 1.0。
struct SystemSnapshot {
    var cpu: Double
    var memory: Double
    var usedBytes: UInt64
    var totalBytes: UInt64
    var temperature: Double? = nil      // 摄氏度，nil 表示设备不支持温度读取
}

/// 通过 Mach 内核接口读取整机 CPU 与内存使用情况（不需要任何权限）。
final class SystemMonitor {
    private let temperatureMonitor = TemperatureMonitor()
    private var previousTotalTicks: UInt64 = 0
    private var previousIdleTicks: UInt64 = 0
    private var hasCPUBaseline = false

    func sample() -> SystemSnapshot {
        let memory = memoryUsage()
        return SystemSnapshot(
            cpu: cpuUsage(),
            memory: memory.ratio,
            usedBytes: memory.used,
            totalBytes: memory.total,
            temperature: temperatureMonitor.sample()
        )
    }

    // MARK: - CPU

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // cpu_ticks 顺序：CPU_STATE_USER / SYSTEM / IDLE / NICE
        let ticks = withUnsafeBytes(of: info.cpu_ticks) { raw -> [UInt64] in
            let buffer = raw.bindMemory(to: UInt32.self)
            let n = min(Int(CPU_STATE_MAX), buffer.count)
            return (0..<n).map { UInt64(buffer[$0]) }
        }
        guard ticks.count >= Int(CPU_STATE_IDLE) + 1 else { return 0 }

        let total = ticks.reduce(0, +)
        let idle = ticks[Int(CPU_STATE_IDLE)]

        defer {
            previousTotalTicks = total
            previousIdleTicks = idle
            hasCPUBaseline = true
        }

        guard hasCPUBaseline else { return 0 }
        let deltaTotal = total >= previousTotalTicks ? total - previousTotalTicks : 0
        let deltaIdle = idle >= previousIdleTicks ? idle - previousIdleTicks : 0
        guard deltaTotal > 0 else { return 0 }
        return min(1.0, max(0.0, 1.0 - Double(deltaIdle) / Double(deltaTotal)))
    }

    // MARK: - Memory

    private func memoryUsage() -> (ratio: Double, used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return (0, 0, total) }

        let pageSize = UInt64(vm_kernel_page_size)
        // 空闲 + 非活跃页视为可立即回收的可用内存；其余为已用（含联动/压缩/内核占用）。
        let availableBytes = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        let used = availableBytes < total ? total - availableBytes : 0
        return (min(1.0, max(0.0, Double(used) / Double(total))), used, total)
    }
}

// MARK: - 格式化

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 10 { return String(format: "%.0f GB", gb) }
    return String(format: "%.1f GB", gb)
}
