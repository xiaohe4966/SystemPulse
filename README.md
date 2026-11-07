# SystemPulse

macOS 原生透明悬浮窗，实时显示 **CPU / 内存 / SoC 温度** 和心跳式走势图。可随意拖动缩放、调节透明度；一键锁定后，鼠标点击完全穿透到下面的窗口。

**简体中文** · [English](README.en.md)

![SystemPulse 主界面](screenshots/overview.png)

> 纯 Swift 5 + AppKit + 少量 C，无第三方依赖、无 Xcode 工程、无网络请求、不申请任何系统权限。Universal 二进制，Apple Silicon 与 Intel Mac 都能跑（macOS 11.0+）。

---

## 功能一览

| 项目 | 说明 |
| --- | --- |
| 实时采样 | 整机 CPU 使用率、内存使用率与已用/总量，每秒刷新一次 |
| 温度 | CPU / SoC die 温度（紫色折线与数字），3 秒采样一次 |
| 心跳走势图 | 红＝CPU、青＝内存、紫＝温度，滚动折线 + 渐变填充 + 末端亮点 |
| 常驻小字 | `峰值 xx% · 均值 xx%`、`可用 x.x GB / xx GB`，窗口缩到最小也不消失 |
| 透明悬浮窗 | 无边框圆角面板，深色/浅色外观，背景浓度 20%~100% 任意拖动 |
| 拖动缩放 | 拖四边、四角或右下角手柄任意调整大小（最小 240×116）；位置与尺寸自动保存 |
| 锁定 / 解锁 | 锁定后点击穿透，浮窗完全不响应鼠标；`⌥⌘L` 或菜单栏解锁 |
| 窗内控件 | 顶部迷你透明度滑杆 + 锁定按钮，右侧实时显示浓度百分比 |
| 菜单栏 | 心电图图标实时显示 `CPU% · 内存% · 温度`，菜单里可显示/隐藏、置顶、切换外观、重置位置、退出 |

| 默认界面 | 锁定状态 |
| --- | --- |
| ![默认界面](screenshots/overview.png) | ![锁定状态](screenshots/locked.png) |

| 最小尺寸 240×116 | 背景浓度 35% |
| --- | --- |
| ![最小尺寸](screenshots/compact.png) | ![通透档](screenshots/transparency.png) |

---

## 下载与安装

