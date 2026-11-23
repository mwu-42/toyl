import AppKit

// toyl's icon: a near-white sheet, "toyl" set in Times New Roman, crossed off in a gray-gold,
// a thing off your list. Drawn at 1024 points; make.sh makes the .icns from it.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// The tile, on Apple's icon grid: 824 square, corners about 185.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
context.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(srgbRed: 0.984, green: 0.984, blue: 0.980, alpha: 1).setFill()
shape.fill()
context.restoreGState()
let paper = NSGradient(starting: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.984, alpha: 1),
                       ending: NSColor(srgbRed: 0.933, green: 0.933, blue: 0.925, alpha: 1))!
paper.draw(in: shape, angle: -90)
NSColor(srgbRed: 0.84, green: 0.84, blue: 0.83, alpha: 1).setStroke()
shape.lineWidth = 3
shape.stroke()

// Faint ruled lines, as on a note.
NSColor(srgbRed: 0.78, green: 0.78, blue: 0.76, alpha: 0.35).setStroke()
for y in stride(from: 300.0, through: 740.0, by: 110.0) {
    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: 190, y: y))
    rule.line(to: NSPoint(x: 834, y: y))
    rule.lineWidth = 2
    rule.stroke()
}

// The word.
let font = NSFont(name: "Times New Roman", size: 330) ?? NSFont.systemFont(ofSize: 330)
let ink = NSColor(srgbRed: 0.11, green: 0.106, blue: 0.098, alpha: 1)
let word = NSAttributedString(string: "toyl", attributes: [.font: font, .foregroundColor: ink, .kern: -6])
let bounds = word.boundingRect(with: NSSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin])
let origin = NSPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY + 20)
word.draw(at: origin)

// Crossed off: a gold stroke, a touch uphill, through the middle of the letters.
let gold = NSColor(srgbRed: 0.592, green: 0.553, blue: 0.475, alpha: 0.95)
let strike = NSBezierPath()
let middle = origin.y + font.xHeight * 0.55 + bounds.minY + 58
strike.move(to: NSPoint(x: 205, y: middle - 14))
strike.curve(to: NSPoint(x: 822, y: middle + 18), controlPoint1: NSPoint(x: 400, y: middle + 6), controlPoint2: NSPoint(x: 640, y: middle - 4))
strike.lineWidth = 26
strike.lineCapStyle = .round
gold.setStroke()
strike.stroke()

image.unlockFocus()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "toyl.png"
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("couldn't draw the icon") }
try! png.write(to: URL(fileURLWithPath: output))
print("drew \(output)")
