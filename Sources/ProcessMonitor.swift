import AppKit
import Darwin

/// 点击悬浮窗数值时打开的排序依据。
enum ProcessMetric: String {
    case cpu
    case memory
}

/// 单个进程的一次采样结果。
struct ProcessEntry {
    let pid: Int32
    let name: String
    let executablePath: String
    /// 可执行文件所属的 .app（可能比 bundleURL 更靠外，便于在 Finder 里定位软件本体）
    let bundlePath: String?
    /// 占整机 CPU 的百分比，已按逻辑核数归一化（与悬浮窗的整机 CPU% 口径一致）
    let cpuPercent: Double
    let memoryBytes: UInt64
    let memoryPercent: Double
}

/// 只解析一次的静态信息（进程名、路径、bundle）。
private struct ProcessMeta {
    let name: String
    let executablePath: String
    let bundlePath: String?
}

/// 进程占用采样器。
///
/// CPU 用两次 `proc_taskinfo` 的累计 CPU tick 差值除以两次 `mach_absolute_time()`
/// 的墙钟 tick 差值，再按逻辑核数归一化。分子分母同为 Mach 绝对时间单位，
/// 因此不需要 mach_timebase_info 换算，Apple Silicon 与 Intel 都成立。
final class ProcessMonitor {
    private let totalMemory: Double
    private let coreCount: Double
    private var previousTicks: [Int32: UInt64] = [:]
    private var previousWall: UInt64 = mach_absolute_time()
    private var metadata: [Int32: ProcessMeta] = [:]
    private var pidBuffer = [Int32](repeating: 0, count: 8192)

    init() {
        totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        coreCount = Double(max(1, ProcessInfo.processInfo.processorCount))
    }

    var cores: Int { Int(coreCount) }

    /// 列表窗口重新打开时清掉旧基线，避免把关闭期间的 CPU 时间算进第一帧。
    func reset() {
        previousTicks.removeAll()
        previousWall = mach_absolute_time()
    }

    func sample() -> [ProcessEntry] {
        let count = proc_listallpids(&pidBuffer,
                                     Int32(MemoryLayout<Int32>.size * pidBuffer.count))
        guard count > 0 else { return [] }

        let now = mach_absolute_time()
        let wallTicks = Double(max(1, now &- previousWall))
        var currentTicks: [Int32: UInt64] = [:]
        currentTicks.reserveCapacity(Int(count))
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let pid = pidBuffer[index]
            var info = proc_taskinfo()
            let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                    Int32(MemoryLayout<proc_taskinfo>.size))
            guard read > 0 else { continue }

            let ticks = info.pti_total_user &+ info.pti_total_system
            currentTicks[pid] = ticks

            // 首次见到的进程没有基线，这一帧记 0，下一帧起即为真实瞬时占用
            let delta = previousTicks[pid].map { ticks &- $0 } ?? 0
            let cpu = min(100.0, Double(delta) / wallTicks / coreCount * 100.0)

            let meta: ProcessMeta
            if let cached = metadata[pid] {
                meta = cached
            } else {
                meta = ProcessMonitor.readMeta(pid: pid)
                metadata[pid] = meta
            }

            let rss = info.pti_resident_size
            entries.append(ProcessEntry(
                pid: pid,
                name: meta.name,
                executablePath: meta.executablePath,
                bundlePath: meta.bundlePath,
                cpuPercent: cpu,
                memoryBytes: rss,
                memoryPercent: totalMemory > 0
                    ? min(100.0, Double(rss) / totalMemory * 100.0) : 0
            ))
        }

        previousTicks = currentTicks
        previousWall = now
        if metadata.count > currentTicks.count {
            metadata = metadata.filter { currentTicks[$0.key] != nil }
        }
        return entries
    }

    private static func readMeta(pid: Int32) -> ProcessMeta {
        var nameBuffer = [CChar](repeating: 0, count: 128)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let shortName = String(cString: nameBuffer)

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? String(cString: pathBuffer) : ""

        let app = NSRunningApplication(processIdentifier: pid)
        // 优先取路径里最外层的 .app，像 Chrome Helper 这类子进程也能定位到主程序
        var bundle: String? = nil
        if let range = path.range(of: ".app/") {
            if let end = path.index(range.lowerBound, offsetBy: 4, limitedBy: path.endIndex) {
                bundle = String(path[..<end])
            }
        } else if let url = app?.bundleURL?.path {
            bundle = url
        }

        let displayName = app?.localizedName
            ?? (path.isEmpty ? shortName : (path as NSString).lastPathComponent)
        return ProcessMeta(name: displayName.isEmpty ? shortName : displayName,
                           executablePath: path,
                           bundlePath: bundle)
    }
}

/// 进程内存用 MB / GB 展示（整机的 formatBytes 一律用 GB，粒度太粗）。
func formatProcessBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576.0
    if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}
