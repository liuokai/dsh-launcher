// 用 DeepSeek 官方鲸鱼 SVG 生成 DSH 应用图标
// Chrome 风格：纯白圆角背景 + 居中黑色鲸鱼（矢量渲染，各尺寸清晰）
// 用法: swift make_icon.swift <logo.svg> <输出iconset目录>
import AppKit

guard CommandLine.arguments.count > 2 else {
    print("usage: swift make_icon.swift <logo.svg> <iconset-dir>")
    exit(2)
}
let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

/// 鲸鱼在 SVG 画布中的实际宽高比（viewBox 50x50，路径 bbox 约 48.2 x 36.3）
let whaleAspect: CGFloat = 36.28 / 48.17

func render(px: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let f = CGFloat(px)

    // 白底圆角矩形（Chrome 式纯白 #FFFFFF，圆角 22.4%）
    let rect = NSRect(x: 0, y: 0, width: f, height: f)
    let radius = f * 0.224
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    bg.fill()

    // 居中绘制黑色鲸鱼（宽度占画布 74%）
    guard let whale = NSImage(contentsOf: svgURL) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    let whaleW = f * 0.74
    let whaleH = whaleW * whaleAspect
    whale.size = NSSize(width: whaleW, height: whaleH)
    whale.draw(in: NSRect(x: (f - whaleW) / 2, y: (f - whaleH) / 2,
                          width: whaleW, height: whaleH),
               from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in sizes {
    guard let rep = render(px: px),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAIL rendering \(name)")
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    do { try png.write(to: url) } catch {
        print("FAIL writing \(name): \(error)")
        exit(1)
    }
}
print("ICON OK \(outDir)")
