import AppKit

/// 温度折线按 30~80°C 映射到图表高度（超过 80°C 贴顶，便于一眼看出过热）。
private func normalizedTemperature(_ celsius: Double) -> Double {
    min(max((celsius - 30) / 50, 0), 1)
}

// MARK: - 外观

enum AppTheme: String {
    case dark
    case light
}

struct Palette {
    let background: NSColor
    let border: NSColor
    let primary: NSColor
    /// 文字专用色：始终 alpha=1，不随背景浓度变化（滑杆只调背景）
    let text: NSColor
    /// 辅助装饰色（缩放手柄等），允许半透明
    let secondary: NSColor
    let grid: NSColor
    let cpu: NSColor
    let memory: NSColor
    let locked: NSColor
    let unlocked: NSColor
    let temperature: NSColor

    static let dark = Palette(
        background: NSColor(srgbRed: 0.055, green: 0.065, blue: 0.085, alpha: 1),
        border: NSColor.white.withAlphaComponent(0.16),
        primary: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1),
        text: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1),
        secondary: NSColor.white.withAlphaComponent(0.60),
        grid: NSColor.white.withAlphaComponent(0.09),
        cpu: NSColor(srgbRed: 1.0, green: 0.46, blue: 0.42, alpha: 1),
        memory: NSColor(srgbRed: 0.34, green: 0.85, blue: 0.76, alpha: 1),
        locked: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.35, alpha: 1),
        unlocked: NSColor(srgbRed: 0.42, green: 0.87, blue: 0.62, alpha: 1),
        temperature: NSColor(srgbRed: 0.74, green: 0.58, blue: 1.0, alpha: 1)
    )

    static let light = Palette(
        background: NSColor(srgbRed: 0.98, green: 0.985, blue: 1.0, alpha: 1),
        border: NSColor.black.withAlphaComponent(0.14),
        primary: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        text: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
        secondary: NSColor.black.withAlphaComponent(0.54),
        grid: NSColor.black.withAlphaComponent(0.08),
        cpu: NSColor(srgbRed: 0.86, green: 0.22, blue: 0.18, alpha: 1),
        memory: NSColor(srgbRed: 0.02, green: 0.58, blue: 0.48, alpha: 1),
        locked: NSColor(srgbRed: 0.82, green: 0.48, blue: 0.02, alpha: 1),
        unlocked: NSColor(srgbRed: 0.08, green: 0.55, blue: 0.28, alpha: 1),
        temperature: NSColor(srgbRed: 0.44, green: 0.22, blue: 0.78, alpha: 1)
    )
}

// MARK: - 悬浮窗口

