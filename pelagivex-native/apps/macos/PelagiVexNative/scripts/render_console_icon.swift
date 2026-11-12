import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run with `swift scripts/render_console_icon.swift <output-directory>` from the native app directory.
// The output directory receives the master PNG, macOS iconset and PelagiVex.icns.

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func renderMaster(at url: URL) throws {
    let pixels = 1024
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(message: "Could not create the icon canvas.")
    }

    func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    // Work in the same top-left coordinate system as the SwiftUI ConsoleGlyph.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    let tile = CGRect(x: 92, y: 92, width: 840, height: 840)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)
    guard let gradient = CGGradient(colorsSpace: space,
                                    colors: [rgb(25, 35, 49), rgb(11, 16, 25)] as CFArray,
                                    locations: [0, 1]) else {
        throw IconError(message: "Could not create the tile gradient.")
    }
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.minY),
                               end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
    context.restoreGState()
    context.addPath(tilePath)
    context.setStrokeColor(rgb(51, 67, 86))
    context.setLineWidth(4)
    context.strokePath()

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * tile.width, y: tile.minY + y * tile.height)
    }

    // Match ConsoleGlyph's geometry. The heavier stroke remains legible at Dock sizes.
    context.setLineWidth(54)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(rgb(255, 79, 95))
    context.addLines(between: [point(0.19, 0.47), point(0.40, 0.26), point(0.68, 0.26), point(0.81, 0.39)])
    context.strokePath()
    context.setStrokeColor(rgb(255, 79, 95, alpha: 0.64))
    context.addLines(between: [point(0.81, 0.53), point(0.60, 0.74), point(0.32, 0.74), point(0.19, 0.61)])
    context.strokePath()
    context.setFillColor(rgb(255, 79, 95))
    context.addLines(between: [point(0.50, 0.40), point(0.60, 0.50), point(0.50, 0.60), point(0.40, 0.50)])
    context.closePath()
    context.fillPath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(message: "Could not prepare the master PNG.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError(message: "Could not write the master PNG.")
    }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError(message: "\(executable) exited with status \(process.terminationStatus).")
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw IconError(message: "Usage: swift render_console_icon.swift <output-directory>")
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let iconset = output.appendingPathComponent("PelagiVex.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let master = output.appendingPathComponent("PelagiVex-1024.png")
    try renderMaster(at: master)

    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = String(points * scale)
            let suffix = scale == 2 ? "@2x" : ""
            let image = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
            try run("/usr/bin/sips", ["-z", pixels, pixels, master.path, "--out", image.path])
        }
    }
    let icon = output.appendingPathComponent("PelagiVex.icns")
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icon.path])
    print(icon.path)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
