// Renders Resources/AppIcon.icns: a session "core" with agents orbiting it, the same motif as the dashboard.
// Usage: swift scripts/make-icon.swift   (needs only the Command Line Tools)
import AppKit

let canvas: CGFloat = 1024

func render() -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        // macOS icon grid: 824 pt body with continuous corners, centred, leaving room for the system shadow.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

        ctx.saveGState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.19, green: 0.18, blue: 0.51, alpha: 1),
                            NSColor(srgbRed: 0.05, green: 0.45, blue: 0.56, alpha: 1)])!
            .draw(in: body, angle: -55)
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
            .draw(in: NSBezierPath(ovalIn: body.insetBy(dx: 140, dy: 140)), relativeCenterPosition: .zero)

        let center = CGPoint(x: body.midX, y: body.midY - 10)

        // Two tilted orbits.
        for (rx, ry, angle) in [(330.0, 150.0, 20.0), (300.0, 120.0, -35.0)] {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor)
            ctx.setLineWidth(7)
            ctx.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            ctx.restoreGState()
        }

        // Core with a soft glow.
        let glow = NSGradient(colors: [NSColor(srgbRed: 0.29, green: 0.87, blue: 0.5, alpha: 0.55),
                                       NSColor(srgbRed: 0.29, green: 0.87, blue: 0.5, alpha: 0)])!
        glow.draw(in: NSBezierPath(ovalIn: CGRect(x: center.x - 230, y: center.y - 230, width: 460, height: 460)),
                  relativeCenterPosition: .zero)
        NSGradient(colors: [NSColor(srgbRed: 0.53, green: 0.94, blue: 0.67, alpha: 1),
                            NSColor(srgbRed: 0.09, green: 0.64, blue: 0.29, alpha: 1)])!
            .draw(in: NSBezierPath(ovalIn: CGRect(x: center.x - 96, y: center.y - 96, width: 192, height: 192)), angle: -70)

        // Satellites with comet tails along their orbits.
        let satellites: [(rx: Double, ry: Double, tilt: Double, at: Double, color: NSColor)] = [
            (330, 150, 20, 0.35, NSColor(srgbRed: 0.96, green: 0.45, blue: 0.71, alpha: 1)),
            (300, 120, -35, 3.6, NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1)),
            (330, 150, 20, 3.9, NSColor(srgbRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)),
        ]
        for satellite in satellites {
            for step in stride(from: 7, through: 0, by: -1) {
                let t = satellite.at - Double(step) * 0.075
                let local = CGPoint(x: cos(t) * satellite.rx, y: sin(t) * satellite.ry)
                let tilt = satellite.tilt * .pi / 180
                let point = CGPoint(x: center.x + local.x * cos(tilt) - local.y * sin(tilt),
                                    y: center.y + local.x * sin(tilt) + local.y * cos(tilt))
                let radius = step == 0 ? 44.0 : 30.0 - Double(step) * 3
                satellite.color.withAlphaComponent(step == 0 ? 1 : 0.5 - Double(step) * 0.06).setFill()
                NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
        }

        // Glass highlight across the top.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
            .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        ctx.restoreGState()

        NSColor(white: 1, alpha: 0.25).setStroke()
        shape.lineWidth = 3
        shape.stroke()
        return true
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let image = render()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}

let output = root.appending(path: "Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