final class PulsePanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // 阴影由视图按圆角自行绘制
        hidesOnDeactivate = false
        isMovableByWindowBackground = false     // 拖动由视图自行处理
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = PulseView(frame: NSRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 缩放方向

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

// MARK: - 主视图：绘制 + 窗内控件 + 拖动 + 缩放

final class PulseView: NSView {
    var isLocked = false { didSet { needsDisplay = true } }
    var theme: AppTheme = .dark { didSet { needsDisplay = true } }
    var backgroundAlpha: CGFloat = 0.62 { didSet { needsDisplay = true } }
    var onSample: ((SystemSnapshot) -> Void)?
    var onFrameChanged: ((NSRect) -> Void)?
    var onLockTapped: (() -> Void)?
    var onAlphaChanged: ((CGFloat) -> Void)?

    private let monitor = SystemMonitor()
    private let pointCount = 90
    // 保持 internal，便于预览脚本 / 单元测试注入示例曲线
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var temperatureHistory: [Double] = []
    private var hasTemperature = false
    private var latest = SystemSnapshot(cpu: 0, memory: 0, usedBytes: 0, totalBytes: 0)
    private var timer: Timer?

    private enum DragMode: Equatable {
        case none
        case move
        case resize(ResizeEdges)
        case alpha
    }
    private var dragMode: DragMode = .none
    private var initialMouseLocation = NSPoint.zero
    private var initialFrame = NSRect.zero

    // 窗内控件的命中区域（每次 draw 时刷新）
    private var alphaTrackRect = NSRect.zero     // 滑杆视觉轨道
    private var alphaHitRect = NSRect.zero      // 滑杆点击/拖动热区
    private var lockHitRect = NSRect.zero       // 锁定按钮热区

    private let edgeThreshold: CGFloat = 7
    private let minSize = NSSize(width: 240, height: 116)
    private let shadowInset: CGFloat = 6
    private let alphaMinimum: CGFloat = 0.2     // 最通透 20%

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        // 先建立 CPU tick 基线，稍等再取一次，让初始曲线直接落在真实数值上
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let first = monitor.sample()
        latest = first
        cpuHistory = Array(repeating: first.cpu, count: pointCount)
        memoryHistory = Array(repeating: first.memory, count: pointCount)
        hasTemperature = first.temperature != nil
        temperatureHistory = Array(repeating: normalizedTemperature(first.temperature ?? 30),
                                   count: pointCount)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit { timer?.invalidate() }

    private func tick() {
        let snapshot = monitor.sample()
        latest = snapshot
        cpuHistory.append(snapshot.cpu)
        memoryHistory.append(snapshot.memory)
        if cpuHistory.count > pointCount { cpuHistory.removeFirst() }
        if memoryHistory.count > pointCount { memoryHistory.removeFirst() }
        if let celsius = snapshot.temperature {
            hasTemperature = true
            temperatureHistory.append(normalizedTemperature(celsius))
            if temperatureHistory.count > pointCount { temperatureHistory.removeFirst() }
        }
        needsDisplay = true
        onSample?(snapshot)
    }

    private var palette: Palette { theme == .dark ? .dark : .light }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pal = palette
        let panelRect = bounds.insetBy(dx: shadowInset, dy: shadowInset)
        let inner = panelRect.insetBy(dx: 12, dy: 9)

        // 圆角半透明面板 + 阴影
        let shape = NSBezierPath(roundedRect: panelRect, xRadius: 13, yRadius: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(theme == .dark ? 0.55 : 0.22)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        pal.background.withAlphaComponent(backgroundAlpha).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        pal.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // ── 顶部：标题 + 透明度滑杆 + 锁定按钮 ──
        let titleHeight: CGFloat = 16
        let controlHeight: CGFloat = 15
        let controlY = inner.maxY - controlHeight - 1
        let titleFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        drawText("SYSTEM PULSE", at: NSPoint(x: inner.minX, y: controlY + 3),
                 font: titleFont, color: pal.text)

        let roomy = inner.width >= 250
        let lockLabel = isLocked ? (roomy ? "⌥⌘L 解锁" : "已锁定") : "锁定"
        let lockWidth: CGFloat = isLocked ? (roomy ? 80 : 56) : 46
        let lockRect = NSRect(x: inner.maxX - lockWidth, y: controlY,
                              width: lockWidth, height: controlHeight)
        lockHitRect = lockRect.insetBy(dx: -2, dy: -3)
        drawLockButton(in: lockRect, label: lockLabel, palette: pal)

        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        let percentText = String(format: "%.0f%%", backgroundAlpha * 100)
        let percentWidth = textWidth(percentText, font: percentFont)
        let percentX = lockRect.minX - 8 - percentWidth
        drawText(percentText, at: NSPoint(x: percentX, y: controlY + 3),
                 font: percentFont, color: pal.text)

        let trackWidth: CGFloat = 38
        let track = NSRect(x: percentX - 7 - trackWidth, y: controlY + 5,
                           width: trackWidth, height: 5)
        alphaTrackRect = track
        alphaHitRect = track.insetBy(dx: -3, dy: -6)
        drawAlphaSlider(in: track, palette: pal)

        // ── 数值行 ──
        let numberHeight: CGFloat = 27
        let footerHeight: CGFloat = 12
        let numbersBottom = inner.maxY - titleHeight - numberHeight
        let rowY = numbersBottom + 1
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let cpuText = String(format: "%.1f%%", latest.cpu * 100)
        let memoryText = String(format: "%.1f%%", latest.memory * 100)
        let cpuWidth = textWidth(cpuText, font: numberFont)
        let memoryWidth = textWidth(memoryText, font: numberFont)

        drawText(cpuText, at: NSPoint(x: inner.minX, y: rowY), font: numberFont, color: pal.cpu)
        drawText("CPU", at: NSPoint(x: inner.minX + cpuWidth + 5, y: rowY + 13),
                 font: labelFont, color: pal.text)

        let column2 = inner.minX + max(120, inner.width * 0.47)
        drawText(memoryText, at: NSPoint(x: column2, y: rowY), font: numberFont, color: pal.memory)
        drawText("MEM", at: NSPoint(x: column2 + memoryWidth + 5, y: rowY + 13),
                 font: labelFont, color: pal.text)

        // 空间够时在数值行右侧显示醒目的温度；窄窗口时挪到底部小字里
        if roomy, let celsius = latest.temperature {
            let temperatureText = String(format: "%.0f°C", celsius)
            let temperatureFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            let temperatureX = inner.maxX - textWidth(temperatureText, font: temperatureFont)
            drawText(temperatureText, at: NSPoint(x: temperatureX, y: rowY + 7),
                     font: temperatureFont, color: pal.temperature)
        }

        // ── 走势图 ──
        let chartHeight = max(18, inner.height - titleHeight - numberHeight - footerHeight - 6)
        let chart = NSRect(x: inner.minX, y: inner.minY + footerHeight + 3,
                           width: inner.width, height: chartHeight)
        drawGrid(in: chart, palette: pal)
        if hasTemperature {
            drawSeries(temperatureHistory, color: pal.temperature, in: chart)
        }
        drawSeries(memoryHistory, color: pal.memory, in: chart)
        drawSeries(cpuHistory, color: pal.cpu, in: chart)

        // ── 底部小字：峰值 / 均值 / 内存可用 GB（始终显示，缩到最小也在）──
        let footerFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let peak = cpuHistory.max() ?? 0
        let average = cpuHistory.reduce(0, +) / Double(max(1, cpuHistory.count))
        let summary = String(format: "峰值 %.0f%% · 均值 %.0f%%", peak * 100, average * 100)
        drawText(summary, at: NSPoint(x: inner.minX, y: inner.minY + 1),
                 font: footerFont, color: pal.text)

        let available = latest.totalBytes > latest.usedBytes
            ? latest.totalBytes - latest.usedBytes : 0
        let availableText: String
        if let celsius = latest.temperature, !roomy {
            availableText = String(format: "%.0f°C · 可用 %@", celsius, formatBytes(available))
        } else {
            availableText = "可用 \(formatBytes(available)) / \(formatBytes(latest.totalBytes))"
        }
        let availableX = panelRect.maxX - 18 - textWidth(availableText, font: footerFont)
        drawText(availableText, at: NSPoint(x: availableX, y: inner.minY + 1),
                 font: footerFont, color: pal.text)

        // 右下角缩放手柄
        for index in 0..<3 {
            let offset = CGFloat(index) * 5
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: panelRect.maxX - 16 + offset, y: panelRect.minY + 8))
            grip.line(to: NSPoint(x: panelRect.maxX - 8, y: panelRect.minY + 16 - offset))
            grip.lineWidth = 1.2
            pal.secondary.setStroke()
            grip.stroke()
        }
    }

    private func drawAlphaSlider(in track: NSRect, palette pal: Palette) {
        let background = NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5)
        pal.secondary.withAlphaComponent(isLocked ? 0.22 : 0.34).setFill()
        background.fill()

        let ratio = clamp((backgroundAlpha - alphaMinimum) / (1 - alphaMinimum), min: 0, max: 1)
        let filledWidth = track.width * ratio
        if filledWidth > 1 {
            let filled = NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                          width: filledWidth, height: track.height),
                                      xRadius: 2.5, yRadius: 2.5)
            pal.unlocked.withAlphaComponent(isLocked ? 0.45 : 0.85).setFill()
            filled.fill()
        }
        let knobX = track.minX + filledWidth
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX - 3.5, y: track.midY - 3.5,
                                               width: 7, height: 7))
        pal.primary.withAlphaComponent(isLocked ? 0.5 : 1).setFill()
        knob.fill()
    }

    private func drawLockButton(in rect: NSRect, label: String, palette pal: Palette) {
        let accent = isLocked ? pal.locked : pal.unlocked
        let pill = NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5)
        accent.withAlphaComponent(isLocked ? 0.22 : 0.14).setFill()
        pill.fill()
        accent.withAlphaComponent(0.35).setStroke()
        pill.lineWidth = 0.8
        pill.stroke()

        let iconOrigin = NSPoint(x: rect.minX + 7, y: rect.midY)
        let body = NSBezierPath(roundedRect: NSRect(x: iconOrigin.x, y: iconOrigin.y - 3.5,
                                                    width: 8, height: 6),
                                xRadius: 1.5, yRadius: 1.5)
        accent.setFill()
        body.fill()

        let shift: CGFloat = isLocked ? 0 : -2.2    // 解锁时锁梁偏向一侧
        let shackle = NSBezierPath()
        shackle.move(to: NSPoint(x: iconOrigin.x + 1.5 + shift, y: iconOrigin.y + 2))
        shackle.curve(to: NSPoint(x: iconOrigin.x + 6.5 + shift, y: iconOrigin.y + 2),
                      controlPoint1: NSPoint(x: iconOrigin.x + 1.5 + shift, y: iconOrigin.y + 7),
                      controlPoint2: NSPoint(x: iconOrigin.x + 6.5 + shift, y: iconOrigin.y + 7))
        accent.setStroke()
        shackle.lineWidth = 1.2
        shackle.stroke()

        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        drawText(label, at: NSPoint(x: iconOrigin.x + 12, y: rect.minY + 3),
                 font: labelFont, color: accent)
    }

    private func drawGrid(in rect: NSRect, palette pal: Palette) {
        let grid = NSBezierPath()
        for index in 0...4 {
            let y = rect.minY + rect.height * CGFloat(index) / 4
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        for index in 0...6 {
            let x = rect.minX + rect.width * CGFloat(index) / 6
            grid.move(to: NSPoint(x: x, y: rect.minY))
            grid.line(to: NSPoint(x: x, y: rect.maxY))
        }
        grid.lineWidth = 0.6
        let pattern: [CGFloat] = [2, 4]
        grid.setLineDash(pattern, count: pattern.count, phase: 0)
        pal.grid.setStroke()
        grid.stroke()
    }

    private func drawSeries(_ values: [Double], color: NSColor, in rect: NSRect) {
        guard values.count > 1, rect.width > 2, rect.height > 2 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let points: [NSPoint] = values.enumerated().map { index, value in
            NSPoint(x: rect.minX + CGFloat(index) * step,
                    y: rect.minY + CGFloat(min(max(value, 0), 1)) * rect.height)
        }

        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() { line.line(to: point) }
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fill.line(to: NSPoint(x: rect.minX, y: rect.minY))
        fill.close()

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            fill.addClip()
            let colors = [color.withAlphaComponent(0.32).cgColor,
                          color.withAlphaComponent(0.01).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: rect.maxY),
                    end: CGPoint(x: 0, y: rect.minY),
                    options: []
                )
            }
            context.restoreGState()
        }

        color.setStroke()
        line.lineWidth = 1.6
        line.stroke()

        if let last = points.last {
            let halo = NSBezierPath(ovalIn: NSRect(x: last.x - 5, y: last.y - 5,
                                                   width: 10, height: 10))
            color.withAlphaComponent(0.22).setFill()
            halo.fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5,
                                                  width: 5, height: 5))
            color.setFill()
            dot.fill()
        }
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    // MARK: 鼠标交互（锁定时窗口会直接忽略所有鼠标事件，窗内按钮也一起失效）

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private func edges(at point: NSPoint) -> ResizeEdges {
        let rect = bounds.insetBy(dx: shadowInset, dy: shadowInset)
        if point.x >= rect.maxX - 18 && point.y <= rect.minY + 18 {
            return [.right, .bottom]
        }
        var result: ResizeEdges = []
        if point.x <= rect.minX + edgeThreshold { result.insert(.left) }
        if point.x >= rect.maxX - edgeThreshold { result.insert(.right) }
        if point.y >= rect.maxY - edgeThreshold { result.insert(.top) }
        if point.y <= rect.minY + edgeThreshold { result.insert(.bottom) }
        return result
    }

    private func applyAlpha(at location: NSPoint) {
        guard alphaTrackRect.width > 0 else { return }
        let ratio = clamp((location.x - alphaTrackRect.minX) / alphaTrackRect.width,
                          min: 0, max: 1)
        onAlphaChanged?(alphaMinimum + ratio * (1 - alphaMinimum))
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked, let window = window else { return }
        let location = convert(event.locationInWindow, from: nil)

        // 窗内控件优先于拖动/缩放
        if lockHitRect.contains(location) {
            dragMode = .none
            onLockTapped?()
            return
        }
        if alphaHitRect.contains(location) {
            dragMode = .alpha
            applyAlpha(at: location)
            return
        }

        let hitEdges = edges(at: location)
        initialMouseLocation = NSEvent.mouseLocation
        initialFrame = window.frame
        dragMode = hitEdges.isEmpty ? .move : .resize(hitEdges)
        if case .move = dragMode {
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isLocked, let window = window else { return }

        if case .alpha = dragMode {
            applyAlpha(at: convert(event.locationInWindow, from: nil))
            return
        }

        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouseLocation.x
        let dy = current.y - initialMouseLocation.y
        var frame = initialFrame

        switch dragMode {
        case .none, .alpha:
            return
        case .move:
            frame.origin.x = initialFrame.origin.x + dx
            frame.origin.y = initialFrame.origin.y + dy
        case .resize(let edges):
            if edges.contains(.left) {
                let width = clamp(initialFrame.width - dx, min: minSize.width, max: 1600)
                frame.size.width = width
                frame.origin.x = initialFrame.maxX - width
            }
            if edges.contains(.right) {
                frame.size.width = clamp(initialFrame.width + dx, min: minSize.width, max: 1600)
            }
            if edges.contains(.bottom) {
                let height = clamp(initialFrame.height - dy, min: minSize.height, max: 1000)
                frame.size.height = height
                frame.origin.y = initialFrame.maxY - height
            }
            if edges.contains(.top) {
                frame.size.height = clamp(initialFrame.height + dy, min: minSize.height, max: 1000)
            }
        }

        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .none:
            return
        case .alpha:
            dragMode = .none
            NSCursor.arrow.set()
        default:
            if let window = window { onFrameChanged?(window.frame) }
            dragMode = .none
            NSCursor.arrow.set()
        }
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }

    // MARK: 光标提示

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isLocked else { return }
        let location = convert(event.locationInWindow, from: nil)
        if lockHitRect.contains(location) || alphaHitRect.contains(location) {
            NSCursor.pointingHand.set()
            return
        }
        let hitEdges = edges(at: location)
        if hitEdges.isEmpty {
            NSCursor.openHand.set()
        } else if hitEdges == [.left] || hitEdges == [.right] {
            NSCursor.resizeLeftRight.set()
        } else if hitEdges == [.top] || hitEdges == [.bottom] {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
