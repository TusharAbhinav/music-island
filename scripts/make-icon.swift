// Renders the app icon to a 1024px PNG: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let pink = rgb(0xFA2D48)
let coral = rgb(0xFF6A5C)
let violet = rgb(0x8E3BFF)

// Squircle on Apple's icon grid (824pt body on a 1024 canvas).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
rgb(0x0B0710).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()

// Base: deep plum fading to near-black.
NSGradient(colors: [rgb(0x1E0B24), rgb(0x07050A)])!.draw(in: body, angle: -90)

// Ambient glows, like the island's album-art wash.
func glow(_ color: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let g = NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])!
    g.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}
glow(pink, center: CGPoint(x: 360, y: 330), radius: 520, alpha: 0.55)
glow(violet, center: CGPoint(x: 760, y: 260), radius: 440, alpha: 0.45)
glow(coral, center: CGPoint(x: 512, y: 540), radius: 300, alpha: 0.18)

// Subtle top sheen.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: 100, y: 620, width: 824, height: 304), angle: -90)

// The island pill.
let pill = CGRect(x: 192, y: 432, width: 640, height: 190)
let pillPath = NSBezierPath(roundedRect: pill, xRadius: 95, yRadius: 95)

NSGraphicsContext.saveGraphicsState()
let pillShadow = NSShadow()
pillShadow.shadowColor = pink.withAlphaComponent(0.55)
pillShadow.shadowBlurRadius = 70
pillShadow.shadowOffset = .zero
pillShadow.set()
NSColor.black.setFill()
pillPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSColor.black.setFill()
pillPath.fill()
NSColor.white.withAlphaComponent(0.10).setStroke()
pillPath.lineWidth = 3
pillPath.stroke()

// Album tile on the left of the pill.
let art = CGRect(x: pill.minX + 42, y: pill.midY - 56, width: 112, height: 112)
let artPath = NSBezierPath(roundedRect: art, xRadius: 28, yRadius: 28)
NSGraphicsContext.saveGraphicsState()
artPath.addClip()
NSGradient(colors: [coral, pink, violet])!.draw(in: art, angle: -45)
NSGraphicsContext.restoreGraphicsState()

// Music note in the tile.
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 66, weight: .bold)) {
    let tinted = NSImage(size: note.size, flipped: false) { rect in
        note.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: CGRect(x: art.midX - s.width / 2, y: art.midY - s.height / 2, width: s.width, height: s.height))
}

// Level bars on the right of the pill.
let heights: [CGFloat] = [70, 118, 54, 96, 132 * 0.62]
let barWidth: CGFloat = 22, gap: CGFloat = 16
var x = pill.maxX - 48 - CGFloat(heights.count) * barWidth - CGFloat(heights.count - 1) * gap
let barGradient = NSGradient(colors: [pink, coral])!
for h in heights {
    let bar = CGRect(x: x, y: pill.midY - h / 2, width: barWidth, height: h)
    let barPath = NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
    barGradient.draw(in: barPath, angle: 90)
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()

// Hairline edge highlight on the squircle.
NSColor.white.withAlphaComponent(0.08).setStroke()
squircle.lineWidth = 2
squircle.stroke()

ctx.flush()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
