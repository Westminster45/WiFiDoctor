// Draws the 1024px app icon. Usage: swift tools/makeicon.swift Resources/icon1024.png
import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let bg = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
                    NSColor(red: 0.30, green: 0.22, blue: 0.80, alpha: 1)])!.draw(in: bg, angle: -60)

// Wi-Fi fan: a dot and three arcs.
NSColor.white.setFill()
NSColor.white.setStroke()
let c = NSPoint(x: 460, y: 270)
NSBezierPath(ovalIn: NSRect(x: c.x - 58, y: c.y - 58, width: 116, height: 116)).fill()
for r in [170.0, 300.0, 430.0] as [CGFloat] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 45, endAngle: 135)
    arc.lineWidth = 72
    arc.lineCapStyle = .round
    arc.stroke()
}

// Medical cross badge.
let badge = NSPoint(x: 770, y: 300)
NSBezierPath(ovalIn: NSRect(x: badge.x - 150, y: badge.y - 150, width: 300, height: 300)).fill()
NSColor(red: 0.92, green: 0.22, blue: 0.27, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: badge.x - 34, y: badge.y - 100, width: 68, height: 200), xRadius: 14, yRadius: 14).fill()
NSBezierPath(roundedRect: NSRect(x: badge.x - 100, y: badge.y - 34, width: 200, height: 68), xRadius: 14, yRadius: 14).fill()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
