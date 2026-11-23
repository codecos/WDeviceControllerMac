#!/usr/bin/env swift
import AppKit
import Foundation

/// 全仓库唯一的图标画法：粉色圆角底 + 白色卡片 + 滑杆/旋钮。
///
/// 图形几何与 `Images/StoreLogo-v2.svg`（300×300 设计稿）逐点对应，两端的图标都由这里生成，
/// 避免 Mac 用扬声器、Windows 用滑杆这种不一致。
///
/// 用法：
///   swift make-icon.swift out.png                  生成 1024×1024 PNG（macOS 圆角样式）
///   swift make-icon.swift --icns Resources/AppIcon.icns
///   swift make-icon.swift --ico path/to/tray.ico [--sizes 16,20,24,32,40,48,64,128,256]

private let designSize: CGFloat = 300

private func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

private func line(_ path: NSBezierPath, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
    path.move(to: NSPoint(x: x1, y: y1))
    path.line(to: NSPoint(x: x2, y: y2))
}

/// 在设计稿坐标系（原点左上，300×300）里画内容。
private func drawArtwork(cornerRadius: CGFloat) {
    // 底色
    color(0xF8EFF2).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: designSize, height: designSize),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    ).fill()

    // 卡片
    let card = NSBezierPath(
        roundedRect: NSRect(x: 26, y: 62, width: 248, height: 176),
        xRadius: 24,
        yRadius: 24
    )
    NSColor.white.setFill()
    card.fill()
    color(0xD8C8CC).setStroke()
    card.lineWidth = 5
    card.stroke()

    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: UInt32, radius: CGFloat) {
        color(fill).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: w, height: h),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }

    func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ fill: UInt32) {
        color(fill).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
    }

    // 标题行
    bar(49, 88, 73, 10, 0x202124, radius: 5)
    bar(130, 91, 21, 5, 0x9A9295, radius: 2.5)
    bar(213, 88, 38, 10, 0x1989E8, radius: 5)

    // 主推子：深色轨道 + 蓝色已播放段 + 白芯旋钮
    let track = NSBezierPath()
    track.lineCapStyle = .round
    line(track, 49, 126, 177, 126)
    color(0x28292B).setStroke()
    track.lineWidth = 7
    track.stroke()

    let progress = NSBezierPath()
    progress.lineCapStyle = .round
    line(progress, 49, 126, 119, 126)
    color(0x147FCA).setStroke()
    progress.lineWidth = 7
    progress.stroke()

    dot(119, 126, 12, 0xFFFFFF)
    let knobRing = NSBezierPath(ovalIn: NSRect(x: 107, y: 114, width: 24, height: 24))
    color(0x147FCA).setStroke()
    knobRing.lineWidth = 5
    knobRing.stroke()

    // 右侧两枚排序/还原箭头
    let controls = NSBezierPath()
    controls.lineCapStyle = .round
    controls.lineJoinStyle = .round
    line(controls, 196, 116, 196, 136)
    line(controls, 187, 125, 196, 116)
    line(controls, 196, 116, 205, 125)
    line(controls, 196, 136, 205, 127)
    line(controls, 228, 164, 228, 188)
    line(controls, 218, 174, 228, 164)
    line(controls, 228, 164, 238, 174)
    line(controls, 228, 188, 238, 178)
    color(0x28292B).setStroke()
    controls.lineWidth = 5
    controls.stroke()

    // 音量行：灰轨道 + 三个彩色档位点
    let volume = NSBezierPath()
    volume.lineCapStyle = .round
    line(volume, 49, 176, 117, 176)
    line(volume, 135, 176, 180, 176)
    color(0xA39B9E).setStroke()
    volume.lineWidth = 7
    volume.stroke()
    dot(49, 176, 7, 0x28292B)
    dot(132, 176, 7, 0xF3B43D)
    dot(180, 176, 7, 0x66B66A)

    // 底部三条灰条
    bar(49, 204, 55, 7, 0xC9BEC2, radius: 3.5)
    bar(112, 204, 38, 7, 0xC9BEC2, radius: 3.5)
    bar(158, 204, 67, 7, 0xC9BEC2, radius: 3.5)
}

