import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let sizes = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (size, scale) in sizes {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let s = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: s, y: s)
    let background = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 218, yRadius: 218)
    let gradient = NSGradient(starting: NSColor(red: 0.37, green: 0.49, blue: 0.97, alpha: 1), ending: NSColor(red: 0.20, green: 0.24, blue: 0.69, alpha: 1))!
    gradient.draw(in: background, angle: -55)
    NSColor.white.withAlphaComponent(0.17).setFill()
    NSBezierPath(roundedRect: NSRect(x: 250, y: 264, width: 530, height: 405), xRadius: 75, yRadius: 75).fill()
    NSColor.white.withAlphaComponent(0.36).setFill()
    NSBezierPath(roundedRect: NSRect(x: 208, y: 310, width: 530, height: 405), xRadius: 75, yRadius: 75).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 167, y: 356, width: 530, height: 405), xRadius: 75, yRadius: 75).fill()
    NSColor(red: 0.29, green: 0.37, blue: 0.86, alpha: 1).setFill()
    let play = NSBezierPath(); play.move(to: NSPoint(x: 375, y: 463)); play.line(to: NSPoint(x: 375, y: 660)); play.line(to: NSPoint(x: 537, y: 562)); play.close(); play.fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = rep.representation(using: .png, properties: [:])!
    let suffix = scale == 2 ? "@2x" : ""
    try data.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
}
