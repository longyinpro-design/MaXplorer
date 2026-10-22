import Foundation
import CoreGraphics

extension FileOperationTests {
    static func previewWindowPlacementTests() async {
        await test("preview window opens on its owner's display in every arrangement") { _ in
            let displays = [
                CGRect(x: 0, y: 40, width: 1920, height: 1016),
                CGRect(x: 1920, y: 40, width: 1440, height: 856),
                CGRect(x: -1440, y: 40, width: 1440, height: 856),
                CGRect(x: 0, y: 1080, width: 1440, height: 856),
                CGRect(x: 0, y: -900, width: 1440, height: 856)
            ]
            for visible in displays {
                let owner = CGRect(x: visible.midX - 500, y: visible.midY - 320, width: 1000, height: 640)
                let frame = PreviewWindowPlacement.initialFrame(ownerFrame: owner, preferredSize: CGSize(width: 1200, height: 848), visibleFrame: visible)
                try expect(visible.contains(frame), "preview escaped owner display at \(visible.origin)")
                try expect(abs(frame.midX - visible.midX) < 1, "preview was centered on another display")
                try expect(frame.height <= visible.height - 40, "title bar chrome was not included")
            }
        }
        await test("preview window fits narrow short and scaled display point bounds") { _ in
            for visible in [CGRect(x: -800, y: 0, width: 800, height: 560), CGRect(x: 100, y: 200, width: 600, height: 420), CGRect(x: 0, y: 25, width: 2056, height: 1240)] {
                let frame = PreviewWindowPlacement.initialFrame(ownerFrame: visible, preferredSize: CGSize(width: 1200, height: 848), visibleFrame: visible)
                try expect(visible.contains(frame), "small screen preview is clipped")
                try expect(frame.width > 0 && frame.height > 0, "small screen has an invalid frame")
                try expect(frame.width <= 1200 && frame.height <= 848, "Retina pixel count inflated point dimensions")
            }
        }
        await test("preview window keeps user size and position when already visible") { _ in
            let visible = CGRect(x: -1920, y: -500, width: 1920, height: 1080)
            let frame = CGRect(x: -1700, y: -300, width: 900, height: 650)
            try expect(PreviewWindowPlacement.constrainedFrame(frame, visibleFrame: visible) == frame, "normal update reset user geometry")
        }
        await test("preview window chooses destination display by overlap") { _ in
            let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
            let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let frame = CGRect(x: -1100, y: 100, width: 1200, height: 820)
            try expect(PreviewWindowPlacement.screenIndex(for: frame, visibleFrames: [main, left], fallback: 0) == 1, "owner/main screen overrode dragged destination")
        }
        await test("preview window shrinks oversized frame only when destination requires it") { _ in
            let visible = CGRect(x: 1920, y: -200, width: 1024, height: 700)
            let old = CGRect(x: 1980, y: -180, width: 1200, height: 848)
            let fitted = PreviewWindowPlacement.constrainedFrame(old, visibleFrame: visible)
            try expect(visible.contains(fitted), "large preview is inaccessible on small display")
            try expect(fitted.size == CGSize(width: 984, height: 660), "fitting did not account for all window edges")
            let normal = CGRect(x: 2000, y: -100, width: 700, height: 500)
            try expect(PreviewWindowPlacement.constrainedFrame(normal, visibleFrame: visible) == normal, "fit enlarged an already usable window")
        }
        await test("preview window recovers after display removal and rearrangement") { _ in
            let remaining = [CGRect(x: 0, y: 24, width: 1440, height: 836), CGRect(x: 1440, y: 24, width: 1280, height: 776)]
            let unplugged = CGRect(x: -1800, y: -1000, width: 1200, height: 848)
            let index = PreviewWindowPlacement.screenIndex(for: unplugged, visibleFrames: remaining, fallback: 1)
            try expect(index == 1, "removed display did not fall back to owner")
            let fitted = PreviewWindowPlacement.constrainedFrame(unplugged, visibleFrame: remaining[index!])
            try expect(remaining[index!].contains(fitted), "recovered window has inaccessible chrome")
            try expect(PreviewWindowPlacement.screenIndex(for: unplugged, visibleFrames: remaining, fallback: nil) == 0, "no-owner fallback failed")
            try expect(PreviewWindowPlacement.screenIndex(for: unplugged, visibleFrames: [], fallback: nil) == nil, "no-display transition fabricated a screen")
        }
        await test("preview window fitting is stable across repeated screen notifications") { _ in
            let visible = CGRect(x: -1200, y: 900, width: 1200, height: 750)
            let first = PreviewWindowPlacement.constrainedFrame(CGRect(x: -1700, y: 1100, width: 1300, height: 900), visibleFrame: visible)
            for _ in 0..<20 {
                try expect(PreviewWindowPlacement.constrainedFrame(first, visibleFrame: visible) == first, "repeated notification shifted window")
            }
        }
    }
}
