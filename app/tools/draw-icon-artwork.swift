import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
// Draws the 1024 px "Files" artwork: one large blue folder that is the icon's
// whole silhouette, transparent around it, with a sheet of paper and a faint
// divider hinting at the two panes. Original artwork, not Apple's Finder mark.
// Usage: swift draw-icon-artwork.swift Resources/AppIcon-artwork.png
// then tools/make-icon.sh builds AppIcon.png and AppIcon.icns from it.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift draw-icon-artwork.swift out.png") }
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func grad(_ cs: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: cs as CFArray, locations: nil)! }
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
func fill(_ p: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
let shadow = c(0, 0.06, 0.25, 0.35)
// Back sheet with its tab.
let back = CGMutablePath()
back.addPath(rr(CGRect(x: 72, y: 150, width: 880, height: 660), 64))
back.addPath(rr(CGRect(x: 72, y: 740, width: 380, height: 140), 56))
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: shadow)
ctx.addPath(back); ctx.setFillColor(c(0.16, 0.46, 0.94)); ctx.fillPath(); ctx.restoreGState()
fill(back, grad([c(0.28, 0.58, 1.0), c(0.10, 0.38, 0.88)]), top: 880, bottom: 150)
// A sheet of paper peeking out.
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: c(0, 0.08, 0.3, 0.25))
ctx.addPath(rr(CGRect(x: 132, y: 500, width: 760, height: 270), 34)); ctx.setFillColor(c(0.96, 0.98, 1.0)); ctx.fillPath()
ctx.restoreGState()
// Front flap.
let front = rr(CGRect(x: 72, y: 150, width: 880, height: 570), 64)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: shadow)
ctx.addPath(front); ctx.setFillColor(c(0.3, 0.62, 1)); ctx.fillPath(); ctx.restoreGState()
fill(front, grad([c(0.50, 0.80, 1.0), c(0.20, 0.54, 0.99)]), top: 720, bottom: 150)
// Top highlight on the flap.
ctx.saveGState(); ctx.addPath(front); ctx.clip()
ctx.setFillColor(c(1, 1, 1, 0.45)); ctx.fill(CGRect(x: 72, y: 713, width: 880, height: 7))
ctx.restoreGState()
// A subtle embossed pane divider: two panes, one app.
ctx.setFillColor(c(0.06, 0.32, 0.82, 0.22))
ctx.addPath(rr(CGRect(x: 508, y: 260, width: 10, height: 340), 5)); ctx.fillPath()
ctx.setFillColor(c(1, 1, 1, 0.28))
ctx.addPath(rr(CGRect(x: 518, y: 260, width: 4, height: 340), 2)); ctx.fillPath()
let img = ctx.makeImage()!
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(out, img, nil); CGImageDestinationFinalize(out)
