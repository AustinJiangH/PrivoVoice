// dev-icon.swift — stamp a "DEV" banner across the bottom of the app icon so a
// dev build is recognizable in Finder, Spotlight, and System Settings →
// Privacy & Security next to the installed release.
//
// Usage:  swift scripts/dev-icon.swift <in.icon> <out.icon>
//
// Copies the Icon Composer document and stamps the banner onto each layer
// image in its Assets folder (full-bleed 1024px artwork; the system applies
// the icon mask, so the banner stays clear of the rounded corners).

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: dev-icon.swift <in.icon> <out.icon>\n".utf8))
    exit(1)
}
let fm = FileManager.default
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try? fm.removeItem(at: output)
try fm.copyItem(at: source, to: output)

func stamp(_ url: URL) throws {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    let side = CGFloat(cg.width)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

    // Inside the system mask's rounded corners.
    let banner = NSRect(x: side * 0.18, y: side * 0.11, width: side * 0.64, height: side * 0.2)
    NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: banner, xRadius: side * 0.05, yRadius: side * 0.05).fill()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: side * 0.14, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: banner.midX - size.width / 2, y: banner.midY - size.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: url)
}

let assets = output.appending(path: "Assets")
for name in try fm.contentsOfDirectory(atPath: assets.path) where name.hasSuffix(".png") {
    try stamp(assets.appending(path: name))
}