到 [Releases](https://github.com/xiaohe4966/SystemPulse/releases/latest) 下载 **`SystemPulse-1.0.0-macOS.zip`**，解压后把 `SystemPulse.app` 拖进 `/Applications`，双击运行即可。启动后菜单栏右上角会出现心电图图标。

> **首次打开提示"已损坏，无法打开"？**
> 这个 App 使用 ad-hoc 签名，没有 Apple Developer ID 签名与公证。在终端执行一次
> `xattr -cr /Applications/SystemPulse.app`
> 清除下载隔离标记后再打开即可；也可以在 Finder 里 **右键 App → 打开 → 打开**。
> 不放心的话，直接按下面的方式从源码自己编译，效果完全一样。

卸载：菜单栏图标 → 退出，然后把 `SystemPulse.app` 丢进废纸篓。偏好设置可用 `defaults delete local.systempulse.monitor` 清空。

---

## 操作说明

| 操作 | 效果 |
| --- | --- |
| 拖窗口中间空白处 | 移动窗口 |
| 拖四边 / 四角 / 右下角斜线手柄 | 八方向缩放 |
| 拖顶部滑杆 | 调背景浓度（20%~100%），旁边实时显示百分比 |
| 点右上角绿色「锁定」 | 立即锁定，按钮变橙并显示 `⌥⌘L 解锁` |
| 按 `⌥⌘L` 或点菜单栏图标 → 「解锁悬浮窗」 | 解锁，恢复拖动与缩放 |
| 菜单栏菜单 | 显示/隐藏、始终置顶、背景浓度快捷档、深色/浅色、恢复默认位置与大小、退出 |

**关于锁定**：锁定后窗口设为 `ignoresMouseEvents`，点击任何位置都直接穿透到下层窗口，连窗内的锁定按钮和滑杆也会一起失效——这是刻意的设计，用来保证"锁定后点击悬浮窗没有任何反应"。因此解锁入口放在菜单栏和全局热键上，锁定按钮会直接把快捷键写在自己脸上提醒你。

> 万一菜单栏图标被 macOS 折叠隐藏，仍可用 `⌥⌘L` 解锁；也可以执行 `defaults delete local.systempulse.monitor` 后重启恢复默认设置。

---

## 自己编译

只需要 macOS 与 Xcode Command Line Tools（`xcode-select --install`），不需要 Xcode 工程、SwiftPM 或 CocoaPods。

```bash
git clone https://github.com/xiaohe4966/SystemPulse.git
cd SystemPulse

./build.sh            # 编译 Universal（arm64 + x86_64），可直接分发
./build.sh --run      # 编译后立刻启动
./build.sh --native   # 只编译当前机器架构，更快
```

产物是同目录下的 `SystemPulse.app`（已 ad-hoc 签名）。脚本会用 `clang` 编译温度探针的 C 代码，再用 `swiftc` 把两个架构的 Swift 产物用 `lipo` 合并。`--run` 和 `--native` 可以组合使用。

CI 里也跑同一条 `./build.sh`，见 [.github/workflows/build.yml](.github/workflows/build.yml)。

---

## 实现原理

| 文件 | 作用 |
| --- | --- |
| `Sources/main.swift` | AppKit 入口；`LSUIElement` 应用，不占 Dock |
| `Sources/AppDelegate.swift` | `NSStatusItem` 菜单栏、锁定状态、Carbon 全局热键 `⌥⌘L`、`UserDefaults` 偏好持久化 |
| `Sources/PulseWindow.swift` | 无边框透明 `NSPanel`，CoreGraphics 自绘面板与折线，鼠标命中区实现移动 / 八方向缩放 / 滑杆 / 按钮 |
| `Sources/SystemMonitor.swift` | `host_statistics(HOST_CPU_LOAD_INFO)` 用两次 tick 差值算 CPU；`host_statistics64(HOST_VM_INFO64)` 把 free + inactive 页视为可用内存，其余算已用 |
| `Sources/TemperatureMonitor.swift` | 温度 3 秒节流缓存，避免频繁枚举传感器 |
| `Sources/TemperatureProbe.c/.h` | 通过 IOKit HID 传感器读取温度（C 层） |

**关于温度**：Apple 没有公开的 CPU 温度 API，Intel 时代常见的 SMC 键在 Apple Silicon 上也不适用。本项目走 IOKit 的 HID 传感器通道：匹配 `PrimaryUsagePage = 0xff00 (AppleVendor)` / `PrimaryUsage = 0x0005 (温度传感器)`，逐个读取 `kIOHIDEventTypeTemperature` 事件，过滤掉电池 / gas gauge 传感器后取 die 最高温。这些是私有符号，全部通过 `dlsym` 动态解析，**不静态链接私有 API**；事件对象每次读完立即释放。

读不到传感器时（例如 Intel Mac，或未来 macOS 升级改变了接口），程序会**自动隐藏温度数字与紫色折线**，CPU、内存等其余功能照常工作，不会崩溃。温度显示的是 SoC die 的最高读数，按 30~80°C 映射到图表高度，只是参考值，不等同于 Apple 官方温度指标。

---

## 隐私

所有数据都来自本机系统计数器，纯本地读取：不联网、不上传、不写日志、不申请辅助功能 / 完全磁盘访问 / root 权限。全局热键用 Carbon `RegisterEventHotKey` 注册，同样不需要辅助功能授权。

## 已知限制

- 没有 Developer ID 签名与公证，首次打开需要手动清除 quarantine 属性。
- `LSUIElement` 应用没有 Dock 图标和主菜单，退出只能通过菜单栏图标。
- 温度是 SoC die 传感器最高值，不同机型传感器命名与数量不同，数值仅供参考。
- 窗口最小 240×116，再小会让文字挤在一起。
- 界面文案（按钮、菜单项）目前只有中文，英文对照见 [README.en.md](README.en.md)。

## 许可证

[MIT](LICENSE) © 2026 xiaohe4966
