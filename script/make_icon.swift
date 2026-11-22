import Foundation
import ImageIO
import UniformTypeIdentifiers

// swift script/make_icon.swift path/to/AppIcon.iconset
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift script/make_icon.swift OUTPUT.iconset")
}
let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
    fatalError("Cannot open \(sourceURL.path)")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width == pixels, image.height == pixels else {
            fatalError("Expected square artwork of at least \(pixels) pixels")
        }
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot create \(file.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Cannot write \(file.path)")
        }
    }
}
