import Foundation
import CoreGraphics

/// Window-frame geometry in AppKit's global point coordinates, including negative
/// screen origins. The caller includes title-bar chrome in the preferred size.
nonisolated enum PreviewWindowPlacement {
    static func usableFrame(_ visibleFrame: CGRect) -> CGRect {
        visibleFrame.insetBy(dx: min(20, visibleFrame.width / 10), dy: min(20, visibleFrame.height / 10))
    }

    static func initialFrame(ownerFrame: CGRect, preferredSize: CGSize, visibleFrame: CGRect) -> CGRect {
        constrainedFrame(CGRect(
            x: ownerFrame.midX - preferredSize.width / 2,
            y: ownerFrame.midY - preferredSize.height / 2,
            width: preferredSize.width,
            height: preferredSize.height
        ), visibleFrame: visibleFrame)
    }

    static func constrainedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let usable = usableFrame(visibleFrame)
        let size = CGSize(width: min(frame.width, usable.width), height: min(frame.height, usable.height))
        return CGRect(
            x: min(max(frame.minX, usable.minX), usable.maxX - size.width),
            y: min(max(frame.minY, usable.minY), usable.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    /// Prefer the surviving display containing most of the window. After a
    /// display is unplugged, fall back to the owner's display, then the first.
    static func screenIndex(for frame: CGRect, visibleFrames: [CGRect], fallback: Int?) -> Int? {
        guard !visibleFrames.isEmpty else { return nil }
        var best: Int?
        var largestArea: CGFloat = 0
        for (index, visible) in visibleFrames.enumerated() {
            let overlap = frame.intersection(visible)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea {
                largestArea = area
                best = index
            }
        }
        if let best { return best }
        if let fallback, visibleFrames.indices.contains(fallback) { return fallback }
        return 0
    }
}
