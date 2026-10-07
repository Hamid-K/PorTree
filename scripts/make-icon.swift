// Draws the Portree app icon (port + tree: a left-to-right device tree with a
// bolt accent) and writes assets/icon_1024.png. Run via `make icon`, which
// then produces AppIcon.icns with sips + iconutil — no Xcode asset catalogs.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let context = NSGraphicsContext.current!.cgContext

// Background: deep slate rounded-rect with a subtle vertical gradient.
let inset: CGFloat = 64
let bgRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 180, cornerHeight: 180, transform: nil)
context.addPath(bgPath)
context.clip()
let bgColors = [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.20, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Tree: root (port) on the left, two tiers of children to the right.
struct Node { let point: CGPoint; let radius: CGFloat; let color: NSColor }
let indigo = NSColor(calibratedRed: 0.49, green: 0.48, blue: 1.0, alpha: 1)
let blue = NSColor(calibratedRed: 0.25, green: 0.61, blue: 1.0, alpha: 1)
let orange = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)

let root = Node(point: CGPoint(x: 268, y: 512), radius: 86, color: indigo)
let children = [
    Node(point: CGPoint(x: 568, y: 716), radius: 62, color: blue),
    Node(point: CGPoint(x: 568, y: 512), radius: 62, color: blue),
    Node(point: CGPoint(x: 568, y: 308), radius: 62, color: orange),
]
let leaves = [
    Node(point: CGPoint(x: 802, y: 786), radius: 44, color: blue),
    Node(point: CGPoint(x: 802, y: 646), radius: 44, color: blue),
    Node(point: CGPoint(x: 802, y: 308), radius: 44, color: orange),
]

func edge(from a: Node, to b: Node, width: CGFloat, color: NSColor) {
    let midX = (a.point.x + b.point.x) / 2
    let path = CGMutablePath()
    path.move(to: a.point)
    path.addCurve(to: b.point,
                  control1: CGPoint(x: midX, y: a.point.y),
                  control2: CGPoint(x: midX, y: b.point.y))
    context.addPath(path)
    context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.strokePath()
}

edge(from: root, to: children[0], width: 30, color: blue)
edge(from: root, to: children[1], width: 30, color: blue)
edge(from: root, to: children[2], width: 18, color: orange)
edge(from: children[0], to: leaves[0], width: 20, color: blue)
edge(from: children[0], to: leaves[1], width: 20, color: blue)
edge(from: children[2], to: leaves[2], width: 14, color: orange)

for node in [root] + children + leaves {
    context.setFillColor(node.color.cgColor)
    context.fillEllipse(in: CGRect(
        x: node.point.x - node.radius, y: node.point.y - node.radius,
        width: node.radius * 2, height: node.radius * 2
    ))
    context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
    let inner = node.radius * 0.45
    context.fillEllipse(in: CGRect(
        x: node.point.x - inner, y: node.point.y - inner,
        width: inner * 2, height: inner * 2
    ))
}

// Bolt accent on the root node.
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 288, y: 596))
bolt.line(to: NSPoint(x: 232, y: 506))
bolt.line(to: NSPoint(x: 268, y: 506))
bolt.line(to: NSPoint(x: 248, y: 428))
bolt.line(to: NSPoint(x: 304, y: 518))
bolt.line(to: NSPoint(x: 268, y: 518))
bolt.close()
NSColor.white.setFill()
bolt.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
let out = URL(fileURLWithPath: "assets/icon_1024.png")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: out)
print("wrote \(out.path)")
