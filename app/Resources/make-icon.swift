// ======================================================================
// APP ICON GENERATOR
// ======================================================================
// Builds AppIcon.icns from the bracketed pixel-clock in assets/logo.png.
// Reusing the real mark keeps the app on-brand, and pixel art stays
// legible at 16pt where fine detail would smear.
//
//   swift app/Resources/make-icon.swift assets/logo.png app/Resources
import AppKit

let logoPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let logo = NSImage(contentsOfFile: logoPath) else { fatalError("cannot read \(logoPath)") }

// Bounding box of the green mark within the wordmark, bottom-left origin.
let markRect = NSRect(x: 30, y: 27, width: 172, height: 114)

let brandGreen = NSColor(srgbRed: 0x78/255.0, green: 0xD8/255.0, blue: 0x6E/255.0, alpha: 1)
let bgTop      = NSColor(srgbRed: 0x24/255.0, green: 0x28/255.0, blue: 0x2F/255.0, alpha: 1)
let bgBottom   = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 1)

func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none  // keep pixel edges crisp

    // macOS icons sit in a squircle with roughly a 22.37% corner radius,
    // inset slightly so the shape matches system icons on the shelf.
    let inset = size * 0.055
    let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = box.width * 0.2237
    let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    shape.addClip()
    NSGradient(starting: bgTop, ending: bgBottom)?.draw(in: box, angle: -90)

    // Hairline top highlight, the way system icons catch light.
    brandGreen.withAlphaComponent(0.10).setStroke()
    let rim = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, size / 340)
    rim.stroke()

    // Draw the mark centred, scaled to ~64% of the icon width.
    let targetWidth = box.width * 0.64
    let scale = targetWidth / markRect.width
    let targetHeight = markRect.height * scale
    let dest = NSRect(x: box.midX - targetWidth / 2,
                      y: box.midY - targetHeight / 2,
                      width: targetWidth, height: targetHeight)
    logo.draw(in: dest, from: markRect, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
    try! data.write(to: URL(fileURLWithPath: path))
}

// Standard iconset ladder.
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    write(renderIcon(size: CGFloat(px)), to: "\(iconset)/\(name).png")
}
write(renderIcon(size: 1024), to: outDir + "/icon-preview.png")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", outDir + "/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")
