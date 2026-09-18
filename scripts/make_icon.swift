import AppKit
//
// make_icon.swift — ocoreai app icon generator (Apple-toolchain only, no 3rd-party).
//
// Design (first principles):
//   "o-core-ai" = an AI core at the center of the product's "o".
//   • Deep navy tile + bright cyan core — high contrast at 16px (Dock) and 512px (About box).
//   • Concentric rings = execution loop; bright center dot = local model core.
//   • A single "agent" node on the outer ring = the computer/agent identity.
//   • No text → scales cleanly. Cyan #2CC7EE deliberately NOT the system blue accent.
//
import CoreGraphics

let S: CGFloat = 1024
let CS = CGColorSpaceCreateDeviceRGB()
guard
    let ctx = CGContext(
        data: nil, width: Int(S), height: Int(S),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CS,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("ctx") }
// NOTE: no coordinate flipping — we draw in the natural CG bottom-left space.
// "center" = (S/2, S/2) in either convention.

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
func fill(_ rect: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addEllipse(in: rect)
    ctx.fillPath()
}
func strokeCircle(_ rect: CGRect, _ w: CGFloat, _ color: CGColor) {
    ctx.addEllipse(in: rect)
    ctx.setLineWidth(w)
    ctx.setStrokeColor(color)
    ctx.strokePath()
}

// MARK: - Canvas: transparent (Apple icons keep the corners transparent; the app
// itself draws a tile only when it fills the rounded-rect area).
// → for our mark: navy rounded-square tile + mark on top, over a transparent canvas.

// MARK: - Tile (rounded square, subtle vertical depth via 2 stacked rects + a sheen band)
let inset: CGFloat = 64
let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let rad: CGFloat = 220
let tilePath = CGPath(roundedRect: tile, cornerWidth: rad, cornerHeight: rad, transform: nil)

// clip mark to tile so nothing bleeds
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// base tile: deep navy
ctx.setFillColor(rgb(0x0F, 0x1B, 0x2E))
ctx.addPath(tilePath)
ctx.fillPath()

// sheen (upper 40% slightly lighter) — clip to tile, fill upper rect
ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, 0.05))
ctx.fill(
    CGRect(
        x: inset, y: S - inset - (S - inset * 2) * 0.42, width: S - inset * 2,
        height: (S - inset * 2) * 0.42))

// subtle bottom shadow inside tile (for depth)
ctx.setFillColor(rgb(0x00, 0x00, 0x00, 0.18))
ctx.fill(CGRect(x: inset, y: inset, width: S - inset * 2, height: (S - inset * 2) * 0.18))

// MARK: - Core mark (centered)
let c = S / 2
let cyan = rgb(0x2C, 0xC7, 0xEE)
let cyanBright = rgb(0x9B, 0xEE, 0xFB)
let cyanSoft = rgb(0x3E, 0xE0, 0xF5, 0.55)

// outer ring
strokeCircle(CGRect(x: c - 312, y: c - 312, width: 624, height: 624), 64, cyan)

// agent node (upper right on ring gap) — navy gap, then bright node
let ang: CGFloat = .pi / 4  // CG y-axis up → visual "top"
let nx = c + 312 * cos(ang)
let ny = c + 312 * sin(ang)
fill(CGRect(x: nx - 46, y: ny - 46, width: 92, height: 92), rgb(0x0F, 0x1B, 0x2E))
fill(CGRect(x: nx - 32, y: ny - 32, width: 64, height: 64), cyanBright)

// inner ring (thin, softer color)
strokeCircle(CGRect(x: c - 192, y: c - 192, width: 384, height: 384), 18, cyanSoft)

// core (bright dot, crisp edge — no gradient to avoid infinite-extend hazard)
fill(CGRect(x: c - 128, y: c - 128, width: 256, height: 256), cyanBright)

// glow halo around core (soft ring, not a fill)
strokeCircle(CGRect(x: c - 146, y: c - 146, width: 292, height: 292), 5, rgb(0x2C, 0xC7, 0xEE, 0.4))

ctx.restoreGState()

// MARK: - PNG out
guard let img = ctx.makeImage() else { fatalError("img") }
let out = URL(fileURLWithPath: "build/AppIcon.src.png")
try! FileManager.default.createDirectory(
    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: img)
rep.size = NSSize(width: 1024, height: 1024)
let pngData = rep.representation(using: .png, properties: [:])!
try! pngData.write(to: out)
print("wrote \(out.path) (1024x1024 RGBA PNG, \(pngData.count) bytes)")
