import AppKit

// 用法: RenderIcon <svg> <outdir>
// 把 SVG 渲染成 macOS iconset 需要的全部尺寸 + 一张 512 预览图。
let args = CommandLine.arguments
guard args.count >= 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: RenderIcon <svg> <outdir>\n".data(using: .utf8)!); exit(1)
}
let out = URL(fileURLWithPath: args[2])
let iconset = out.appending(path: "Dew.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ size: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// iconset 命名规范
for base in [16, 32, 128, 256, 512] {
    png(base, to: iconset.appending(path: "icon_\(base)x\(base).png"))
    png(base * 2, to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
png(512, to: out.appending(path: "dew-icon-512.png"))
png(128, to: out.appending(path: "dew-icon-128.png"))
print("rendered")
