import AppKit

/// Export existing file URLs without file IO or deferred pasteboard providers.
@MainActor
enum FileDragPayload {
    static func items(for urls: [URL], origin: NSPoint) -> [NSDraggingItem] {
        urls.filter(\.isFileURL).enumerated().map { index, url in
            let writer = NSPasteboardItem()
            writer.setString(url.absoluteString, forType: .fileURL)
            let item = NSDraggingItem(pasteboardWriter: writer)
            // A large selection must not create a screen-sized drag surface.
            let offset = CGFloat(min(index, 2)) * 4
            item.setDraggingFrame(
                NSRect(x: origin.x + offset, y: origin.y - offset, width: 32, height: 32),
                contents: image
            )
            return item
        }
    }

    // Rasterize once before AppKit hands the image to the drag server. A drawing
    // handler would defer rendering, and file-specific icons can query disks or
    // Launch Services synchronously while the global drag session is starting.
    private static let image: NSImage = {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)?
            .draw(in: NSRect(x: 8, y: 4, width: 48, height: 56))
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 32, height: 32))
    }()
}
