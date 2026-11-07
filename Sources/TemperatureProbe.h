#ifndef TEMPERATURE_PROBE_H
#define TEMPERATURE_PROBE_H

/// 读取 Apple Silicon 上最高的 SoC / CPU die 温度（摄氏度）。
/// 私有接口不可用或读不到传感器时返回 -1。
/// 实现见 TemperatureProbe.c：通过 IOKit 的 IOHIDEventSystemClient
/// 同步读取 PMU 温度传感器，过滤电池传感器后取最大值。
double sp_current_temperature(void);

#endif /* TEMPERATURE_PROBE_H */
