import AppKit

@MainActor
final class IconProvider {
    static let menuBarHeight: CGFloat = 18
    static let dimAlpha: CGFloat = 0.4

    private struct Level {
        let percent: Int
        let url: URL
    }

    private var levels: [Level] = []
    private var errorURL: URL?
    private var cache: [String: NSImage] = [:]

    init(directory: URL? = IconProvider.locateIconDirectory()) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name == "icon-error.svg" {
                errorURL = url
            } else if name.hasPrefix("icon-"), name.hasSuffix(".svg"),
                      let percent = Int(name.dropFirst(5).dropLast(4)) {
                levels.append(Level(percent: percent, url: url))
            }
        }
        levels.sort { $0.percent < $1.percent }
    }

    var hasIcons: Bool { !levels.isEmpty || errorURL != nil }

    func image(forRemaining remaining: Int) -> NSImage? {
        guard let level = nearestLevel(to: remaining) else { return nil }
        return cached("level-\(level.percent)") { Self.makeImage(url: level.url, alpha: 1) }
    }

    func loadingImage() -> NSImage? {
        guard let level = levels.last else { return nil }
        return cached("dim-\(level.percent)") { Self.makeImage(url: level.url, alpha: Self.dimAlpha) }
    }

    func errorImage(lastRemaining: Int?) -> NSImage? {
        if let errorURL {
            return cached("error") { Self.makeImage(url: errorURL, alpha: 1) }
        }
        guard let level = nearestLevel(to: lastRemaining ?? 0) else { return nil }
        return cached("dim-\(level.percent)") { Self.makeImage(url: level.url, alpha: Self.dimAlpha) }
    }

    func allIcons() -> [(name: String, url: URL)] {
        levels.map { ("icon-\($0.percent)", $0.url) } + (errorURL.map { [("icon-error", $0)] } ?? [])
    }

    private func nearestLevel(to remaining: Int) -> Level? {
        // Ties resolve to the lower step (levels are sorted ascending, min keeps the first).
        levels.min { abs($0.percent - remaining) < abs($1.percent - remaining) }
    }

    private func cached(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let hit = cache[key] { return hit }
        guard let image = make() else { return nil }
        cache[key] = image
        return image
    }

    static func makeImage(url: URL, alpha: CGFloat) -> NSImage? {
        guard let base = NSImage(contentsOf: url), base.size.width > 0, base.size.height > 0 else { return nil }
        let size = NSSize(width: menuBarHeight * base.size.width / base.size.height, height: menuBarHeight)
        if alpha >= 1 {
            base.size = size
            base.isTemplate = false
            return base
        }
        let dimmed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        dimmed.isTemplate = false
        return dimmed
    }

    nonisolated static func locateIconDirectory() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("icons"),
           fm.fileExists(atPath: bundled.path) { return bundled }
        // Development runs (swift run): walk up from the executable to the package's Resources/icons.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("Resources/icons")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/icons")
        return fm.fileExists(atPath: cwd.path) ? cwd : nil
    }
}

// MARK: - --render-icons

@MainActor
enum IconRenderer {
    static func run(outputDirectory: String) -> Int32 {
        let provider = IconProvider()
        let icons = provider.allIcons()
        guard !icons.isEmpty else {
            FileHandle.standardError.write(Data("No icons found.\n".utf8))
            return 1
        }
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var images: [NSImage] = []
        for (name, url) in icons {
            guard let image = NSImage(contentsOf: url) else {
                FileHandle.standardError.write(Data("Failed to load \(name)\n".utf8))
                return 1
            }
            images.append(image)
            let height: CGFloat = 512
            let width = (height * image.size.width / image.size.height).rounded()
            guard let rep = bitmap(width: Int(width), height: Int(height), background: nil, draw: { rect in
                image.draw(in: rect)
            }) else { return 1 }
            write(rep, to: dir.appendingPathComponent("\(name).png"))
        }
        writeContactSheet(images, to: dir.appendingPathComponent("sheet.png"))
        print("Rendered \(icons.count) icons to \(dir.path)")
        return 0
    }

    private static func bitmap(width: Int, height: Int, background: NSColor?, draw: (NSRect) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        if let background {
            background.setFill()
            rect.fill()
        }
        draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // Row per background (light, dark); each icon at large size and at real menu-bar size (18pt @2x).
    private static func writeContactSheet(_ images: [NSImage], to url: URL) {
        let cellW = 240, largeH = 150, smallH = 36, pad = 20
        let bandH = pad + largeH + pad + smallH + pad
        let width = images.count * (cellW + pad) + pad
        guard let rep = bitmap(width: width, height: bandH * 2, background: nil, draw: { _ in
            let bands: [(NSColor, Int)] = [(.white, bandH), (NSColor(white: 0.16, alpha: 1), 0)]
            for (color, originY) in bands {
                color.setFill()
                NSRect(x: 0, y: originY, width: width, height: bandH).fill()
                for (i, image) in images.enumerated() {
                    let x = CGFloat(pad + i * (cellW + pad))
                    let aspect = image.size.width / image.size.height
                    let largeW = min(CGFloat(cellW), CGFloat(largeH) * aspect)
                    image.draw(in: NSRect(x: x, y: CGFloat(originY + pad + smallH + pad), width: largeW, height: largeW / aspect))
                    let smallW = CGFloat(smallH) * aspect
                    image.draw(in: NSRect(x: x, y: CGFloat(originY + pad), width: smallW, height: CGFloat(smallH)))
                }
            }
        }) else { return }
        write(rep, to: url)
    }
}
