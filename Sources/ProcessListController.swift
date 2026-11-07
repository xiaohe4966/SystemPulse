import AppKit
import Darwin

/// 进程列表的三种排序方式（CPU / 内存视图共用）。
enum ProcessSort: String {
    case descending      // 占用从高到低
    case ascending       // 占用从低到高
    case name            // 按名称 A~Z
}

/// 自己画一层实底，保证深色/浅色外观下标题与分段控件都有稳定背景。
private final class ProcessRootView: NSView {
    var fill = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fill.setFill()
        bounds.fill()
    }
}

/// 右键菜单需要知道鼠标落在哪一行。
private final class ProcessTableView: NSTableView {
    weak var owner: ProcessListController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        owner?.contextRow = row
        return super.menu(for: event)
    }
}

/// 点击悬浮窗 CPU / 内存数值后弹出的进程占用列表窗口。
final class ProcessListController: NSObject, NSWindowDelegate, NSTableViewDataSource,
                                   NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {

    private enum Key {
        static let metric = "SystemPulse.processMetric"
        static let sort = "SystemPulse.processSort"
        static let frame = "SystemPulse.processFrame"
    }

    private let monitor = ProcessMonitor()
    private let defaults = UserDefaults.standard
    private let iconCache = NSCache<NSNumber, NSImage>()

    private var window: NSWindow?
    private var rootView: ProcessRootView!
    private var tableView: ProcessTableView!
    private var titleLabel: NSTextField!
    private var summaryLabel: NSTextField!
    private var metricControl: NSSegmentedControl!
    private var sortControl: NSSegmentedControl!
    private var searchField: NSSearchField!
    private var contextMenu: NSMenu!

    private var allEntries: [ProcessEntry] = []
    private var rows: [ProcessEntry] = []
    private var filter = ""
    private var refreshTimer: Timer?
    private var theme: AppTheme = .dark

    private var metric: ProcessMetric = .cpu
    private var sort: ProcessSort = .descending

    /// 由右键菜单选中行设置，供菜单动作读取
    var contextRow: Int?

    override init() {
        super.init()
        if let raw = defaults.string(forKey: Key.metric),
           let saved = ProcessMetric(rawValue: raw) { metric = saved }
        if let raw = defaults.string(forKey: Key.sort),
           let saved = ProcessSort(rawValue: raw) { sort = saved }
    }

    // MARK: - 对外入口

    func show(metric requested: ProcessMetric, near panelFrame: NSRect, theme: AppTheme) {
        if window == nil { buildWindow() }
        guard let window = window else { return }

        if metric != requested {
            metric = requested
            defaults.set(metric.rawValue, forKey: Key.metric)
        }
        self.theme = theme
        applyTheme()

        if !window.isVisible {
            position(near: panelFrame)
            restoreFrame(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if refreshTimer == nil {
            startSampling()
        } else {
            applyFilterAndSort()
            tableView.reloadData()
        }
        syncControls()
    }

    func setTheme(_ theme: AppTheme) {
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        let dark = theme == .dark
        let background = dark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window?.backgroundColor = background
        rootView?.fill = background
        titleLabel?.textColor = dark
            ? NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        summaryLabel?.textColor = dark
            ? NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)
        rootView?.needsDisplay = true
    }

    private func position(near panelFrame: NSRect) {
        guard let window = window else { return }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        var origin = NSPoint(x: panelFrame.minX - size.width - 12,
                             y: panelFrame.minY - size.height - 12)
        if origin.x < screen.minX + 8 { origin.x = panelFrame.maxX + 12 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let below = panelFrame.minY - size.height - 12
        origin.y = below >= screen.minY + 8 ? below : panelFrame.maxY + 12
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        window.setFrameOrigin(origin)
    }

    private func restoreFrame(_ window: NSWindow) {
        guard let raw = defaults.string(forKey: Key.frame) else { return }
        let frame = NSRectFromString(raw)
        guard frame.width >= 480, frame.height >= 280,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = window else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: Key.frame)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = window, window.isVisible else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: Key.frame)
    }

    // MARK: - 窗口搭建

    private func buildWindow() {
        let width: CGFloat = 720
        let height: CGFloat = 440
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        panel.title = "SystemPulse · 进程占用"
        panel.minSize = NSSize(width: 480, height: 280)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.hidesOnDeactivate = false
        window = panel

        rootView = ProcessRootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView
        let content: NSView = rootView

        let header = NSView(frame: NSRect(x: 0, y: height - 66, width: width, height: 66))
        header.autoresizingMask = [.width, .minYMargin]
        content.addSubview(header)

        titleLabel = label("", size: 13, weight: .semibold,
                           frame: NSRect(x: 16, y: 36, width: 220, height: 20))
        header.addSubview(titleLabel)

        metricControl = NSSegmentedControl(labels: ["CPU", "内存"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(metricChanged(_:)))
        metricControl.frame = NSRect(x: width - 16 - 156 - 12 - 186 - 12 - 108,
                                     y: 35, width: 108, height: 22)
        metricControl.autoresizingMask = [.minXMargin]
        metricControl.selectedSegment = metric == .cpu ? 0 : 1
        header.addSubview(metricControl)

        sortControl = NSSegmentedControl(labels: ["降序", "升序", "名称"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(sortChanged(_:)))
        sortControl.frame = NSRect(x: width - 16 - 156 - 12 - 186,
                                   y: 35, width: 186, height: 22)
        sortControl.autoresizingMask = [.minXMargin]
        header.addSubview(sortControl)

        searchField = NSSearchField(frame: NSRect(x: width - 16 - 156,
                                                  y: 35, width: 156, height: 22))
        searchField.placeholderString = "搜索进程名 / 路径"
        searchField.autoresizingMask = [.minXMargin]
        searchField.delegate = self
        header.addSubview(searchField)

        summaryLabel = label("", size: 10.5, weight: .regular,
                             frame: NSRect(x: 16, y: 12, width: width - 32, height: 16))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.autoresizingMask = [.width]
        header.addSubview(summaryLabel)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16,
                                                width: width - 32, height: height - 66 - 16))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        content.addSubview(scroll)

        tableView = ProcessTableView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tableView.owner = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.doubleAction = #selector(revealSelected(_:))
        tableView.target = self
        tableView.autoresizingMask = [.width]
        tableView.menu = makeContextMenu()

        for columnSpec in [
            ("name", "进程名称", CGFloat(210), CGFloat(120)),
            ("pid", "PID", CGFloat(60), CGFloat(50)),
            ("cpu", "CPU%", CGFloat(75), CGFloat(60)),
            ("memory", "内存", CGFloat(110), CGFloat(80)),
            ("path", "可执行文件位置", CGFloat(225), CGFloat(120))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnSpec.0))
            column.title = columnSpec.1
            column.width = columnSpec.2
            column.minWidth = columnSpec.3
            column.sortDescriptorPrototype = NSSortDescriptor(key: columnSpec.0, ascending: false)
            if columnSpec.0 == "pid" || columnSpec.0 == "cpu" || columnSpec.0 == "memory" {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        scroll.documentView = tableView

        applyTheme()
        syncControls()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        return field
    }

    // MARK: - 采样与排序

    private func startSampling() {
        monitor.reset()
        refresh()                       // 第一帧建立 CPU tick 基线，CPU 列暂为 0
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        // 0.8 秒后补采一帧，避免刚打开时 CPU 列空等 2 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard self?.refreshTimer != nil else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        allEntries = monitor.sample()
        applyFilterAndSort()
        tableView.reloadData()
        let total = allEntries.count
        let visible = filter.isEmpty ? "\(total)" : "\(rows.count) / \(total)"
        let cpuNote = "CPU 为整机占比（\(monitor.cores) 核归一化）"
        summaryLabel.stringValue =
            "每 2 秒刷新 · 共 \(visible) 个进程 · \(cpuNote) · 右键可强制结束 / 在 Finder 中打开运行位置"
    }

    private func metricValue(_ entry: ProcessEntry) -> Double {
        metric == .cpu ? entry.cpuPercent : Double(entry.memoryBytes)
    }

    private func applyFilterAndSort() {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = needle.isEmpty ? allEntries : allEntries.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.executablePath.localizedCaseInsensitiveContains(needle)
        }
        switch sort {
        case .name:
            rows.sort { lhs, rhs in
                let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return result == .orderedSame ? lhs.pid < rhs.pid : result == .orderedAscending
            }
        case .descending, .ascending:
            let down = sort == .descending
            rows.sort { lhs, rhs in
                let a = metricValue(lhs), b = metricValue(rhs)
                if a != b { return down ? a > b : a < b }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func syncControls() {
        metricControl?.selectedSegment = metric == .cpu ? 0 : 1
        sortControl?.selectedSegment = sort == .descending ? 0 : (sort == .ascending ? 1 : 2)
        titleLabel?.stringValue = metric == .cpu ? "CPU 占用排行" : "内存占用排行"
        syncSortDescriptors()
    }

    private func syncSortDescriptors() {
        guard let tableView = tableView else { return }
        let key = sort == .name ? "name" : (metric == .cpu ? "cpu" : "memory")
        let ascending = sort != .descending
        let descriptor = NSSortDescriptor(key: key, ascending: ascending)
        let current = tableView.sortDescriptors.first
        if current?.key != key || current?.ascending != ascending {
            tableView.sortDescriptors = [descriptor]
        }
    }

    private func applySort(_ newSort: ProcessSort) {
        sort = newSort
        defaults.set(sort.rawValue, forKey: Key.sort)
        syncControls()
        applyFilterAndSort()
        tableView.reloadData()
    }

    // MARK: - 控件动作

    @objc private func metricChanged(_ sender: NSSegmentedControl) {
        metric = sender.selectedSegment == 0 ? .cpu : .memory
        defaults.set(metric.rawValue, forKey: Key.metric)
        syncControls()
        applyFilterAndSort()
        tableView.reloadData()
    }

    @objc private func sortChanged(_ sender: NSSegmentedControl) {
        let modes: [ProcessSort] = [.descending, .ascending, .name]
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        applySort(modes[sender.selectedSegment])
    }

    func controlTextDidChange(_ obj: Notification) {
        filter = searchField?.stringValue ?? ""
        applyFilterAndSort()
        tableView.reloadData()
        refreshSummaryOnly()
    }

    private func refreshSummaryOnly() {
        let total = allEntries.count
        let visible = filter.isEmpty ? "\(total)" : "\(rows.count) / \(total)"
        summaryLabel.stringValue =
            "每 2 秒刷新 · 共 \(visible) 个进程 · CPU 为整机占比（\(monitor.cores) 核归一化） · 右键可强制结束 / 在 Finder 中打开运行位置"
    }

    // MARK: - TableView 数据源

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let identifier = column.identifier.rawValue
        let cell = makeCell(identifier, width: column.width)
        let field = cell.textField

        switch identifier {
        case "name":
            field?.stringValue = entry.name
            cell.imageView?.image = icon(for: entry)
            cell.toolTip = entry.executablePath.isEmpty ? entry.name : entry.executablePath
        case "pid":
            field?.stringValue = "\(entry.pid)"
        case "cpu":
            field?.stringValue = String(format: "%.2f%%", entry.cpuPercent)
            field?.textColor = .systemRed
        case "memory":
            field?.stringValue = String(format: "%@ · %.1f%%",
                                        formatProcessBytes(entry.memoryBytes),
                                        entry.memoryPercent)
            field?.textColor = .systemTeal
        case "path":
            field?.stringValue = entry.executablePath
            field?.textColor = .secondaryLabelColor
            cell.toolTip = entry.executablePath
        default:
            break
        }
        return cell
    }

    private func makeCell(_ identifier: String, width: CGFloat) -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        cell.identifier = NSUserInterfaceItemIdentifier("pcell-\(identifier)")
        let hasIcon = identifier == "name"
        let left: CGFloat = hasIcon ? 24 : 4
        let field = NSTextField(frame: NSRect(x: left, y: 3,
                                              width: width - left - 4, height: 18))
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        if identifier == "pid" || identifier == "cpu" || identifier == "memory" {
            field.alignment = .right
        }
        field.autoresizingMask = [.width, .height]
        cell.addSubview(field)
        cell.textField = field
        if hasIcon {
            let iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
            iconView.imageScaling = .scaleProportionallyDown
            cell.addSubview(iconView)
            cell.imageView = iconView
        }
        return cell
    }

    private func icon(for entry: ProcessEntry) -> NSImage {
        let key = NSNumber(value: entry.pid)
        if let cached = iconCache.object(forKey: key) { return cached }
        let workspace = NSWorkspace.shared
        let image: NSImage
        if let bundle = entry.bundlePath,
           FileManager.default.fileExists(atPath: bundle) {
            image = workspace.icon(forFile: bundle)
        } else if !entry.executablePath.isEmpty,
                  FileManager.default.fileExists(atPath: entry.executablePath) {
            image = workspace.icon(forFile: entry.executablePath)
        } else {
            // 内核任务等没有可执行文件路径，留一个空白占位，避免误用别的程序图标
            image = NSImage(size: NSSize(width: 16, height: 16))
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache.setObject(image, forKey: key)
        return image
    }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let next: ProcessSort
        switch key {
        case "name":
            next = .name
        case "cpu", "memory":
            // 点 CPU% / 内存 表头时顺便切换该维度，与点击悬浮窗数值的语义保持一致
            metric = key == "cpu" ? .cpu : .memory
            defaults.set(metric.rawValue, forKey: Key.metric)
            next = descriptor.ascending ? .ascending : .descending
        default:
            return
        }
        sort = next
        defaults.set(sort.rawValue, forKey: Key.sort)
        syncControls()
        applyFilterAndSort()
        tableView.reloadData()
    }

    // MARK: - 右键菜单

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, _ tag: Int) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        add("强制结束进程…", #selector(forceQuit(_:)), 1)
        add("正常退出进程…", #selector(gracefulQuit(_:)), 2)
        menu.addItem(.separator())
        add("在 Finder 中显示运行位置", #selector(revealInFinder(_:)), 3)
        add("打开这个应用", #selector(openApplication(_:)), 4)
        add("打开可执行文件所在文件夹", #selector(openContainingFolder(_:)), 5)
        menu.addItem(.separator())
        add("复制进程名称", #selector(copyName(_:)), 6)
        add("复制 PID", #selector(copyPID(_:)), 7)
        add("复制完整路径", #selector(copyPath(_:)), 8)
        menu.addItem(.separator())
        add("立即刷新", #selector(refreshNow(_:)), 9)
        contextMenu = menu
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let entry = contextEntry
        let canTerminate = entry.map { $0.pid > 1 && $0.pid != getpid() } ?? false
        let hasPath = entry.map { !$0.executablePath.isEmpty } ?? false
        let hasBundle = entry.map { ($0.bundlePath?.isEmpty ?? true) == false } ?? false
        for item in menu.items {
            switch item.tag {
            case 1, 2:   item.isEnabled = canTerminate
            case 3, 5, 8: item.isEnabled = hasPath
            case 4:      item.isEnabled = hasBundle
            case 6, 7:   item.isEnabled = entry != nil
            default:     item.isEnabled = true
            }
        }
    }

    private var contextEntry: ProcessEntry? {
        guard let row = contextRow, rows.indices.contains(row) else { return nil }
        return rows[row]
    }

    private func notify(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func terminate(_ entry: ProcessEntry, signal: Int32, force: Bool) {
        guard entry.pid > 1, entry.pid != getpid() else {
            notify("不能结束这个进程", "系统关键进程或 SystemPulse 自身不允许被结束。")
            return
        }
        if force {
            let alert = NSAlert()
            alert.messageText = "强制结束「\(entry.name)」？"
            alert.informativeText = "PID \(entry.pid) 会立即被终止（SIGKILL），未保存的数据可能丢失。系统进程可能因权限不足而无法结束。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "强制结束")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if kill(entry.pid, signal) != 0 {
            notify("结束失败", "系统返回错误：\(String(cString: strerror(errno)))（权限不足或进程已退出）")
        }
        contextRow = nil
        refresh()
    }

    @objc private func forceQuit(_ sender: Any) {
        guard let entry = contextEntry else { return }
        terminate(entry, signal: SIGKILL, force: true)
    }

    @objc private func gracefulQuit(_ sender: Any) {
        guard let entry = contextEntry else { return }
        terminate(entry, signal: SIGTERM, force: false)
    }

    private func reveal(_ path: String?) {
        guard let path = path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            notify("找不到位置", "该进程没有可用的可执行文件路径（可能是内核任务）。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func revealInFinder(_ sender: Any) {
        guard let entry = contextEntry else { return }
        reveal(entry.bundlePath ?? entry.executablePath)
    }

    @objc private func revealSelected(_ sender: Any) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        let entry = rows[row]
        reveal(entry.bundlePath ?? entry.executablePath)
    }

    @objc private func openApplication(_ sender: Any) {
        guard let bundle = contextEntry?.bundlePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: bundle))
    }

    @objc private func openContainingFolder(_ sender: Any) {
        guard let path = contextEntry?.executablePath, !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func copyName(_ sender: Any) {
        guard let entry = contextEntry else { return }
        copy(entry.name)
    }

    @objc private func copyPID(_ sender: Any) {
        guard let entry = contextEntry else { return }
        copy("\(entry.pid)")
    }

    @objc private func copyPath(_ sender: Any) {
        guard let entry = contextEntry else { return }
        copy(entry.executablePath)
    }

    @objc private func refreshNow(_ sender: Any) { refresh() }
}
