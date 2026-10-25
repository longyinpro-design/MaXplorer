import Foundation
import CoreGraphics
import ImageIO

nonisolated private func image(_ side: Int = 4) -> FileThumbnailImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return FileThumbnailImage(cgImage: context.makeImage()!)
}
nonisolated private func key(_ name: String, date: Double = 1, size: Int64 = 1, pixels: Int = 64) -> FileThumbnailKey {
    FileThumbnailKey(url: URL(fileURLWithPath: "/test/" + name), modifiedAt: Date(timeIntervalSince1970: date), fileSize: size, pixelSize: pixels)
}
private actor Probe {
    var starts: [FileThumbnailKey] = []
    var active = 0
    var peak = 0
    var gates: [CheckedContinuation<Void, Never>] = []
    func load(_ key: FileThumbnailKey) async -> FileThumbnailImage? {
        starts.append(key); active += 1; peak = max(peak, active)
        await withCheckedContinuation { gates.append($0) }
        active -= 1
        return image()
    }
    func release() { let pending = gates; gates = []; for gate in pending { gate.resume() } }
    func count() -> Int { starts.count }
}
private actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
@main struct ThumbnailRegression {
    static func until(_ condition: () async -> Bool) async {
        for _ in 0..<100_000 { if await condition() { return }; await Task.yield() }
        fatalError("Timed out waiting for deterministic provider gate")
    }
    static func check(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL " + name) }; print("PASS " + name) }
    static func main() async {
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--probe-video") {
            let directory = URL(fileURLWithPath: CommandLine.arguments.last!)
            var fixtures: [(String, URL)] = []
            if CommandLine.arguments.contains("--probe") {
                let url = directory.appendingPathComponent("probe.png")
                let png = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(png, image(32).cgImage, nil)
                guard CGImageDestinationFinalize(png) else { fatalError("Fixture creation failed") }
                fixtures.append(("PNG", url))
            }
            let video = directory.appendingPathComponent("probe.mov")
            if FileManager.default.fileExists(atPath: video.path) { fixtures.append(("video", video)) }
            else { print("NOT_PROVEN video fixture unavailable"); exit(2) }
            var unproven = false
            for (kind, url) in fixtures {
                let probeKey = FileThumbnailKey(url: url, modifiedAt: Date(), fileSize: nil, pixelSize: 64)
                let result = await withTaskGroup(of: FileThumbnailImage?.self) { group in
                    group.addTask { await FileThumbnailService.shared.thumbnail(for: probeKey) }
                    group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
                    let first = await group.next()!
                    group.cancelAll()
                    return first
                }
                if let result { print("PASS real Quick Look \(kind) thumbnail \(result.cgImage.width)x\(result.cgImage.height)") }
                else { print("NOT_PROVEN real Quick Look \(kind) unavailable within desktop-denied sandbox"); unproven = true }
            }
            if unproven { exit(2) }
            return
        }

        let probe = Probe()
        let service = FileThumbnailService(provider: { await probe.load($0) })
        let first = Task { await service.thumbnail(for: key("same")) }
        let second = Task { await service.thumbnail(for: key("same")) }
        await until { await probe.count() == 1 }
        for _ in 0..<100 { await Task.yield() }
        first.cancel()
        check(await first.value == nil, "cancelled consumer receives nil")
        await probe.release()
        let secondImage = await second.value
        let dedupCount = await probe.count()
        check(secondImage != nil && dedupCount == 1, "dedup preserves other consumer")

        var batch = (0..<3).map { i in Task { await service.thumbnail(for: key("batch\(i)")) } }
        await until { await probe.count() == 4 }
        batch += (3..<8).map { i in Task { await service.thumbnail(for: key("batch\(i)")) } }
        for _ in 0..<100 { await Task.yield() }
        check(await probe.peak == 3, "concurrency bounded to three")
        batch[7].cancel()
        check(await batch[7].value == nil, "queued cancellation")
        for _ in 0..<4 { await probe.release(); for _ in 0..<100 { await Task.yield() } }
        for task in batch { _ = await task.value }
        check(await !probe.starts.contains(key("batch7")), "cancelled queue entry never starts")

        let staleProbe = Probe()
        let staleService = FileThumbnailService(maxConcurrent: 1, provider: { await staleProbe.load($0) })
        let stale = Task { await staleService.thumbnail(for: key("stale")) }
        await until { await staleProbe.count() == 1 }
        stale.cancel()
        check(await stale.value == nil, "last consumer cancellation returns promptly")
        let fresh = Task { await staleService.thumbnail(for: key("stale")) }
        await staleProbe.release()
        await until { await staleProbe.count() == 2 }
        await staleProbe.release()
        check(await fresh.value != nil, "late cancelled result does not satisfy replacement request")

        let cancellation = Counter()
        let cancelService = FileThumbnailService(provider: { _ in
            do { try await Task.sleep(for: .seconds(30)); return image() }
            catch { _ = await cancellation.next(); throw error }
        })
        let cancelled = Task { await cancelService.thumbnail(for: key("cancel")) }
        for _ in 0..<100 { await Task.yield() }
        cancelled.cancel(); _ = await cancelled.value
        await until { await cancellation.value == 1 }
        check(await cancellation.value == 1, "all consumers cancelled propagates provider cancellation")

        enum Failure: Error { case expected }
        let failing = FileThumbnailService(provider: { _ in throw Failure.expected })
        check(await failing.thumbnail(for: key("failure")) == nil, "provider failure becomes fallback")
        let count = Counter()
        let cached = FileThumbnailService(cacheCount: 2, cacheCost: 128, provider: { _ in _ = await count.next(); return image() })
        _ = await cached.thumbnail(for: key("a")); _ = await cached.thumbnail(for: key("b"))
        _ = await cached.thumbnail(for: key("a")); _ = await cached.thumbnail(for: key("c"))
        _ = await cached.thumbnail(for: key("a"))
        check(await count.value == 3, "cache hit refreshes LRU")
        _ = await cached.thumbnail(for: key("b"))
        check(await count.value == 4, "count LRU evicts oldest")
        _ = await cached.thumbnail(for: key("b", date: 2))
        _ = await cached.thumbnail(for: key("b", date: 2, size: 2))
        _ = await cached.thumbnail(for: key("b", date: 2, size: 2, pixels: 128))
        check(await count.value == 7, "mtime size and pixel dimensions invalidate cache")
        let costs = Counter()
        let costCache = FileThumbnailService(cacheCount: 10, cacheCost: 64, provider: { _ in _ = await costs.next(); return image() })
        _ = await costCache.thumbnail(for: key("a")); _ = await costCache.thumbnail(for: key("b")); _ = await costCache.thumbnail(for: key("a"))
        check(await costs.value == 3, "cost budget evicts despite available count")
        let oversized = Counter()
        let smallCache = FileThumbnailService(cacheCost: 1, provider: { _ in _ = await oversized.next(); return image() })
        _ = await smallCache.thumbnail(for: key("big")); _ = await smallCache.thumbnail(for: key("big"))
        check(await oversized.value == 2, "oversized image is not retained")
        print("Thumbnail regression complete")
    }
}
