import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Legacy ICNS consumers draw the supplied pixels, so export the silhouette
// and transparent padding explicitly instead of relying on system masking.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift render-icon.swift artwork.png AppIcon.png")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else {
    fatalError("Icon artwork must be a decodable square image")
}
let size = 1024
guard let context = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot allocate icon bitmap")
}
context.clear(CGRect(x: 0, y: 0, width: size, height: size))
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.interpolationQuality = .high
// The artwork carries its own silhouette (a folder) and transparent padding,
// so it is drawn as is, without clipping it to a rounded tile.
context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create icon output")
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon PNG") }
