// Zeichnet das App-Icon (1024×1024 PNG) mit CoreGraphics.
// Verwendung: swift scripts/make-icon.swift <ausgabe.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ c: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: c as CFArray, locations: nil)!
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// macOS-Icon-Raster: 824×824 Fläche, 100 px Rand, Eckradius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

// Schatten unter der Kachel
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(roundedRect(tile, 185))
ctx.setFillColor(color(0x101A30))
ctx.fillPath()
ctx.restoreGState()

// Hintergrund: dunkles Blau mit Verlauf
ctx.saveGState()
ctx.addPath(roundedRect(tile, 185))
ctx.clip()
ctx.drawLinearGradient(gradient([color(0x2B4A80), color(0x15233F), color(0x0B1224)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// dezenter Lichtschein oben
ctx.drawRadialGradient(gradient([color(0x6FA8FF, 0.28), color(0x6FA8FF, 0)]),
                       startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 900), endRadius: 560, options: [])
ctx.restoreGState()

// Feiner Rand
ctx.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), 183))
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(4)
ctx.strokePath()

// Drei Server-Einschübe
let unitW = 600.0, unitH = 150.0, gap = 34.0
let x0 = (size - unitW) / 2
let totalH = unitH * 3 + gap * 2
let yTop = (size + totalH) / 2 - unitH + 20
let leds: [UInt32] = [0x38E07B, 0x38E07B, 0xFFB340]

for i in 0..<3 {
    let r = CGRect(x: x0, y: yTop - Double(i) * (unitH + gap), width: unitW, height: unitH)

    // Gehäuse mit Metall-Verlauf und Schatten
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.5))
    ctx.addPath(roundedRect(r, 26))
    ctx.setFillColor(color(0xC9D2E0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(r, 26))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xF4F7FB), color(0xC3CCDA), color(0x9EA9BB)]),
                           start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.restoreGState()

    // Frontblende (dunkel)
    let face = r.insetBy(dx: 22, dy: 22)
    ctx.addPath(roundedRect(face, 14))
    ctx.setFillColor(color(0x1C2638))
    ctx.fillPath()

    // Laufwerksschächte
    let bayW = 74.0, bayH = face.height - 36
    for b in 0..<4 {
        let bay = CGRect(x: face.minX + 22 + Double(b) * (bayW + 14), y: face.minY + 18, width: bayW, height: bayH)
        ctx.addPath(roundedRect(bay, 7))
        ctx.setFillColor(color(0x2E3B54))
        ctx.fillPath()
        let handle = CGRect(x: bay.minX + 12, y: bay.midY - 4, width: bayW - 24, height: 8)
        ctx.addPath(roundedRect(handle, 4))
        ctx.setFillColor(color(0x55657F))
        ctx.fillPath()
    }

    // Lüftungsschlitze
    for s in 0..<5 {
        let sx = face.minX + 400 + Double(s) * 16
        ctx.addPath(roundedRect(CGRect(x: sx, y: face.minY + 22, width: 7, height: face.height - 44), 3.5))
        ctx.setFillColor(color(0x2E3B54))
        ctx.fillPath()
    }

    // Status-LED mit Leuchten
    let led = CGPoint(x: face.maxX - 34, y: face.midY)
    ctx.drawRadialGradient(gradient([color(leds[i], 0.85), color(leds[i], 0)]),
                           startCenter: led, startRadius: 0, endCenter: led, endRadius: 40, options: [])
    ctx.addEllipse(in: CGRect(x: led.x - 12, y: led.y - 12, width: 24, height: 24))
    ctx.setFillColor(color(leds[i]))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: led.x - 5, y: led.y + 1, width: 8, height: 8))
    ctx.setFillColor(color(0xFFFFFF, 0.7))
    ctx.fillPath()
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG konnte nicht geschrieben werden") }
print("Icon geschrieben: \(out.path)")
