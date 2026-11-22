#!/usr/bin/env swift
import AppKit
import Foundation

// 生成 1024x1024 的 App 图标：明亮的蓝青渐变圆角底 + 纯白扬声器字形 + 玻璃高光。
let size = 1024
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
) else {
    FileHandle.standardError.write(Data("create bitmap failed\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = ctx

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let inset: CGFloat = 92
let body = rect.insetBy(dx: inset, dy: inset)
let path = NSBezierPath(roundedRect: body, xRadius: 210, yRadius: 210)

// 底色：顶部天空蓝 → 底部理智蓝，整体保持高亮度
let topColor = NSColor(srgbRed: 0.47, green: 0.80, blue: 1.00, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.20, green: 0.44, blue: 0.97, alpha: 1)
NSGradient(starting: topColor, ending: bottomColor)?.draw(in: path, angle: -90)

// 自下而上渐隐的白色高光，制造玻璃质感且不留接缝
if let highlight = NSGradient(colorsAndLocations:
    (NSColor(calibratedWhite: 1, alpha: 0.00), 0.00),
    (NSColor(calibratedWhite: 1, alpha: 0.02), 0.42),
    (NSColor(calibratedWhite: 1, alpha: 0.20), 0.88),
    (NSColor(calibratedWhite: 1, alpha: 0.26), 1.00)
) {
    highlight.draw(in: path, angle: -90)
}

// 边缘高光描边
NSColor(calibratedWhite: 1, alpha: 0.34).setStroke()
path.lineWidth = 5
path.stroke()

// 扬声器字形：用模板遮罩染成纯白，保证亮底上也清晰
if let symbol = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil),
   let configured = symbol.withSymbolConfiguration(
       NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
   ) {
    let symbolSize = configured.size
    let tinted = NSImage(size: symbolSize)
    tinted.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbolSize).fill()
    configured.draw(
        in: NSRect(origin: .zero, size: symbolSize),
        from: .zero,
        operation: .destinationIn,
        fraction: 1
    )
    tinted.unlockFocus()

    let target = NSRect(
        x: (CGFloat(size) - symbolSize.width) / 2,
        y: (CGFloat(size) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.05, green: 0.15, blue: 0.45, alpha: 0.30)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
