import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the 1024 px "Files" artwork: the whole icon tile is a folder, filled
// edge to edge (navy back, a tab at the top left, a sheet of paper and a bright
// front flap with a faint divider hinting at the two panes). Original artwork,
// not Apple's Finder mark. tools/render-icon.swift clips it to the macOS icon
// shape (824 px, 100 px margins).
// Usage: swift draw-icon-artwork.swift Resources/AppIcon-artwork.png
// then tools/make-icon.sh builds AppIcon.png and AppIcon.icns from it.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift draw-icon-artwork.swift out.png") }
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot allocate bitmap")
}
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func grad(_ cs: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: cs as CFArray, locations: nil)! }
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
func fill(_ p: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
let shade = c(0, 0.08, 0.30, 0.45)

// The folder's back fills the tile.
fill(CGPath(rect: CGRect(x: 0, y: 0, width: size, height: size), transform: nil),
     grad([c(0.10, 0.30, 0.80), c(0.05, 0.18, 0.58)]), top: 924, bottom: 560)
// The tab at the top left, with the back showing above it.
let tab = rr(CGRect(x: 60, y: 640, width: 440, height: 230), 56)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: shade)
ctx.addPath(tab); ctx.setFillColor(c(0.24, 0.54, 0.98)); ctx.fillPath(); ctx.restoreGState()
fill(tab, grad([c(0.34, 0.64, 1.0), c(0.20, 0.50, 0.96)]), top: 870, bottom: 700)
// A sheet of paper peeking out above the flap.
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: c(0, 0.08, 0.3, 0.3))
ctx.addPath(rr(CGRect(x: 168, y: 520, width: 688, height: 240), 30)); ctx.setFillColor(c(0.96, 0.98, 1.0)); ctx.fillPath()
ctx.restoreGState()
// The front flap, edge to edge below the paper.
let flapTop: CGFloat = 700
let flap = rr(CGRect(x: -60, y: -200, width: CGFloat(size) + 120, height: flapTop + 200), 64)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: shade)
ctx.addPath(flap); ctx.setFillColor(c(0.3, 0.6, 1)); ctx.fillPath(); ctx.restoreGState()
fill(flap, grad([c(0.52, 0.81, 1.0), c(0.16, 0.50, 0.98)]), top: flapTop, bottom: 100)
ctx.setFillColor(c(1, 1, 1, 0.5)); ctx.fill(CGRect(x: 0, y: flapTop - 7, width: CGFloat(size), height: 7))
// A faint embossed divider: two panes, one app.
ctx.setFillColor(c(0.06, 0.32, 0.82, 0.22)); ctx.addPath(rr(CGRect(x: 507, y: 230, width: 10, height: 380), 5)); ctx.fillPath()
ctx.setFillColor(c(1, 1, 1, 0.28)); ctx.addPath(rr(CGRect(x: 517, y: 230, width: 4, height: 380), 2)); ctx.fillPath()

guard let image = ctx.makeImage(),
      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot write artwork")
}
CGImageDestinationAddImage(out, image, nil)
guard CGImageDestinationFinalize(out) else { fatalError("Cannot write artwork") }
print("→ \(CommandLine.arguments[1])")