/// 小尺寸（托盘 16/20/24px）用的简化版：只留卡片、主推子和音量档位点。
/// 完整稿里的细线在 16px 下会糊成一团，简化版保证一眼能认出是同一枚图标。
private func drawCompactArtwork(cornerRadius: CGFloat) {
    color(0xF8EFF2).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: designSize, height: designSize),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    ).fill()

    let card = NSBezierPath(
        roundedRect: NSRect(x: 26, y: 46, width: 248, height: 208),
        xRadius: 40,
        yRadius: 40
    )
    NSColor.white.setFill()
    card.fill()

    let slider = NSBezierPath()
    slider.lineCapStyle = .round
    line(slider, 62, 126, 230, 126)
    color(0x28292B).setStroke()
    slider.lineWidth = 24
    slider.stroke()

    let progress = NSBezierPath()
    progress.lineCapStyle = .round
    line(progress, 62, 126, 168, 126)
    color(0x147FCA).setStroke()
    progress.lineWidth = 24
    progress.stroke()

    color(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: NSRect(x: 140, y: 98, width: 56, height: 56)).fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: 140, y: 98, width: 56, height: 56))
    color(0x147FCA).setStroke()
    ring.lineWidth = 12
    ring.stroke()

    let volume = NSBezierPath()
    volume.lineCapStyle = .round
    line(volume, 62, 190, 230, 190)
    color(0xA39B9E).setStroke()
    volume.lineWidth = 16
    volume.stroke()

    for (cx, fill) in [(62.0, UInt32(0x28292B)), (144.0, UInt32(0xF3B43D)), (222.0, UInt32(0x66B66A))] {
        color(fill).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - 16, y: 174, width: 32, height: 32)).fill()
    }
}

/// macOS 图标规范：1024 画布、824 的可视区、约 22% 圆角。Windows 侧则是满幅圆角方块。
private enum Style {
    case macApp
    case tile
}

private func renderPNG(pixelSize size: Int, style: Style) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let canvas = CGFloat(size)
    let inset = style == .macApp ? canvas * (100.0 / 1024.0) : 0
    let body = canvas - inset * 2
    let scale = body / designSize

    // 翻转成设计稿坐标（原点左上），之后所有数值都能直接照抄 SVG。
    let transform = NSAffineTransform()
    transform.translateX(by: inset, yBy: canvas - inset)
    transform.scaleX(by: scale, yBy: -scale)
    transform.concat()

    let radius = style == .macApp ? designSize * (185.0 / 824.0) : 56
    if size <= 24 {
        drawCompactArtwork(cornerRadius: radius)
    } else {
        drawArtwork(cornerRadius: radius)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - 输出

private func writePNG(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url)
}

private func writeICNS(_ path: String) throws {
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wdc-icon-\(ProcessInfo.processInfo.processIdentifier)")
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    // 每个尺寸单独渲染，比先出 1024 再缩更清晰。
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = base * scale
            guard let data = renderPNG(pixelSize: pixels, style: .macApp) else { exit(1) }
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try data.write(to: iconset.appendingPathComponent(name))
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed\n".utf8))
        exit(1)
    }
}

/// ICO 容器：每个尺寸存一张 PNG（Vista 起支持，Win10/11 原生按 DPI 选层）。
private func writeICO(_ path: String, sizes: [Int]) throws {
    var images: [(size: Int, png: Data)] = []
    for size in sizes.sorted() {
        guard let data = renderPNG(pixelSize: size, style: .tile) else { exit(1) }
        images.append((size, data))
    }

    var out = Data()
    out.append(contentsOf: [0, 0, 1, 0] as [UInt8])
    func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }
    func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }

    append16(images.count)
    var offset = 6 + 16 * images.count
    for image in images {
        out.append(UInt8(image.size >= 256 ? 0 : image.size))
        out.append(UInt8(image.size >= 256 ? 0 : image.size))
        out.append(0)
        out.append(0)
        append16(1)
        append16(32)
        append32(image.png.count)
        append32(offset)
        offset += image.png.count
    }
    for image in images { out.append(image.png) }

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try out.write(to: url)
}

// MARK: - 入口

private var arguments = Array(CommandLine.arguments.dropFirst())
private var sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
private var mode = "--png"
private var output: String?

while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--icns", "--ico":
        mode = argument
        output = arguments.first
        if output != nil { arguments.removeFirst() }
    case "--sizes":
        let value = arguments.first ?? ""
        if !value.isEmpty { arguments.removeFirst() }
        sizes = value.split(separator: ",").compactMap { Int($0) }
    default:
        output = argument
    }
}

guard let target = output else {
    FileHandle.standardError.write(Data("missing output path\n".utf8))
    exit(1)
}

switch mode {
case "--icns":
    try writeICNS(target)
case "--ico":
    try writeICO(target, sizes: sizes)
default:
    guard let data = renderPNG(pixelSize: 1024, style: .macApp) else { exit(1) }
    try writePNG(data, to: target)
}

print("wrote \(target)")
