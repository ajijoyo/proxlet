// Builds the macOS app icon PNG from icon.jpg: masks it to the 824 px rounded-square body of a 1024 px canvas.
// Usage: swift scripts/make-icon.swift <input.jpg> <output.png>
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make-icon.swift <input> <output.png>") }
guard let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("cannot read image \(args[1])")
}
let size = 1024
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("cannot create drawing context")
}

// Apple's icon grid: 824 px body with a 100 px transparent margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
out.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
out.clip()
out.draw(src, in: body)
guard let image = out.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fail("cannot encode PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    fail("cannot write \(args[2]): \(error.localizedDescription)")
}
