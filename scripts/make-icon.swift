#!/usr/bin/env swift
import AppKit
import Foundation

// 生成 1024x1024 的 App 图标：深色圆角底 + 白色扬声器 SF Symbol。
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
let path = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
])
gradient?.draw(in: path, angle: -90)

NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
path.lineWidth = 3
path.stroke()

if let symbol = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    let symbolSize = configured.size
    let target = NSRect(
        x: (CGFloat(size) - symbolSize.width) / 2,
        y: (CGFloat(size) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    NSColor.white.set()
    configured.isTemplate = true
    configured.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
