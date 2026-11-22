import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the full-bleed 1024 px "Files" artwork: a blue gradient tile with a
// white folder wearing a simple friendly face. Original artwork; it borrows
// the classic Mac file manager's spirit, not Apple's Finder mark.
// Usage: swift draw-icon-artwork.swift Resources/AppIcon-artwork.png
// then tools/make-icon.sh masks it and builds AppIcon.icns.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift draw-icon-artwork.swift out.png") }
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot allocate bitmap")
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

// Background: full bleed, sky blue at the top to deep blue at the bottom.
ctx.drawLinearGradient(gradient([color(0.36, 0.74, 1.0), color(0.07, 0.42, 0.93)]),
                       start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
// A soft glow behind the folder.
ctx.drawRadialGradient(gradient([color(1, 1, 1, 0.28), color(1, 1, 1, 0)]),
                       startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])

// Folder geometry (origin bottom-left), inside the 864 px tile with margin.
let body = CGRect(x: 232, y: 270, width: 560, height: 400)
let radius: CGFloat = 54
let tab = CGRect(x: 232, y: 630, width: 230, height: 90)

// Back sheet and tab, a little darker than the front.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0.0, 0.12, 0.35, 0.35))
let back = CGMutablePath()
back.addRoundedRect(in: CGRect(x: body.minX, y: body.minY + 40, width: body.width, height: body.height),
                    cornerWidth: radius, cornerHeight: radius)
back.addRoundedRect(in: tab, cornerWidth: 40, cornerHeight: 40)
ctx.addPath(back)
ctx.setFillColor(color(0.84, 0.92, 1.0))
ctx.fillPath()
ctx.restoreGState()

// Front panel: white with a faint cool gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0.0, 0.12, 0.35, 0.25))
let front = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(front)
ctx.clip()
ctx.drawLinearGradient(gradient([color(1, 1, 1), color(0.90, 0.95, 1.0)]),
                       start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
ctx.restoreGState()

// The face: two rounded eyes and a smile, in the background's deep blue.
let ink = color(0.07, 0.36, 0.85)
ctx.setFillColor(ink)
for x in [CGFloat(420), 604] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x - 26, y: 470, width: 52, height: 96),
                       cornerWidth: 26, cornerHeight: 26, transform: nil))
}
ctx.fillPath()
ctx.setStrokeColor(ink)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 512, y: 452), radius: 118,
           startAngle: CGFloat.pi * 1.18, endAngle: CGFloat.pi * 1.82, clockwise: false)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot write artwork")
}
CGImageDestinationAddImage(out, image, nil)
guard CGImageDestinationFinalize(out) else { fatalError("Cannot write artwork") }
print("→ \(CommandLine.arguments[1])")
