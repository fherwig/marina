// Marina app icon generator — old-fashioned ship's wheel on a navy squircle.
// Usage: swift gen-icon.swift <output.png>   (renders the 1024×1024 master)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "marina-icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon squircle with the standard ~100px transparent margin
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.34, alpha: 1),  // deep sea
    NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.70, alpha: 1)   // harbour blue
])?.draw(in: rect, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

// the wheel, white
let c = NSPoint(x: size / 2, y: size / 2)
NSColor.white.setStroke()
NSColor.white.setFill()

func ring(radius: CGFloat, lineWidth: CGFloat) {
    let p = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                        width: 2 * radius, height: 2 * radius))
    p.lineWidth = lineWidth
    p.stroke()
}

// rim: broad outer ring with a thin inner companion
ring(radius: 228, lineWidth: 42)
ring(radius: 177, lineWidth: 15)

// hub with a sea-blue centre hole
NSBezierPath(ovalIn: NSRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124)).fill()
NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.52, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 24, y: c.y - 24, width: 48, height: 48)).fill()
NSColor.white.setFill()

// eight spokes, each continuing past the rim into a turned handle with knob
for i in 0..<8 {
    let a = CGFloat(i) * .pi / 4
    let dx = cos(a), dy = sin(a)

    let spoke = NSBezierPath()
    spoke.lineWidth = 30
    spoke.lineCapStyle = .round
    spoke.move(to: NSPoint(x: c.x + dx * 48, y: c.y + dy * 48))
    spoke.line(to: NSPoint(x: c.x + dx * 228, y: c.y + dy * 228))
    spoke.stroke()

    let handle = NSBezierPath()
    handle.lineWidth = 40
    handle.lineCapStyle = .round
    handle.move(to: NSPoint(x: c.x + dx * 250, y: c.y + dy * 250))
    handle.line(to: NSPoint(x: c.x + dx * 330, y: c.y + dy * 330))
    handle.stroke()

    let kx = c.x + dx * 352, ky = c.y + dy * 352
    NSBezierPath(ovalIn: NSRect(x: kx - 24, y: ky - 24, width: 48, height: 48)).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
