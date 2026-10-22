// Draws the app icon: a dark rounded square with a play triangle over talk-track lines. Run by build.sh.
import AppKit

let out = CommandLine.arguments[1]
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1), ending: NSColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
// talk-track lines
NSColor(white: 1, alpha: 0.22).setFill()
for (k, w) in [CGFloat(520), 600, 440].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 212, y: 250 + CGFloat(k) * 70, width: w, height: 30), xRadius: 15, yRadius: 15).fill()
}
// play triangle
let p = NSBezierPath()
p.move(to: NSPoint(x: 420, y: 520)); p.line(to: NSPoint(x: 420, y: 780)); p.line(to: NSPoint(x: 640, y: 650)); p.close()
NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1).setFill()
p.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
