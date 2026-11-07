// SystemPulse 应用图标生成器（纯 CoreGraphics，不依赖任何第三方库 / 素材）
//
//   swiftc -O tools/MakeAppIcon/main.swift -o .build/makeicon
//   .build/makeicon --all-previews design/previews
//   .build/makeicon --style chip --png design/AppIcon-1024.png
//   .build/makeicon --style chip --iconset design/AppIcon.iconset
//
// 三款风格：
//   chip    芯片 · 玻璃   —— 沿用「芯片 + 三条走势线」概念，适配 macOS 圆角方形
//   pulse   三色脉冲      —— 与悬浮窗界面完全一致的红 / 青 / 紫三条走势线
//   minimal 极简心跳      —— 蓝色渐变 + 单条粗波形，小尺寸辨识度最高
//
// 16 / 32 / 64 像素档会自动去掉网格、引脚等细节并加粗主波形，保证缩到菜单栏也不糊。

import AppKit
import CoreGraphics
import Foundation

struct MakeAppIcon {
    enum Style: String, CaseIterable {
        case chip, pulse, minimal
    }

    static func main() {
        let args = CommandLine.arguments
        var style: Style = .chip
        var iconsetPath: String?
        var pngPath: String?
        var previewDir: String?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--style":
                if index + 1 < args.count, let value = Style(rawValue: args[index + 1]) {
                    style = value
                    index += 1
                }
            case "--iconset":
                if index + 1 < args.count { iconsetPath = args[index + 1]; index += 1 }
            case "--png":
                if index + 1 < args.count { pngPath = args[index + 1]; index += 1 }
            case "--all-previews":
                if index + 1 < args.count { previewDir = args[index + 1]; index += 1 }
            default:
                break
            }
            index += 1
        }

        let fm = FileManager.default
        if let dir = previewDir {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for candidate in Style.allCases {
                let path = "\(dir)/icon-\(candidate.rawValue).png"
                try? render(style: candidate, pixels: 1024).write(to: URL(fileURLWithPath: path))
                print("预览: \(path)")
            }
        }
        if let path = pngPath {
            try? render(style: style, pixels: 1024).write(to: URL(fileURLWithPath: path))
            print("预览: \(path)")
        }
        if let dir = iconsetPath {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let entries: [(String, Int)] = [
                ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
            ]
            for (name, pixels) in entries {
                let path = "\(dir)/\(name)"
                try? render(style: style, pixels: pixels).write(to: URL(fileURLWithPath: path))
            }
            print("iconset: \(dir)（\(entries.count) 档）")
        }
    }

    // MARK: - 渲染

    private static func render(style: Style, pixels: Int) -> Data {
        let scale = CGFloat(pixels) / 1024
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Data()
        }
        ctx.scaleBy(x: scale, y: scale)
        // 把原点翻到左上角，后面全部按 1024×1024 的屏幕坐标书写
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        draw(style: style, in: ctx, compact: pixels <= 64)
        guard let image = ctx.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    private struct Series {
        let color: CGColor
        let width: CGFloat
        let points: [CGPoint]
    }

    private static func draw(style: Style, in ctx: CGContext, compact: Bool) {
        let body = CGRect(x: 96, y: 96, width: 832, height: 832)
        let shape = CGPath(roundedRect: body, cornerWidth: 188, cornerHeight: 188, transform: nil)

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()

        // 底色：深色玻璃 / 明亮蓝
        let backgroundColors: [CGColor]
        switch style {
        case .minimal:
            backgroundColors = [rgb(0.13, 0.67, 0.93), rgb(0.03, 0.31, 0.62)]
        case .pulse:
            backgroundColors = [rgb(0.085, 0.135, 0.24), rgb(0.025, 0.045, 0.09)]
        case .chip:
            backgroundColors = [rgb(0.105, 0.205, 0.38), rgb(0.035, 0.075, 0.15)]
        }
        ctx.drawLinearGradient(gradient(backgroundColors),
                               start: CGPoint(x: 96, y: 96), end: CGPoint(x: 928, y: 928),
                               options: [])

        // 右上角冷光（startRadius 必须为 0，否则 CoreGraphics 会在中心留一个实心圆盘）
        ctx.drawRadialGradient(
            gradient([rgb(0.08, 0.60, 0.88, style == .minimal ? 0.20 : 0.38),
                      rgb(0.08, 0.60, 0.88, 0)]),
            startCenter: CGPoint(x: 800, y: 190), startRadius: 0,
            endCenter: CGPoint(x: 800, y: 190), endRadius: 660, options: [])

        // 顶部玻璃高光
        ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.16), rgb(1, 1, 1, 0)]),
                               start: CGPoint(x: 512, y: 96), end: CGPoint(x: 512, y: 580),
                               options: [])

        if !compact && style != .minimal {
            drawGrid(in: ctx)
        }
        if style == .chip {
            drawChipFrame(in: ctx, compact: compact)
        }

        let series = makeSeries(style: style, compact: compact)

        // 走势线
        for line in series {
            ctx.saveGState()
            if !compact {
                ctx.setShadow(offset: .zero, blur: 26,
                              color: line.color.copy(alpha: 0.72))
            }
            ctx.setStrokeColor(line.color)
            ctx.setLineWidth(compact ? line.width * 1.5 : line.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path(of: line.points))
            ctx.strokePath()
            ctx.restoreGState()

            if !compact, let end = line.points.last {
                ctx.setFillColor(line.color.copy(alpha: 0.35)!)
                ctx.addEllipse(in: CGRect(x: end.x - 17, y: end.y - 17, width: 34, height: 34))
                ctx.fillPath()
                ctx.setFillColor(rgb(1, 1, 1, 0.96))
                ctx.addEllipse(in: CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16))
                ctx.fillPath()
            }
        }

        ctx.restoreGState()

        // 外描边，让图标在浅色 Dock 上也有清晰轮廓
        ctx.setStrokeColor(rgb(1, 1, 1, style == .minimal ? 0.26 : 0.18))
        ctx.setLineWidth(4)
        ctx.addPath(shape)
        ctx.strokePath()
    }

    // MARK: - 元素

    private static func drawGrid(in ctx: CGContext) {
        ctx.setStrokeColor(rgb(1, 1, 1, 0.055))
        ctx.setLineWidth(2)
        for index in 1...5 {
            let y = 96 + 832 * CGFloat(index) / 6
            ctx.addLines(between: [CGPoint(x: 96, y: y), CGPoint(x: 928, y: y)])
        }
        for index in 1...7 {
            let x = 96 + 832 * CGFloat(index) / 8
            ctx.addLines(between: [CGPoint(x: x, y: 96), CGPoint(x: x, y: 928)])
        }
        ctx.strokePath()
    }

    private static func drawChipFrame(in ctx: CGContext, compact: Bool) {
        let inner = CGRect(x: 212, y: 212, width: 600, height: 600)
        ctx.setStrokeColor(rgb(0.32, 0.73, 0.96, 0.55))
        ctx.setLineWidth(9)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 44, cornerHeight: 44, transform: nil))
        ctx.strokePath()
        if compact { return }

        // 每边 5 根简化引脚（原图每边 16 根，缩到 16px 会糊成实线）
        ctx.setFillColor(rgb(0.36, 0.79, 0.99, 0.9))
        for center in [292, 402, 512, 622, 732] as [CGFloat] {
            let rects = [
                CGRect(x: center - 7, y: 166, width: 14, height: 50),
                CGRect(x: center - 7, y: 808, width: 14, height: 50),
                CGRect(x: 166, y: center - 7, width: 50, height: 14),
                CGRect(x: 808, y: center - 7, width: 50, height: 14)
            ]
            for rect in rects {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
            }
        }
        ctx.fillPath()

        // 四角装饰点
        ctx.setFillColor(rgb(0.58, 0.89, 1.0, 0.85))
        for point in [(250, 250), (774, 250), (250, 774), (774, 774)] {
            ctx.addEllipse(in: CGRect(x: CGFloat(point.0) - 13, y: CGFloat(point.1) - 13,
                                      width: 26, height: 26))
        }
        ctx.fillPath()
    }

    private static func makeSeries(style: Style, compact: Bool) -> [Series] {
        let cpu = rgb(1.0, 0.36, 0.43)     // 与悬浮窗 CPU 折线同色
        let memory = rgb(0.21, 0.84, 0.76) // 内存
        let temperature = rgb(0.66, 0.55, 0.98) // 温度

        // 小于 64px 时只保留一条居中的粗波形，缩到菜单栏尺寸仍清晰
        if compact {
            let shape = points([
                (150, 512), (250, 512), (320, 512), (385, 300),
                (455, 730), (525, 512), (630, 512), (700, 420),
                (770, 600), (874, 512)])
            return [Series(color: rgb(0.93, 0.98, 1.0), width: 68, points: shape)]
        }

        switch style {
        case .chip:
            return [
                Series(color: cpu, width: 26, points: points([
                    (250, 360), (320, 360), (365, 360), (405, 268), (450, 446),
                    (492, 360), (560, 360), (610, 318), (660, 404), (710, 336), (774, 360)])),
                Series(color: memory, width: 22, points: points([
                    (250, 520), (330, 498), (410, 540), (490, 494), (570, 534),
                    (650, 500), (730, 538), (774, 520)])),
                Series(color: temperature, width: 22, points: points([
                    (250, 680), (335, 664), (420, 692), (505, 660), (590, 688),
                    (675, 662), (774, 680)]))
            ]
        case .pulse:
            return [
                Series(color: cpu, width: 30, points: points([
                    (160, 350), (250, 350), (310, 350), (365, 218), (425, 482),
                    (485, 350), (570, 350), (630, 280), (690, 410), (760, 328), (864, 350)])),
                Series(color: memory, width: 26, points: points([
                    (160, 530), (270, 504), (380, 552), (490, 498), (600, 548),
                    (710, 500), (864, 528)])),
                Series(color: temperature, width: 26, points: points([
                    (160, 708), (280, 690), (400, 716), (520, 684), (640, 712),
                    (760, 688), (864, 706)]))
            ]
        case .minimal:
            return [
                Series(color: rgb(1, 1, 1, 0.97), width: 56, points: points([
                    (150, 512), (255, 512), (330, 512), (395, 292), (470, 736),
                    (545, 512), (650, 512), (705, 424), (770, 604), (874, 512)]))
            ]
        }
    }

    // MARK: - 工具

    private static func points(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] {
        values.map { CGPoint(x: $0.0, y: $0.1) }
    }

    private static func path(of points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: colors as CFArray,
                   locations: colors.count == 2 ? [0, 1] : [0, 0.5, 1])!
    }
}

MakeAppIcon.main()
