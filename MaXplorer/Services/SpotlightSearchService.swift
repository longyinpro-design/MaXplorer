import Foundation

nonisolated enum SpotlightSearchError: Error, Equatable, LocalizedError {
    case invalidRoot
    case emptyQuery
    case startFailed
    case timedOut
    case resultLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "内容搜索需要本机的有效目录。"
        case .emptyQuery: return "请输入要搜索的文件内容。"
        case .startFailed: return "无法启动系统索引内容搜索。"
        case .timedOut: return "系统索引内容搜索超时，结果可能不完整。"
        case .resultLimitExceeded: return "已保留找到的候选，但系统索引结果超过上限，结果不完整。请缩小搜索目录或内容条件。"
        }
    }
}

/// One initial index gathering only. Completion does not imply that the system
/// has indexed every file. Callers must validate filesystem access and filters.
nonisolated struct SpotlightSearchService: Sendable {
    private let timeout: TimeInterval
    private let maximumResults: Int
    private let makeDriver: @Sendable () -> any SpotlightQueryDriver

    init(timeout: TimeInterval = 30, maximumResults: Int = 10_000) {
        self.init(timeout: timeout, maximumResults: maximumResults, makeDriver: { MetadataSpotlightQueryDriver() })
    }

    init(timeout: TimeInterval, maximumResults: Int, makeDriver: @escaping @Sendable () -> any SpotlightQueryDriver) {
        self.timeout = timeout.isFinite ? max(0.001, timeout) : 30
        self.maximumResults = max(1, maximumResults)
        self.makeDriver = makeDriver
    }

    func search(root: URL, contentQuery: String) -> AsyncThrowingStream<[URL], Error> {
        let text = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = root.standardizedFileURL
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              normalized.path.hasPrefix("/") else {
            return AsyncThrowingStream { $0.finish(throwing: SpotlightSearchError.invalidRoot) }
        }
        guard !text.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: SpotlightSearchError.emptyQuery) }
        }
        return AsyncThrowingStream { continuation in
            let session = SpotlightSearchSession(root: normalized, text: text, timeout: timeout,
                maximumResults: maximumResults, driver: makeDriver(), continuation: continuation)
            continuation.onTermination = { @Sendable _ in session.cancel() }
            session.start()
        }
    }
}

// The driver is private to this feature's implementation and deterministic tests.
// All methods and event callbacks execute on the supplied serial operation queue.
nonisolated enum SpotlightQueryEvent: Sendable {
    case snapshot([URL], finished: Bool, exceededLimit: Bool)
    case failed
}

nonisolated protocol SpotlightQueryDriver: Sendable {
    func start(root: URL, text: String, maximumResults: Int, queue: OperationQueue,
               receive: @escaping @Sendable (SpotlightQueryEvent) -> Void) -> Bool
    func stop()
}

nonisolated private final class SpotlightSearchSession: @unchecked Sendable {
    private let queue: OperationQueue
    private let root: URL
    private let text: String
    private let timeout: TimeInterval
    private let maximumResults: Int
    private let driver: any SpotlightQueryDriver
    private var continuation: AsyncThrowingStream<[URL], Error>.Continuation?
    private var seen = Set<String>()
    private var timeoutWork: DispatchWorkItem?
    private var ended = false

    init(root: URL, text: String, timeout: TimeInterval, maximumResults: Int,
         driver: any SpotlightQueryDriver, continuation: AsyncThrowingStream<[URL], Error>.Continuation) {
        self.root = root
        self.text = text
        self.timeout = timeout
        self.maximumResults = maximumResults
        self.driver = driver
        self.continuation = continuation
        queue = OperationQueue()
        queue.name = "MaXplorer.SpotlightSearch"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    func start() {
        queue.addOperation { [self] in
            guard !ended else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.addOperation { self.finish(SpotlightSearchError.timedOut) }
            }
            timeoutWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
            let started = driver.start(root: root, text: text, maximumResults: maximumResults,
                queue: queue) { [weak self] event in
                    guard let self else { return }
                    // Keep injected drivers and notifications on the same ownership queue.
                    self.queue.addOperation { self.receive(event) }
                }
            if !started { finish(SpotlightSearchError.startFailed) }
        }
    }

    func cancel() { queue.addOperation { self.finish(CancellationError()) } }

    private func receive(_ event: SpotlightQueryEvent) {
        guard !ended else { return }
        switch event {
        case .failed: finish(SpotlightSearchError.startFailed)
        case let .snapshot(urls, finished, exceededLimit):
            var batch: [URL] = []
            for candidate in urls {
                guard candidate.isFileURL, candidate.host == nil || candidate.host == "" || candidate.host == "localhost" else { continue }
                let url = candidate.standardizedFileURL
                guard url.path != root.path, url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"), seen.insert(url.path).inserted else { continue }
                guard seen.count <= maximumResults else {
                    if !batch.isEmpty { continuation?.yield(batch) }
                    finish(SpotlightSearchError.resultLimitExceeded)
                    return
                }
                batch.append(url)
                if batch.count == 256 {
                    continuation?.yield(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { continuation?.yield(batch) }
            if exceededLimit { finish(SpotlightSearchError.resultLimitExceeded) }
            else if finished { finish(nil) }
        }
    }

    private func finish(_ error: Error?) {
        guard !ended else { return }
        ended = true
        timeoutWork?.cancel()
        timeoutWork = nil
        driver.stop()
        let output = continuation
        continuation = nil
        output?.onTermination = nil
        if let error { output?.finish(throwing: error) }
        else { output?.finish() }
    }
}

nonisolated private final class MetadataSpotlightQueryDriver: SpotlightQueryDriver, @unchecked Sendable {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    func start(root: URL, text: String, maximumResults: Int, queue: OperationQueue,
               receive: @escaping @Sendable (SpotlightQueryEvent) -> Void) -> Bool {
        let query = NSMetadataQuery()
        self.query = query
        query.operationQueue = queue
        query.searchScopes = [root]
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemTextContentKey, text)
        query.notificationBatchingInterval = 0.2
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, Notification.Name.NSMetadataQueryDidFinishGathering] {
            let token = NotificationCenter.default.addObserver(forName: name, object: query, queue: queue) { [weak self] notification in
                guard let self, let query = self.query, notification.object as? NSMetadataQuery === query else { return }
                query.disableUpdates()
                let count = query.resultCount
                var urls: [URL] = []
                for index in 0..<min(count, maximumResults) {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    urls.append(URL(fileURLWithPath: path))
                }
                query.enableUpdates()
                receive(.snapshot(urls, finished: notification.name == Notification.Name.NSMetadataQueryDidFinishGathering,
                                  exceededLimit: count > maximumResults))
            }
            observers.append(token)
        }
        return query.start()
    }

    func stop() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        query?.stop()
        query = nil
    }
}
