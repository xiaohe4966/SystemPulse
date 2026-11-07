import AppKit
import Carbon

/// Carbon 全局热键的 C 回调不能捕获上下文，用一个全局闭包转发到主线程。
private var globalLockToggle: (() -> Void)?

private func hotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                            _ event: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { globalLockToggle?() }
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let frame = "SystemPulse.frame.v2"   // 紧凑布局改版，旧尺寸不再复用
        static let locked = "SystemPulse.locked"
        static let alpha = "SystemPulse.backgroundAlpha"
        static let theme = "SystemPulse.theme"
        static let alwaysOnTop = "SystemPulse.alwaysOnTop"
    }

    private var statusItem: NSStatusItem!
    private var panel: PulsePanel!
    private var pulseView: PulseView!
    private let processList = ProcessListController()

    private var menu: NSMenu!
    private var statusTitleItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var topItem: NSMenuItem!
    private var alphaItems: [NSMenuItem] = []
    private var themeItems: [NSMenuItem] = []
    private var alphaHeaderItem: NSMenuItem!

    private var locked = false
    private var alwaysOnTop = true
    private var backgroundAlpha: CGFloat = 0.62
    private var theme: AppTheme = .dark

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private let alphaOptions: [(String, Int)] = [
        ("通透 · 35%", 35),
        ("标准 · 62%", 62),
        ("较实 · 82%", 82),
        ("完全不透明", 100)
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()

        panel = PulsePanel(frame: restoredFrame())
        pulseView = panel.contentView as? PulseView
        pulseView?.theme = theme
        pulseView?.backgroundAlpha = backgroundAlpha
        pulseView?.isLocked = locked
        pulseView?.onSample = { [weak self] snapshot in self?.updateStatusTitle(snapshot) }
        pulseView?.onFrameChanged = { [weak self] frame in
            self?.defaults.set(NSStringFromRect(frame), forKey: Key.frame)
        }
        pulseView?.onLockTapped = { [weak self] in self?.toggleLock() }
        pulseView?.onAlphaChanged = { [weak self] value in
            guard let self = self else { return }
            self.backgroundAlpha = value
            self.pulseView?.backgroundAlpha = value
            self.defaults.set(Double(value), forKey: Key.alpha)
            self.refreshMenu()
        }
        pulseView?.onShowProcessList = { [weak self] metric in
            guard let self = self else { return }
            self.processList.show(metric: metric, near: self.panel.frame, theme: self.theme)
        }
        panel.ignoresMouseEvents = locked
        panel.level = alwaysOnTop ? .floating : .normal

        setupStatusItem()
        registerGlobalHotKey()
        panel.orderFrontRegardless()
    }

    // MARK: - 设置持久化

    private func loadSettings() {
        // 旧版大窗口：保留用户摆好的位置，尺寸换成新的紧凑默认值（只迁移一次）
        if defaults.string(forKey: Key.frame) == nil,
           let legacy = defaults.string(forKey: "SystemPulse.frame") {
            let old = NSRectFromString(legacy)
            if old.width > 0, old.height > 0 {
                var migrated = defaultFrame()
                migrated.origin = old.origin
                defaults.set(NSStringFromRect(migrated), forKey: Key.frame)
            }
            defaults.removeObject(forKey: "SystemPulse.frame")
        }
        locked = defaults.bool(forKey: Key.locked)
        let storedAlpha = defaults.double(forKey: Key.alpha)
        if storedAlpha > 0 { backgroundAlpha = CGFloat(storedAlpha) }
        if let raw = defaults.string(forKey: Key.theme),
           let saved = AppTheme(rawValue: raw) { theme = saved }
        if defaults.object(forKey: Key.alwaysOnTop) != nil {
            alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        }
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 300
        let height: CGFloat = 136
        return NSRect(x: screen.maxX - width - 28, y: screen.maxY - height - 28,
                      width: width, height: height)
    }

    private func restoredFrame() -> NSRect {
        guard let raw = defaults.string(forKey: Key.frame) else { return defaultFrame() }
        let frame = NSRectFromString(raw)
        guard frame.width >= 240, frame.height >= 116,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
            return defaultFrame()
        }
        return frame
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusImage(locked: locked)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = " --% · --%"
            button.toolTip = "SystemPulse：点击打开菜单，可锁定 / 解锁悬浮窗"
        }

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        buildMenu()
    }

    private func buildMenu() {
        menu.removeAllItems()
        alphaItems.removeAll()
        themeItems.removeAll()

        statusTitleItem = NSMenuItem(title: "正在采样…", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        menu.addItem(.separator())

        lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        visibilityItem = NSMenuItem(title: "", action: #selector(toggleVisibility), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)

        topItem = NSMenuItem(title: "始终置顶显示", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        topItem.target = self
        menu.addItem(topItem)

        menu.addItem(.separator())
        let processHeader = NSMenuItem(title: "进程占用列表（也可点击浮窗数值）", action: nil, keyEquivalent: "")
        processHeader.isEnabled = false
        menu.addItem(processHeader)
        let cpuItem = NSMenuItem(title: "按 CPU 占用排序…", action: #selector(showCPUList), keyEquivalent: "")
        cpuItem.target = self
        cpuItem.toolTip = "查看各进程 CPU 占用，可降序 / 升序 / 按名称排列，右键可强制结束"
        menu.addItem(cpuItem)
        let memoryItem = NSMenuItem(title: "按内存占用排序…", action: #selector(showMemoryList), keyEquivalent: "")
        memoryItem.target = self
        memoryItem.toolTip = "查看各进程内存占用，可降序 / 升序 / 按名称排列，右键可强制结束"
        menu.addItem(memoryItem)

        menu.addItem(.separator())
        alphaHeaderItem = NSMenuItem(title: "背景浓度", action: nil, keyEquivalent: "")
        alphaHeaderItem.isEnabled = false
        menu.addItem(alphaHeaderItem)
        for (title, value) in alphaOptions {
            let item = NSMenuItem(title: title, action: #selector(chooseAlpha(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            menu.addItem(item)
            alphaItems.append(item)
        }

        menu.addItem(.separator())
        let themeHeader = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        themeHeader.isEnabled = false
        menu.addItem(themeHeader)
        for (index, title) in ["深色", "浅色"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
            themeItems.append(item)
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "恢复默认位置与大小", action: #selector(resetFrame), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let quit = NSMenuItem(title: "退出 SystemPulse", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        refreshMenu()
    }

    private func refreshMenu() {
        lockItem?.title = locked ? "解锁悬浮窗   ⌥⌘L" : "锁定悬浮窗   ⌥⌘L"
        visibilityItem?.title = (panel?.isVisible ?? true) ? "隐藏悬浮窗" : "显示悬浮窗"
        topItem?.state = alwaysOnTop ? .on : .off
        let current = Int((backgroundAlpha * 100).rounded())
        alphaHeaderItem?.title = "背景浓度 \(current)% · 也可拖窗内滑杆"
        for item in alphaItems {
            item.state = abs(item.tag - current) <= 2 ? .on : .off
        }
        for item in themeItems {
            item.state = (item.tag == 0 ? theme == .dark : theme == .light) ? .on : .off
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func updateStatusTitle(_ snapshot: SystemSnapshot) {
        let temperatureDetail = snapshot.temperature.map { String(format: "  温度 %.0f°C", $0) } ?? ""
        statusTitleItem?.title = String(
            format: "CPU %.1f%%   内存 %.1f%%   %@ / %@%@",
            snapshot.cpu * 100, snapshot.memory * 100,
            formatBytes(snapshot.usedBytes), formatBytes(snapshot.totalBytes),
            temperatureDetail
        )
        let temperatureShort = snapshot.temperature.map { String(format: " · %.0f°", $0) } ?? ""
        statusItem?.button?.title = String(format: " %.0f%% · %.0f%%%@",
                                           snapshot.cpu * 100, snapshot.memory * 100,
                                           temperatureShort)
    }

    private func statusImage(locked isLocked: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let color: NSColor = isLocked
                ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
                : NSColor.black
            color.setStroke()
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 1, y: 8))
            wave.line(to: NSPoint(x: 3.5, y: 8))
            wave.line(to: NSPoint(x: 6, y: 13))
            wave.line(to: NSPoint(x: 9, y: 2.5))
            wave.line(to: NSPoint(x: 12, y: 10))
            wave.line(to: NSPoint(x: 14.5, y: 8))
            wave.line(to: NSPoint(x: 17, y: 8))
            wave.lineWidth = 1.5
            wave.lineJoinStyle = .round
            wave.lineCapStyle = .round
            wave.stroke()

            if isLocked {
                let dot = NSBezierPath(ovalIn: NSRect(x: 11, y: 0.5, width: 6, height: 6))
                NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1).setFill()
                dot.fill()
                color.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
        // 模板图会随系统菜单栏明暗自动变色；锁定时保留橙色提示
        image.isTemplate = !isLocked
        return image
    }

    // MARK: - 菜单动作

    @objc private func toggleLock() {
        locked.toggle()
        panel.ignoresMouseEvents = locked
        pulseView?.isLocked = locked
        defaults.set(locked, forKey: Key.locked)
        statusItem?.button?.image = statusImage(locked: locked)
        refreshMenu()
    }

    @objc private func toggleVisibility() {
        let visible = !(panel.isVisible)
        panel.setIsVisible(visible)
        if visible { panel.orderFrontRegardless() }
        refreshMenu()
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        panel.level = alwaysOnTop ? .floating : .normal
        defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop)
        refreshMenu()
    }

    @objc private func chooseAlpha(_ sender: NSMenuItem) {
        backgroundAlpha = CGFloat(sender.tag) / 100
        pulseView?.backgroundAlpha = backgroundAlpha
        defaults.set(Double(backgroundAlpha), forKey: Key.alpha)
        refreshMenu()
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        theme = sender.tag == 0 ? .dark : .light
        pulseView?.theme = theme
        processList.setTheme(theme)
        defaults.set(theme.rawValue, forKey: Key.theme)
        refreshMenu()
    }

    @objc private func showCPUList() {
        processList.show(metric: .cpu, near: panel.frame, theme: theme)
    }

    @objc private func showMemoryList() {
        processList.show(metric: .memory, near: panel.frame, theme: theme)
    }

    @objc private func resetFrame() {
        let frame = defaultFrame()
        panel.setFrame(frame, display: true)
        defaults.set(NSStringFromRect(frame), forKey: Key.frame)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 全局热键 ⌥⌘L（无需辅助功能权限）

    private func registerGlobalHotKey() {
        globalLockToggle = { [weak self] in self?.toggleLock() }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1,
                            &eventType, nil, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50554C53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_L),
                            UInt32(optionKey) | UInt32(cmdKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }
}
