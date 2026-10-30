/// Turns a supplied illustration into the Energy tab's figure: crop to the body, pale line art.
///
/// **Run by hand, never by the app.** The output is a committed resource
/// (`Data/Resources/Energy/body.png`), and the source is an illustration the owner supplied — a JPEG
/// on a white background, which would be a bright rectangle on a dark card and would carry skin tones
/// into a screen that has no business showing them.
///
/// The transform is two steps and no options: crop to the bounding box of anything that is not paper
/// white, then map ink density to alpha on a cool light neutral so the outlines read and the body's
/// fill is a whisper. **The landmark table printed at the end is what `EnergyFlowMapView.Mark` is
/// measured from**, so a different figure means running this and re-reading those fractions rather
/// than nudging numbers until the overlay looks right.
///
/// Usage:  swiftc -O scripts/prepare-energy-figure.swift -o /tmp/bodyart && /tmp/bodyart <src> <dst>
///
/// It is Swift rather than Python because this machine has no image library installed, and Core
/// Graphics is already here.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: src dst\n".utf8)); exit(2) }
let src = URL(fileURLWithPath: args[1])
let dst = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }

let w = image.width, h = image.height
var rgba = [UInt8](repeating: 255, count: w * h * 4)
guard let ctx = CGContext(
    data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

func luminance(_ i: Int) -> Double {
    (0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2])) / 255.0
}

// Bounding box of anything that is not paper-white.
var minX = w, maxX = -1, minY = h, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        if luminance(i) < 0.965 { 
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
// Pad a little so the outline is not tight to the edge.
let pad = 6
minX = max(0, minX - pad); maxX = min(w - 1, maxX + pad)
minY = max(0, minY - pad); maxY = min(h - 1, maxY + pad)
let cw = maxX - minX + 1, ch = maxY - minY + 1

// Pale line art: alpha from ink density, colour a cool light neutral.
var out = [UInt8](repeating: 0, count: cw * ch * 4)
for y in 0..<ch {
    for x in 0..<cw {
        let si = ((y + minY) * w + (x + minX)) * 4
        let l = luminance(si)
        // White -> fully transparent; the figure's fill -> a faint wash; outlines -> solid.
        var a = (1.0 - l) * 1.12
        a = min(1.0, max(0.0, a))
        // Keep a whisper of the body's fill so the silhouette reads without becoming a slab.
        if a > 0.02 { a = max(0.10, a) }
        let r = 0.80, g = 0.84, b = 0.90
        let di = (y * cw + x) * 4
        out[di]     = UInt8(r * a * 255)
        out[di + 1] = UInt8(g * a * 255)
        out[di + 2] = UInt8(b * a * 255)
        out[di + 3] = UInt8(a * 255)
    }
}

guard let outCtx = CGContext(
    data: &out, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let outImage = outCtx.makeImage() else { exit(1) }

guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }

// Landmarks the overlay is positioned against, as fractions of the cropped box.
func rowSpan(_ y: Int) -> (Int, Int) {
    var lo = cw, hi = -1
    for x in 0..<cw where out[(y * cw + x) * 4 + 3] > 40 {
        if x < lo { lo = x }; if x > hi { hi = x }
    }
    return (lo, hi)
}
print("size=\(cw)x\(ch) aspect=\(Double(cw) / Double(ch))")
for f in [0.02, 0.05, 0.10, 0.14, 0.18, 0.22, 0.30, 0.40, 0.50, 0.60, 0.75, 0.90, 0.98] {
    let y = min(ch - 1, Int(Double(ch) * f))
    let (lo, hi) = rowSpan(y)
    print(String(format: "y=%.2f span %.3f..%.3f", f, Double(lo) / Double(cw), Double(hi) / Double(cw)))
}
