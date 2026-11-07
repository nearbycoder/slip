// Renders the installer window background: Resources/dmg/background.tiff (1x + 2x).
//
//   swift scripts/make-dmg-background.swift                  # from apple/
//   swift scripts/make-dmg-background.swift --preview dark   # also writes build/dmg-preview-dark.png
//
// Finder shows 640×400 pt of it (the window is a little taller for the title bar; the extra
// 30 pt at the bottom is a safety margin). Icon centers must match Resources/dmg/settings.py:
// Slip.app at (160, 186) and Applications at (480, 186), measured from the top left.
// The greens are mid-tone so Finder's labels stay legible in both light (black) and dark (white).
import AppKit

let size = NSSize(width: 640, height: 430)
/// Top-left coordinates (as in settings.py) to AppKit's bottom-left ones.
func flip(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: size.height - y) }
let appCenter = flip(160, 186)
let applicationsCenter = flip(480, 186)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func radialGlow(at center: NSPoint, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    NSGradient(colors: [color(hex, alpha), color(hex, 0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

func text(_ string: String, y: CGFloat, font: NSFont, alpha: CGFloat = 1, shadow: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: paragraph,
    ]
    if shadow {
        let s = NSShadow()
        s.shadowColor = color(0x052e16, 0.35)
        s.shadowBlurRadius = 10
        s.shadowOffset = NSSize(width: 0, height: -2)
        attributes[.shadow] = s
    }
    let line = font.ascender - font.descender
    NSAttributedString(string: string, attributes: attributes)
        .draw(in: NSRect(x: 0, y: size.height - y - line, width: size.width, height: line + 4))
}

func draw() {
    let bounds = NSRect(origin: .zero, size: size)

    // Slip green, lit from the top left.
    NSGradient(colors: [color(0x22C55E), color(0x16A34A), color(0x15803D)])!.draw(in: bounds, angle: -60)
    radialGlow(at: flip(30, -10), radius: 300, 0x86EFAC, 0.55)
    radialGlow(at: flip(640, 20), radius: 320, 0x2DD4BF, 0.35)
    radialGlow(at: flip(320, 520), radius: 360, 0x14532D, 0.55)

    // A faint dot grid that fades out toward the bottom.
    for row in stride(from: CGFloat(11), to: size.height, by: 22) {
        let fade = max(0, 1 - row / (size.height * 0.85))
        guard fade > 0 else { continue }
        color(0xFFFFFF, 0.1 * fade).setFill()
        for col in stride(from: CGFloat(11), to: size.width, by: 22) {
            NSBezierPath(ovalIn: NSRect(x: col - 1, y: size.height - row - 1, width: 2, height: 2)).fill()
        }
    }

    // Light pooled behind each icon, and radar rings around Slip (as in the app's Receive screen).
    radialGlow(at: appCenter, radius: 100, 0xFFFFFF, 0.26)
    radialGlow(at: applicationsCenter, radius: 100, 0xFFFFFF, 0.2)
    for (i, r) in [CGFloat(90), 111, 132].enumerated() {
        color(0xFFFFFF, 0.2 - CGFloat(i) * 0.055).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: appCenter.x - r, y: appCenter.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    // Dotted path from Slip to Applications, brightening as it goes.
    let from = appCenter.x + 98, to = applicationsCenter.x - 98, y = appCenter.y
    let dots = 9
    for i in 0..<dots {
        let t = CGFloat(i) / CGFloat(dots - 1)
        let x = from + (to - 14 - from) * t
        let d: CGFloat = 5.5
        color(0xFFFFFF, 0.3 + 0.7 * t).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d)).fill()
    }
    NSColor.white.setStroke()
    let head = NSBezierPath()
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: to - 12, y: y + 12))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 12, y: y - 12))
    head.stroke()

    text("Install Slip", y: 30, font: rounded(24, .heavy), shadow: true)
    text("Drag Slip into your Applications folder", y: 64, font: rounded(13, .semibold), alpha: 0.85)

    // Hint pill about the one permission Slip needs.
    let hint = NSMutableAttributedString(string: "Then open Slip and choose ", attributes: [
        .font: rounded(11.5, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])
    hint.append(NSAttributedString(string: "Allow", attributes: [.font: rounded(11.5, .heavy), .foregroundColor: NSColor.white]))
    hint.append(NSAttributedString(string: " to find devices nearby", attributes: [
        .font: rounded(11.5, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]))
    let hintSize = hint.size()
    let pill = NSRect(x: (size.width - hintSize.width) / 2 - 14, y: size.height - 318 - hintSize.height - 14,
                      width: hintSize.width + 28, height: hintSize.height + 14)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
    color(0x052E16, 0.28).setFill()
    pillPath.fill()
    color(0xFFFFFF, 0.22).setStroke()
    pillPath.lineWidth = 1
    pillPath.stroke()
    hint.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 7))

    text("Free & open source · Works with LocalSend · nearbycoder.github.io/slip", y: 364, font: rounded(10.5, .semibold), alpha: 0.6)
}

func render(scale: CGFloat, overlay: (() -> Void)? = nil) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    overlay?()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let output = URL(fileURLWithPath: "Resources/dmg/background.tiff")
try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: output)
print("Wrote \(output.path)")

// --preview light|dark: mock Finder's icons and labels on top, to check the layout.
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let dark = CommandLine.arguments[i + 1] == "dark"
    let icon = NSImage(contentsOfFile: "App/macOS/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png") ?? NSImage(named: NSImage.applicationIconName)!
    let folder = NSWorkspace.shared.icon(forFile: "/Applications")
    let rep = render(scale: 2) {
        for (img, center, label) in [(icon, appCenter, "Slip"), (folder, applicationsCenter, "Applications")] {
            img.draw(in: NSRect(x: center.x - 64, y: center.y - 64, width: 128, height: 128))
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: dark ? NSColor.white : NSColor.black, .paragraphStyle: p,
            ]).draw(in: NSRect(x: center.x - 80, y: center.y - 64 - 24, width: 160, height: 18))
        }
    }
    let url = URL(fileURLWithPath: "build/dmg-preview-\(dark ? "dark" : "light").png")
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}
