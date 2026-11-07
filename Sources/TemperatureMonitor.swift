import Foundation

/// 温度变化很慢，做成节流采样：CPU/内存仍每秒刷新，温度最多每 3 秒枚举一次 HID 传感器。
final class TemperatureMonitor {
    private let interval: TimeInterval = 3.0
    private var lastSampleTime: TimeInterval = -TimeInterval.greatestFiniteMagnitude
    private var cachedValue: Double = -1

    /// 摄氏度；nil 表示当前设备/系统不提供可读的温度传感器。
    func sample() -> Double? {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastSampleTime < interval {
            return cachedValue >= 0 ? cachedValue : nil
        }
        lastSampleTime = now
        let value = sp_current_temperature()
        cachedValue = value
        return value >= 0 ? value : nil
    }
}
