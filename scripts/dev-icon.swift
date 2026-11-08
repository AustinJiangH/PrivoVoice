// dev-icon.swift — stamp a "DEV" banner across the bottom of the app icon so a
// dev build is recognizable in Finder, Spotlight, and System Settings →
// Privacy & Security next to the installed release.
//
// Usage:  swift scripts/dev-icon.swift <in.icns> <out.icns>

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: dev-icon.swift <in.icns> <out.icns>\n".utf8))
    exit(1)
}
let outURL = URL(fileURLWithPath: args[2])
let iconset = FileManager.default.temporaryDirectory
    .appending(path: "privovoice-dev-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    let side = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))

    // Banner inset like the macOS icon grid so it sits on the artwork.
    let banner = NSRect(x: side * 0.12, y: side * 0.10, width: side * 0.76, height: side * 0.22)
    NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: banner, xRadius: side * 0.05, yRadius: side * 0.05).fill()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: side * 0.15, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: banner.midX - size.width / 2, y: banner.midY - size.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let png = render(pixels: points * scale) else { exit(1) }
        try png.write(to: iconset.appending(path: name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outURL.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
