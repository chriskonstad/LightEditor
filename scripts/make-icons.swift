// Builds every AppIcon image from one 1024 px square master:
//
//   swift scripts/make-icons.swift [master.png]
//
// - icon-1024.png: iOS and iPadOS, the master flattened onto the background with no
//   alpha channel (App Store Connect rejects icons that have one).
// - icon-1024-dark.png: the artwork on transparency, so the system's dark backdrop
//   shows through. The background color is keyed out.
// - icon-1024-tinted.png: the dark variant in grayscale, which the system tints.
// - mac-*.png: macOS draws icons as they are, so the artwork sits in a rounded square
//   on the standard 1024 px grid (824 px body, 100 px margin) with a soft shadow.
//
// The master defaults to docs/images/icon.png.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSet = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../App/Resources/Assets.xcassets/AppIcon.appiconset").standardized
let masterURL = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../docs/images/icon.png").standardized

/// The icon's background, #111214.
let background = (r: 0x11, g: 0x12, b: 0x14)

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("Can't read \(url.path)") }
    return image
}

func save(_ image: CGImage, _ name: String) {
    let url = iconSet.appending(path: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(name)") }
    print("wrote \(name) (\(image.width) px\([.none, .noneSkipLast].contains(image.alphaInfo) ? ", no alpha" : ""))")
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ size: Int, alpha: Bool) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func pixels(_ image: CGImage) -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let ctx = context(image.width, alpha: true)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (ctx, ctx.data!.assumingMemoryBound(to: UInt8.self))
}

let master = load(masterURL)
precondition(master.width == 1024 && master.height == 1024, "The master must be 1024 × 1024")
let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)

// iOS: opaque, no alpha channel.
let opaque = context(1024, alpha: false)
opaque.setFillColor(CGColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255, blue: CGFloat(background.b) / 255, alpha: 1))
opaque.fill(full)
opaque.draw(master, in: full)
save(opaque.makeImage()!, "icon-1024.png")

// Dark: key out the background color, with a soft edge so antialiasing stays smooth.
let (darkContext, dark) = pixels(master)
for i in stride(from: 0, to: 1024 * 1024 * 4, by: 4) {
    let distance = abs(Int(dark[i]) - background.r) + abs(Int(dark[i + 1]) - background.g) + abs(Int(dark[i + 2]) - background.b)
    let keep = min(1, max(0, Double(distance - 12) / 36))
    for c in 0..<4 { dark[i + c] = UInt8(Double(dark[i + c]) * keep) }
}
let darkImage = darkContext.makeImage()!
save(darkImage, "icon-1024-dark.png")

// Tinted: grayscale of the dark variant, brightened so the tint reads.
let (tintContext, tint) = pixels(darkImage)
for i in stride(from: 0, to: 1024 * 1024 * 4, by: 4) where tint[i + 3] > 0 {
    let alpha = Double(tint[i + 3]) / 255
    let luma = (0.2126 * Double(tint[i]) + 0.7152 * Double(tint[i + 1]) + 0.0722 * Double(tint[i + 2])) / alpha
    let value = UInt8(min(255, luma * 1.25) * alpha)
    tint[i] = value; tint[i + 1] = value; tint[i + 2] = value
}
save(tintContext.makeImage()!, "icon-1024-tinted.png")

// macOS: rounded square with margins and a shadow, at every size.
let mac = context(1024, alpha: true)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
mac.addPath(shape)
mac.setFillColor(CGColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255, blue: CGFloat(background.b) / 255, alpha: 1))
mac.fillPath()
mac.restoreGState()
mac.addPath(shape)
mac.clip()
mac.draw(master, in: body)
let macImage = mac.makeImage()!
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let scaled = context(size, alpha: true)
    scaled.interpolationQuality = .high
    scaled.draw(macImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    save(scaled.makeImage()!, "mac-\(size).png")
}
