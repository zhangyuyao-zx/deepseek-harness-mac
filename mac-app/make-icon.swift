import AppKit

// 生成 1024x1024 应用图标：深蓝渐变圆角底 + 白色鲸鱼剪影
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out/icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)

// 背景：圆角矩形 + 垂直渐变（DeepSeek 蓝）
let bg = NSBezierPath(roundedRect: canvas.insetBy(dx: 36, dy: 36), xRadius: 228, yRadius: 228)
if let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.45, green: 0.58, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.82, alpha: 1),
]) {
    grad.draw(in: bg, angle: -90)
}

// 鲸鱼剪影（面朝右）
let whale = NSBezierPath()
// 下巴 → 额头
whale.move(to: NSPoint(x: 240, y: 566))
whale.curve(to: NSPoint(x: 258, y: 478),
            controlPoint1: NSPoint(x: 205, y: 525),
            controlPoint2: NSPoint(x: 228, y: 492))
// 额头 → 背部
whale.curve(to: NSPoint(x: 468, y: 428),
            controlPoint1: NSPoint(x: 320, y: 448),
            controlPoint2: NSPoint(x: 400, y: 420))
// 长背 → 尾柄
whale.curve(to: NSPoint(x: 764, y: 462),
            controlPoint1: NSPoint(x: 596, y: 414),
            controlPoint2: NSPoint(x: 684, y: 448))
// 上尾鳍
whale.curve(to: NSPoint(x: 856, y: 372),
            controlPoint1: NSPoint(x: 792, y: 462),
            controlPoint2: NSPoint(x: 806, y: 404))
whale.curve(to: NSPoint(x: 826, y: 468),
            controlPoint1: NSPoint(x: 886, y: 410),
            controlPoint2: NSPoint(x: 852, y: 448))
// 下尾鳍
whale.curve(to: NSPoint(x: 862, y: 598),
            controlPoint1: NSPoint(x: 846, y: 500),
            controlPoint2: NSPoint(x: 868, y: 560))
whale.curve(to: NSPoint(x: 782, y: 546),
            controlPoint1: NSPoint(x: 852, y: 616),
            controlPoint2: NSPoint(x: 810, y: 566))
// 腹部 → 回到下巴
whale.curve(to: NSPoint(x: 392, y: 616),
            controlPoint1: NSPoint(x: 652, y: 646),
            controlPoint2: NSPoint(x: 520, y: 646))
whale.curve(to: NSPoint(x: 240, y: 566),
            controlPoint1: NSPoint(x: 320, y: 606),
            controlPoint2: NSPoint(x: 270, y: 584))
whale.close()
NSColor.white.setFill()
whale.fill()

// 眼睛（深蓝）
let eye = NSBezierPath(ovalIn: NSRect(x: 302, y: 498, width: 26, height: 26))
NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.78, alpha: 1).setFill()
eye.fill()

// 尾鳍旁的气泡
let bubble1 = NSBezierPath(ovalIn: NSRect(x: 908, y: 620, width: 40, height: 40))
NSColor.white.withAlphaComponent(0.85).setFill()
bubble1.fill()
let bubble2 = NSBezierPath(ovalIn: NSRect(x: 950, y: 560, width: 22, height: 22))
NSColor.white.withAlphaComponent(0.6).setFill()
bubble2.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let url = URL(fileURLWithPath: out)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: url)
print("saved \(out)")
