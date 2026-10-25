import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// Metadata is supplied by the directory loader; constructing a key performs no I/O.
nonisolated struct FileThumbnailKey: Hashable, Sendable {
    let url: URL
    let modifiedAt: Date?
    let fileSize: Int64?
    let pixelSize: Int

    init(url: URL, modifiedAt: Date?, fileSize: Int64?, pixelSize: Int) {
        self.url = url.standardizedFileURL
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.pixelSize = max(1, min(pixelSize, 2048))
    }
}

/// CGImage is immutable. Its lifetime may safely cross the service/UI boundary.
nonisolated struct FileThumbnailImage: @unchecked Sendable {
    let cgImage: CGImage
    var cost: Int { cgImage.bytesPerRow * cgImage.height }
}

actor FileThumbnailService {
    typealias Provider = @Sendable (FileThumbnailKey) async throws -> FileThumbnailImage?
    static let shared = FileThumbnailService()

    private struct Job {
        let id = UUID()
        var waiters: [UUID: CheckedContinuation<FileThumbnailImage?, Never>] = [:]
        var task: Task<Void, Never>?
    }
    private struct Cached {
        let image: FileThumbnailImage
        var access: UInt64
    }
    private let provider: Provider
    private let concurrency: Int
    private let countLimit: Int
    private let costLimit: Int
    private var jobs: [FileThumbnailKey: Job] = [:]
    private var queue: [FileThumbnailKey] = []
    private var running = 0
    private var cache: [FileThumbnailKey: Cached] = [:]
    private var cacheCost = 0
    private var clock: UInt64 = 0

    init(maxConcurrent: Int = 3, cacheCount: Int = 256, cacheCost: Int = 64 * 1024 * 1024,
         provider: @escaping Provider = { key in await QuickLookThumbnailOperation.load(key) }) {
        self.concurrency = max(1, min(maxConcurrent, 3))
        self.countLimit = max(0, cacheCount)
        self.costLimit = max(0, cacheCost)
        self.provider = provider
    }

    func thumbnail(for key: FileThumbnailKey) async -> FileThumbnailImage? {
        guard !Task.isCancelled else { return nil }
        if var entry = cache[key] {
            clock &+= 1
            entry.access = clock
            cache[key] = entry
            return entry.image
        }
        let consumer = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if jobs[key] == nil {
                    jobs[key] = Job()
                    queue.append(key)
                }
                jobs[key]?.waiters[consumer] = continuation
                pump()
            }
        } onCancel: {
            Task { await self.cancel(key, consumer: consumer) }
        }
        return Task.isCancelled ? nil : result
    }

    private func cancel(_ key: FileThumbnailKey, consumer: UUID) {
        guard var job = jobs[key], let waiter = job.waiters.removeValue(forKey: consumer) else { return }
        waiter.resume(returning: nil)
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: key)
            if let task = job.task { task.cancel() }
            else { queue.removeAll { $0 == key } }
        } else {
            jobs[key] = job
        }
        pump()
    }

    private func pump() {
        while running < concurrency, !queue.isEmpty {
            let key = queue.removeFirst()
            guard var job = jobs[key], job.task == nil else { continue }
            let id = job.id
            let provider = self.provider
            running += 1
            job.task = Task {
                let image: FileThumbnailImage?
                do { image = try await provider(key) } catch { image = nil }
                self.finished(key, id: id, image: image, cancelled: Task.isCancelled)
            }
            jobs[key] = job
        }
    }

    private func finished(_ key: FileThumbnailKey, id: UUID, image: FileThumbnailImage?, cancelled: Bool) {
        running -= 1
        if let job = jobs[key], job.id == id {
            jobs.removeValue(forKey: key)
            if let image, !cancelled, !job.waiters.isEmpty { insert(image, for: key) }
            for waiter in job.waiters.values { waiter.resume(returning: cancelled ? nil : image) }
        }
        pump()
    }

    private func insert(_ image: FileThumbnailImage, for key: FileThumbnailKey) {
        guard countLimit > 0, image.cost <= costLimit else { return }
        clock &+= 1
        if let previous = cache.updateValue(Cached(image: image, access: clock), forKey: key) {
            cacheCost -= previous.image.cost
        }
        cacheCost += image.cost
        while cache.count > countLimit || cacheCost > costLimit {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
            cacheCost -= oldest.value.image.cost
            cache.removeValue(forKey: oldest.key)
        }
    }
}

/// Owns one request and arbitrates cancellation against Quick Look's callback.
/// No NSApplication, window, or synchronous file reads are used.
nonisolated private final class QuickLookThumbnailOperation: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "MaXplorer.thumbnail-request")
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<FileThumbnailImage?, Never>?
    private var cancelled = false

    private init(_ key: FileThumbnailKey) {
        request = QLThumbnailGenerator.Request(fileAt: key.url,
            size: CGSize(width: key.pixelSize, height: key.pixelSize), scale: 1,
            representationTypes: .thumbnail)
    }

    static func load(_ key: FileThumbnailKey) async -> FileThumbnailImage? {
        let operation = QuickLookThumbnailOperation(key)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    private func start(_ continuation: CheckedContinuation<FileThumbnailImage?, Never>) {
        stateQueue.async { [self] in
            guard !cancelled else { continuation.resume(returning: nil); return }
            self.continuation = continuation
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [self] representation, _ in
                let image = representation.map { FileThumbnailImage(cgImage: $0.cgImage) }
                stateQueue.async { [self] in
                    let waiter = self.continuation
                    self.continuation = nil
                    waiter?.resume(returning: cancelled ? nil : image)
                }
            }
        }
    }

    private func cancel() {
        stateQueue.async { [self] in
            cancelled = true
            let waiter = continuation
            continuation = nil
            QLThumbnailGenerator.shared.cancel(request)
            waiter?.resume(returning: nil)
        }
    }
}
