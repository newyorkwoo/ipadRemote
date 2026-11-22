// 產生兩個 App 的圖示（1024×1024 原始圖）。一般請執行 Tools/make-app-icons.sh，會輸出各尺寸到 Assets.xcassets
//
// • iPad App「遠端 Mac」：藍紫漸層滿版背景，白色 Mac 螢幕，螢幕上一個游標與點擊波紋
//   （iPadOS 會自動套上圓角遮罩，所以畫滿整張）
// • Mac App「iPad Remote Agent」：macOS 標準圓角方形（824 / 1024，含陰影），白色橫放 iPad，
//   螢幕上是觸控點與波紋 —— 兩個圖示同一個色系與波紋語彙，一看就知道是一組
//
// 用法：swift Tools/make-app-icons.swift <輸出資料夾>（或執行 Tools/make-app-icons.sh）

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

/// opaque：iOS 圖示不可有透明通道（App Store 會拒絕）；macOS 圖示需要透明背景
func makeContext(opaque: Bool) -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: alpha.rawValue)!
    // 改成左上角為原點、y 向下，方便用設計稿座標
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func save(_ ctx: CGContext, to url: URL) {
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "寫入失敗：\(url.path)")
}

func linearFill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, clip: CGPath, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha), color(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func withShadow(_ ctx: CGContext, blur: CGFloat, offsetY: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    ctx.saveGState()
    // 座標系已翻轉，陰影的 y 位移也要反過來
    ctx.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur, color: color(0x0B0A2A, alpha))
    draw()
    ctx.restoreGState()
}

/// 波紋：以 center 為圓心的同心圓弧（或整圈）
func ripples(_ ctx: CGContext, center: CGPoint, radii: [CGFloat], alphas: [CGFloat], width: CGFloat,
             start: CGFloat = 0, end: CGFloat = 2 * .pi) {
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    for (radius, alpha) in zip(radii, alphas) {
        ctx.setStrokeColor(color(0xFFFFFF, alpha))
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

let brandTop = color(0x5AA2FF)
let brandBottom = color(0x4A2BC9)
let screenTop = color(0x1A2150)
let screenBottom = color(0x2F3C93)

// MARK: - iPad App：Mac 螢幕 + 游標

func drawIPadAppIcon() -> CGContext {
    let ctx = makeContext(opaque: true)
    let full = CGPath(rect: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
    linearFill(ctx, full, [brandTop, brandBottom], from: CGPoint(x: 120, y: 0), to: CGPoint(x: 904, y: 1024))
    glow(ctx, clip: full, center: CGPoint(x: 260, y: 180), radius: 720, alpha: 0.22)

    // 螢幕外框 + 支架（同一個陰影）
    let body = rounded(CGRect(x: 197, y: 262, width: 630, height: 410), 58)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 462, y: 668))
    neck.addLine(to: CGPoint(x: 562, y: 668))
    neck.addLine(to: CGPoint(x: 584, y: 752))
    neck.addLine(to: CGPoint(x: 440, y: 752))
    neck.closeSubpath()
    let base = rounded(CGRect(x: 372, y: 744, width: 280, height: 36), 18)
    withShadow(ctx, blur: 46, offsetY: 22, alpha: 0.35) {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.addPath(body); ctx.addPath(neck); ctx.addPath(base)
        ctx.fillPath()
    }
    // 支架接縫處的淡陰影，讓支架看起來在螢幕後面
    linearFill(ctx, neck, [color(0xC9CFF0), color(0xF2F4FF)], from: CGPoint(x: 0, y: 668), to: CGPoint(x: 0, y: 700))

    // 螢幕
    let screenRect = CGRect(x: 229, y: 294, width: 566, height: 346)
    let screen = rounded(screenRect, 30)
    linearFill(ctx, screen, [screenTop, screenBottom], from: CGPoint(x: 0, y: 294), to: CGPoint(x: 0, y: 640))
    glow(ctx, clip: screen, center: CGPoint(x: 330, y: 300), radius: 420, alpha: 0.10)

    // 點擊波紋 + 游標
    let tip = CGPoint(x: 462, y: 425)
    ctx.saveGState()
    ctx.addPath(screen); ctx.clip()
    ripples(ctx, center: tip, radii: [46, 82, 118], alphas: [0.9, 0.55, 0.28], width: 14,
            start: .pi * 1.05, end: .pi * 1.62)
    ctx.restoreGState()

    let s: CGFloat = 1.1
    let arrow: [CGPoint] = [(0, 0), (0, 152), (36, 118), (62, 176), (90, 164), (64, 108), (112, 108)]
        .map { CGPoint(x: tip.x + $0.0 * s, y: tip.y + $0.1 * s) }
    let cursor = CGMutablePath()
    cursor.addLines(between: arrow)
    cursor.closeSubpath()
    withShadow(ctx, blur: 14, offsetY: 6, alpha: 0.45) {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.addPath(cursor)
        ctx.fillPath()
    }
    ctx.setStrokeColor(color(0x1A2150))
    ctx.setLineWidth(9)
    ctx.setLineJoin(.round)
    ctx.addPath(cursor)
    ctx.strokePath()
    return ctx
}

// MARK: - Mac App：iPad + 觸控點

func drawMacAgentIcon() -> CGContext {
    let ctx = makeContext(opaque: false)
    // macOS 圖示格線：824×824 圓角方形置中，留空間給陰影
    let tile = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    withShadow(ctx, blur: 30, offsetY: 14, alpha: 0.35) {
        ctx.setFillColor(brandBottom)
        ctx.addPath(tile)
        ctx.fillPath()
    }
    linearFill(ctx, tile, [brandTop, brandBottom], from: CGPoint(x: 200, y: 100), to: CGPoint(x: 824, y: 924))
    glow(ctx, clip: tile, center: CGPoint(x: 300, y: 230), radius: 640, alpha: 0.22)
    ctx.saveGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.addPath(rounded(CGRect(x: 101.5, y: 101.5, width: 821, height: 821), 184))
    ctx.strokePath()
    ctx.restoreGState()

    // 橫放的 iPad
    let body = rounded(CGRect(x: 222, y: 300, width: 580, height: 424), 62)
    withShadow(ctx, blur: 40, offsetY: 20, alpha: 0.38) {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.addPath(body)
        ctx.fillPath()
    }
    let screen = rounded(CGRect(x: 252, y: 330, width: 520, height: 364), 36)
    linearFill(ctx, screen, [screenTop, screenBottom], from: CGPoint(x: 0, y: 330), to: CGPoint(x: 0, y: 694))
    glow(ctx, clip: screen, center: CGPoint(x: 340, y: 340), radius: 400, alpha: 0.10)
    // 前鏡頭（橫放時在上緣中央）
    ctx.setFillColor(color(0xB9C0E6))
    ctx.fillEllipse(in: CGRect(x: 506, y: 309, width: 12, height: 12))

    // 觸控點 + 波紋
    let touch = CGPoint(x: 512, y: 512)
    ctx.saveGState()
    ctx.addPath(screen); ctx.clip()
    ripples(ctx, center: touch, radii: [74, 116, 158], alphas: [0.75, 0.42, 0.2], width: 14)
    ctx.restoreGState()
    withShadow(ctx, blur: 16, offsetY: 6, alpha: 0.4) {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: touch.x - 38, y: touch.y - 38, width: 76, height: 76))
    }
    return ctx
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
save(drawIPadAppIcon(), to: out.appendingPathComponent("ipad-1024.png"))
save(drawMacAgentIcon(), to: out.appendingPathComponent("mac-1024.png"))
print("icons written to", out.path)
