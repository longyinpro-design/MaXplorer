import Foundation
import Combine
import Darwin
import AppKit
import UniformTypeIdentifiers

/// What the main detail surface is currently showing. The file browser is the
/// default; the others are transient surfaces reached from the sidebar.
enum DetailDestination: Equatable {
    case files
    case copyQueue
    case about
    case settings
}

struct CopyConflictRequest: Identifiable, Equatable {
    let id = UUID()
    let conflictingName: String
    let conflictNumber: Int
    let totalConflicts: Int
}

struct ArchiveConflictRequest: Identifiable, Equatable {
    let id = UUID()
    let archiveName: String
    let conflictCount: Int
    var isCompression = false
}

enum ArchiveConflictResolution {
    case overwrite
    case skip
    case cancel
}

@MainActor
final class FileClipboard: ObservableObject {
    @Published var cutItemURLs: [URL] = []
    @Published var copiedItemURLs: [URL] = []
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
    private static let networkRootURL = URL(string: "maxplorer://network")!

    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = [] {
        didSet {
            scheduleDisplayUpdate()
        }
    }
    /// `items` sorted and filtered for display. Kept as stored state and rebuilt
    /// off the main actor only when the items, sort, or filter change, because
    /// the table, status bar, and selection logic all read it on every render.
    @Published private(set) var displayedItems: [FileItem] = []
    @Published private(set) var displaySections: [FilePresentationSection] = []
    var groupingMode: FileGroupingMode = .none {
        didSet {
            guard groupingMode != oldValue else { return }
            scheduleDisplayUpdate()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isCurrentDirectoryWritable = false
    @Published private(set) var loadsTagColors = false
    @Published private(set) var volumeStats: VolumeCapacityStats?
    @Published private(set) var errorMessage: String?
    @Published var isConnectToServerPresented = false
    @Published var isGoToFolderPresented = false
    @Published var isSelectPatternPresented = false
    @Published var isNewFilePresented = false
    @Published var infoItem: FileItem?
    @Published private(set) var infoItems: [FileItem] = []
    @Published private(set) var isPreparingDuplicates = false
    @Published private(set) var infoDetails: FileInfo?
    @Published private(set) var infoFolderSize: Int64?
    @Published private(set) var isInfoSizeLoading = false
    @Published private(set) var infoError: String?
    @Published var isTransferPlanPresented = false
    @Published private(set) var transferPlan: TransferPlan?
    @Published private(set) var isPreparingTransferPlan = false
    @Published private(set) var transferPlanError: String?
    @Published private(set) var transferPlanScannedCount = 0
    @Published private(set) var transferPlanScannedBytes: Int64 = 0
    @Published var archiveConflictRequest: ArchiveConflictRequest?
    @Published var isArchiveOperationPresented = false
    @Published private(set) var archiveOperationTitle = ""
    @Published private(set) var archiveOperationError: String?
    @Published private(set) var recoveryResidues: [RecoveryResidue] = []
    @Published var isRecoveryNoticePresented = false
    @Published var detailDestination: DetailDestination = .files
    @Published var copyConflictRequest: CopyConflictRequest?
    @Published var pathText: String
    @Published var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleDisplayUpdate(debounceMilliseconds: 50)
        }
    }
    let filterFocusProxy = FilterFocusProxy()

    @Published var searchQuery = "" {
        didSet {
            guard isSearchActive, searchQuery != oldValue else { return }
            scheduleSearch(debounceMilliseconds: 250)
        }
    }
    @Published var searchScope: SearchScope = .currentFolder {
        didSet {
            guard isSearchActive, searchScope != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published var searchMode: SearchMatchMode = .contains {
        didSet {
            guard isSearchActive, searchMode != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var isSearchActive = false
    @Published private(set) var isSearching = false
    @Published private(set) var searchScannedCount = 0
    @Published private(set) var searchSkippedCount = 0
    @Published private(set) var searchErrorMessage: String?
    @Published private(set) var searchScopeRoot: URL?
    let searchFocusProxy = FilterFocusProxy()
    @Published var selectedItemIDs: Set<FileItem.ID> = []
    @Published var sortOrder = FileSortDescriptor.fallback.comparators {
        didSet {
            guard sortOrder != oldValue else { return }
            scheduleDisplayUpdate()
            if !isRestoringSort, let sort = FileSortDescriptor(sortOrder) {
                FolderSortStore.shared.remember(sort, for: currentURL)
            }
        }
    }
    @Published var renameRequest: FileItem?
    @Published var trashRequest: [FileItem] = []
    @Published var quickViewContent: QuickViewContent?
    @Published var showHiddenFiles = false {
        didSet {
            reload()
        }
    }
    @Published var showAliases = true {
        didSet {
            guard showAliases != oldValue else { return }
            scheduleDisplayUpdate()
        }
    }
    @Published var isIntegratedTerminalPresented = false
    @Published var isReadmePresented = false
    @Published var isUndoHistoryPresented = false
    @Published var isRecentFilesPresented = false
    @Published var isBatchRenamePresented = false
    @Published var batchRenameOptions = BatchRenameOptions()
    @Published var batchRenamePreview: [BatchRenamePreviewItem] = []
    @Published var batchRenamePreviewIsLoading = false
    @Published private(set) var batchRenameIsRunning = false
    @Published private(set) var batchRenameProgress: Double = 0

    let fileSystem: any FileSystemService
    let copyQueue: CopyQueueViewModel
    private let fileClipboard: FileClipboard
    private let favoritesStore: FavoritesStore
    let undoJournal: FileUndoJournal
    private var undoJournalObservation: AnyCancellable?
    private var undoBatchAccumulators: [UUID: UndoBatchAccumulator] = [:]
    /// Guards against a second ⌘Z while the first undo is still running.
    private var isUndoInProgress = false
    private var batchRenameSources: [URL] = []
    private var batchRenamePreviewOptions: BatchRenameOptions?
    private var batchRenamePreviewTask: Task<Void, Never>?
    private var batchRenameExecutionTask: Task<Void, Never>?
    private let networkBrowser = NetworkBrowserService()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var loadGeneration = 0
    private var selectionAnchorID: FileItem.ID?
    private var destinationBeforeAuxiliaryDetail: DetailDestination = .files
    private var listingOptions = DirectoryListingOptions(columns: FileColumn.defaultVisible)
    private var conflictSession: ConflictSession?
    private var conflictPreparationGeneration = 0
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitorReloadTask: Task<Void, Never>?
    private var clipboardObservation: AnyCancellable?
    private var favoritesObservation: AnyCancellable?
    private var isRestoringSort = false
    private var displayGeneration = 0
    private var displayTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private var transferPlanTask: Task<Void, Never>?
    private var transferPlanGeneration = 0
    private var pendingTransfer: PendingTransfer?
    private var archiveOperationTask: Task<Void, Never>?
    private var archiveOperationGeneration = 0
    private var pendingArchiveCompression: PendingArchiveCompression?
    private var pendingArchiveExtraction: PendingArchiveExtraction?
    private var didScanRecoveryResidues = false
    private var isAwaitingLoadDisplay = false
    private var progressiveLoadItems: [FileItem] = []
    private var lastProgressiveDisplayUptime: UInt64 = 0
    private var pendingCompletedURLs: [URL] = []
    private var pendingCompletedURLSet: Set<URL> = []
    private var completionFlushTask: Task<Void, Never>?
    private let volumeCatalog = VolumeCatalog.shared
    private var volumeCatalogObservation: AnyCancellable?
    private var volumeStatsRefreshTask: Task<Void, Never>?
    private var volumeStatsLoadTask: Task<Void, Never>?
    private static let completionFlushDelayMilliseconds = 400
    private static let maximumIncrementalRefreshCount = 400
    private static let progressiveDisplayIntervalNanoseconds: UInt64 = 200_000_000

    private struct ConflictSession {
        nonisolated enum Operation: Sendable {
            case copy(maximumConcurrentCopies: Int)
            case move(shouldClearCut: Bool)
        }
        let allSources: [URL]
        let destinationDirectory: URL
        let operation: Operation
        var approvedItems: [(source: URL, shouldOverwrite: Bool)]
        var remainingConflictIndices: [Int]
        let totalConflicts: Int
    }

    private struct ConflictPreflightResult: Sendable {
        let approvedSources: [URL]
        let conflictIndices: [Int]
    }

    private struct PendingTransfer {
        let sources: [URL]
        let destinationDirectory: URL
        let operation: ConflictSession.Operation
    }

    private struct PendingArchiveCompression {
        let items: [URL]
        let destination: URL
        let format: ArchiveFormat
    }

    private struct PendingArchiveExtraction {
        let staging: URL
        let destinationDirectory: URL
        let items: [URL]
        let conflicts: [URL]
        let archiveName: String
    }

    init(
        fileSystem: FileSystemService,
        fileClipboard: FileClipboard,
        favoritesStore: FavoritesStore,
        copyQueue: CopyQueueViewModel,
        undoJournal: FileUndoJournal
    ) {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        self.fileSystem = fileSystem
        self.fileClipboard = fileClipboard
        self.favoritesStore = favoritesStore
        self.copyQueue = copyQueue
        self.undoJournal = undoJournal
        self.currentURL = homeURL
        self.pathText = homeURL.path
        self.sortOrder = FolderSortStore.shared.sort(for: homeURL).comparators
        self.copyQueue.observeItemCompletions { [weak self] sourceURL, destinationURL, operation, shouldOverwrite, batchID in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.recordUndoCompletion(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    operation: operation,
                    shouldOverwrite: shouldOverwrite,
                    batchID: batchID
                )

                if self.isSearchActive {
                    self.scheduleSearch(debounceMilliseconds: 400)
                    return
                }

                guard destinationURL.deletingLastPathComponent().standardizedFileURL == self.currentURL.standardizedFileURL else {
                    return
                }

                self.enqueueCompletedItem(destinationURL)
            }
        }
        self.copyQueue.observeBatchCompletions { [weak self] batchID in
            Task { @MainActor [weak self] in
                self?.flushUndoBatchIfSettled(batchID)
            }
        }
        self.copyQueue.observeMoveCompletions { [weak self] sourceURL in
            self?.clearCutItems(containing: [sourceURL])
        }
        self.undoJournalObservation = undoJournal.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.clipboardObservation = fileClipboard.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.favoritesObservation = favoritesStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.volumeCatalogObservation = volumeCatalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        startVolumeStatsRefreshLoop()

        // Defer the initial load to the next main-actor tick. Calling reload()
        // directly here would publish @Published changes (isLoading/errorMessage)
        // while SwiftUI is still instantiating this @StateObject during a view
        // update, which triggers "Publishing changes from within view updates".
        Task { @MainActor [weak self] in
            self?.startMonitoringCurrentFolder()
            self?.reload()
        }
    }

    deinit {
        monitorReloadTask?.cancel()
        folderMonitor?.cancel()
        completionFlushTask?.cancel()
        displayTask?.cancel()
        searchTask?.cancel()
        infoTask?.cancel()
        duplicateTask?.cancel()
        transferPlanTask?.cancel()
        archiveOperationTask?.cancel()
        undoJournalObservation?.cancel()
        volumeStatsRefreshTask?.cancel()
        volumeStatsLoadTask?.cancel()
    }

    var cutItemURLs: [URL] {
        fileClipboard.cutItemURLs
    }

    var copiedItemURLs: [URL] {
        fileClipboard.copiedItemURLs
    }

    var pinnedFavoriteURLs: [URL] {
        favoritesStore.pinnedURLs
    }

    var removedBuiltInFavoriteURLs: [URL] {
        favoritesStore.removedBuiltInURLs
    }

    /// Drops any sort/filter result computed for a folder that is no longer the
    /// current loading target, so stale rows cannot briefly replace the spinner.
    private func invalidatePendingDisplayUpdate() {
        displayGeneration += 1
        displayTask?.cancel()
        displayTask = nil
        isAwaitingLoadDisplay = false
    }

    /// Rebuilds the displayed rows without blocking the main actor. Every input
    /// change bumps `displayGeneration` so only the newest result is applied;
    /// filter typing waits briefly so keystrokes are not each sorted and
    /// filtered against the whole folder.
    private func scheduleDisplayUpdate(debounceMilliseconds: Int = 0) {
        displayGeneration += 1
        let generation = displayGeneration
        let itemsSnapshot = items
        let descriptor = FileSortDescriptor(sortOrder) ?? FolderSortStore.shared.defaultSort
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let showAliases = showAliases
        let grouping = groupingMode

        displayTask?.cancel()
        displayTask = Task { [weak self] in
            if debounceMilliseconds > 0 {
                guard (try? await Task.sleep(for: .milliseconds(debounceMilliseconds))) != nil else {
                    return
                }
            }

            let sections = await Task.detached(priority: .userInitiated) {
                let sorted = FileDisplayPipeline.displayedItems(
                    from: itemsSnapshot,
                    descriptor: descriptor,
                    query: query,
                    showAliases: showAliases
                )
                return FileBrowserPresentation.sections(from: sorted, grouping: grouping)
            }.value

            guard let self, generation == self.displayGeneration else {
                return
            }

            self.displaySections = sections
            self.displayedItems = FileBrowserPresentation.flattenedItems(in: sections)
            if self.isAwaitingLoadDisplay {
                self.isAwaitingLoadDisplay = false
                self.isLoading = false
            }
        }
    }

    var selectedItem: FileItem? {
        items.first { selectedItemIDs.contains($0.id) }
    }

    var selectedItems: [FileItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedFileSize: Int64? {
        let fileSizes = selectedItems.compactMap { item in
            item.isDirectory && !item.isPackage ? nil : item.size
        }
        guard !fileSizes.isEmpty else { return nil }
        return fileSizes.reduce(0, +)
    }

    var canGoBack: Bool { !isSearchActive && !backStack.isEmpty }
    var canGoForward: Bool { !isSearchActive && !forwardStack.isEmpty }
    var canGoUp: Bool { !isSearchActive && currentURL.isFileURL && currentURL.path != "/" }
    var canCreateFolder: Bool { !isSearchActive && currentURL.isFileURL && isCurrentDirectoryWritable }
    var canSearch: Bool { currentURL.isFileURL }
    var canCutSelectedItem: Bool { selectedItems.contains { !$0.isNetworkLocation } }
    var canCopySelectedItem: Bool { selectedItems.contains { !$0.isNetworkLocation } }
    var canDuplicateSelected: Bool { !isPreparingDuplicates && selectedItems.contains { !$0.isNetworkLocation } }
    var canShowInfo: Bool { selectedItem != nil }
    var canUndo: Bool { undoJournal.canUndo }
    var undoActionTitle: String? { undoJournal.undoActionTitle }
    var canCompressSelected: Bool {
        let items = selectedItems.filter { !$0.isNetworkLocation }
        guard let firstParent = items.first?.url.deletingLastPathComponent() else {
            return false
        }
        return items.allSatisfy { $0.url.deletingLastPathComponent() == firstParent }
    }
    func canCompress(format: ArchiveFormat) -> Bool {
        canCompressSelected && (format != .gzip || (selectedItems.count == 1 && selectedItem?.isDirectory == false))
    }

    var canExtractSelected: Bool {
        guard selectedItems.count == 1, let selectedItem, !selectedItem.isNetworkLocation else {
            return false
        }
        return ArchiveService.isArchive(selectedItem.url)
    }
    var canPasteItems: Bool { !isSearchActive && currentURL.isFileURL && (!cutItemURLs.isEmpty || !copiedItemURLs.isEmpty || !SystemActions.fileURLsFromPasteboard().isEmpty) }
    var canPasteCutItems: Bool { !isSearchActive && currentURL.isFileURL && !cutItemURLs.isEmpty }
    var canTrashSelectedItems: Bool { selectedItems.contains { !$0.isNetworkLocation } }
    var selectedItemsRequirePermanentDeletion: Bool {
        selectedItems.contains(where: requiresPermanentDeletion)
    }
    var canQuickViewSelectedItem: Bool {
        guard selectedItems.count == 1, let selectedItem else {
            return false
        }

        return canQuickView(selectedItem)
    }
    var isBrowsingNetwork: Bool { currentURL == Self.networkRootURL }
    var currentLocationText: String {
        if currentURL == Self.networkRootURL {
            return "网络"
        }

        return currentURL.isFileURL ? currentURL.path : currentURL.absoluteString
    }

    var tabTitle: String {
        if isSearchActive {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? "搜索" : "搜索：\(query)"
        }

        if currentURL == Self.networkRootURL {
            return "网络"
        }

        if currentURL.isFileURL {
            if currentURL.path == "/" {
                return "/"
            }

            return currentURL.lastPathComponent.isEmpty ? currentURL.path : currentURL.lastPathComponent
        }

        return currentURL.host() ?? currentURL.absoluteString
    }

    var sidebarLocations: [SidebarLocation] {
        let builtInFavorites = builtInFavoriteLocations()
        let removedBuiltInURLs = Set(removedBuiltInFavoriteURLs.map(\.standardizedFileURL))
        var locations = builtInFavorites.filter { !removedBuiltInURLs.contains($0.url.standardizedFileURL) }
        let builtInFavoriteURLs = Set(builtInFavorites.map { $0.url.standardizedFileURL })

        for url in pinnedFavoriteURLs where !builtInFavoriteURLs.contains(url.standardizedFileURL) {
            locations.append(
                SidebarLocation(
                    name: sidebarName(for: url),
                    url: url,
                    group: .favorites,
                    systemImage: "folder.fill",
                    canRemoveFromFavorites: true
                )
            )
        }

        locations.append(
            SidebarLocation(
                name: "浏览网络",
                url: Self.networkRootURL,
                group: .network,
                systemImage: "network"
            )
        )

        for volume in volumeCatalog.mountedVolumes where volume.url.path != "/" {
            locations.append(
                SidebarLocation(
                    name: volume.name,
                    url: volume.url,
                    group: volume.isLocal ? .devices : .network,
                    systemImage: volume.isLocal ? "externaldrive.fill" : "server.rack"
                )
            )
        }

        return locations
    }

    private func builtInFavoriteLocations() -> [SidebarLocation] {
        [
            SidebarLocation(name: "个人文件夹", url: FileManager.default.homeDirectoryForCurrentUser, group: .favorites, systemImage: "house.fill", canRemoveFromFavorites: true),
            SidebarLocation(name: "桌面", url: homeSubfolder("Desktop"), group: .favorites, systemImage: "desktopcomputer", canRemoveFromFavorites: true),
            SidebarLocation(name: "文稿", url: homeSubfolder("Documents"), group: .favorites, systemImage: "folder.fill", canRemoveFromFavorites: true),
            SidebarLocation(name: "下载", url: homeSubfolder("Downloads"), group: .favorites, systemImage: "arrow.down.circle.fill", canRemoveFromFavorites: true)
        ]
    }

    func reload() {
        if isSearchActive {
            scheduleSearch()
            return
        }

        invalidatePendingDisplayUpdate()
        Task { await self.reload(selecting: nil) }
    }

    func focusFilterField() {
        filterFocusProxy.focus()
    }

    func showSelectPattern() {
        isSelectPatternPresented = true
    }

    // MARK: - Search

    func beginSearch(scopeRoot: URL, query: String = "") {
        guard scopeRoot.isFileURL else { return }

        invalidatePendingDisplayUpdate()
        loadGeneration += 1
        stopMonitoringCurrentFolder()
        backStack.removeAll()
        forwardStack.removeAll()

        isSearchActive = true
        searchScopeRoot = scopeRoot
        currentURL = scopeRoot
        pathText = scopeRoot.path
        detailDestination = .files
        filterText = ""
        selectedItemIDs = []
        selectionAnchorID = nil
        items = []
        displayedItems = []
        displaySections = []
        volumeStats = nil
        searchErrorMessage = nil
        searchScannedCount = 0
        searchSkippedCount = 0
        isLoading = false

        if !query.isEmpty {
            searchQuery = query
        }

        refreshVolumeStats()
        scheduleSearch()
        focusSearchField()
    }

    func endSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        isSearchActive = false
        isSearching = false
        isLoading = false
        searchErrorMessage = nil
        searchScannedCount = 0
        searchSkippedCount = 0
        searchScopeRoot = nil
    }

    func focusSearchField() {
        searchFocusProxy.focus()
    }

    func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isLoading = false
    }

    func selectItems(matching query: String, mode: SearchMatchMode) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let ids = displayedItems
            .filter { mode.matches($0.name, query: query) }
            .map(\.id)
        selectedItemIDs = Set(ids)
        selectionAnchorID = ids.first
    }

    private func scheduleSearch(selecting itemID: FileItem.ID? = nil, debounceMilliseconds: Int = 0) {
        guard isSearchActive else { return }

        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if debounceMilliseconds > 0 {
                guard (try? await Task.sleep(for: .milliseconds(debounceMilliseconds))) != nil else {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            await self.performSearch(selecting: itemID, generation: generation)
        }
    }

    private func performSearch(selecting itemID: FileItem.ID?, generation: Int) async {
        guard generation == searchGeneration, isSearchActive else { return }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            items = []
            displayedItems = []
            displaySections = []
            selectedItemIDs = []
            selectionAnchorID = nil
            isSearching = false
            isLoading = false
            searchErrorMessage = nil
            searchScannedCount = 0
            searchSkippedCount = 0
            return
        }

        let root = await resolvedSearchRoot()
        guard !Task.isCancelled, generation == searchGeneration, isSearchActive else { return }
        guard let root else {
            isSearching = false
            isLoading = false
            searchErrorMessage = "当前搜索位置不可用。"
            return
        }

        invalidatePendingDisplayUpdate()
        loadGeneration += 1
        items = []
        displayedItems = []
        displaySections = []
        selectedItemIDs = []
        selectionAnchorID = nil
        isLoading = true
        isSearching = true
        searchErrorMessage = nil
        searchScannedCount = 0
        searchSkippedCount = 0
        refreshVolumeStats()

        let stream = FileSearchService(fileSystem: fileSystem).search(
            root: root,
            query: query,
            mode: searchMode,
            showHiddenFiles: showHiddenFiles,
            options: listingOptions
        )

        do {
            for try await event in stream {
                guard generation == searchGeneration, isSearchActive else { return }
                switch event {
                case .batch(let batch):
                    items.append(contentsOf: batch)
                case .progress(let progress):
                    searchScannedCount = progress.scannedCount
                    searchSkippedCount = progress.skippedCount
                case .finished(let summary):
                    searchScannedCount = summary.scannedCount
                    searchSkippedCount = summary.skippedCount
                }
            }

            guard generation == searchGeneration, isSearchActive else { return }
            isSearching = false
            isLoading = false
            if let itemID, items.contains(where: { $0.id == itemID }) {
                selectedItemIDs = [itemID]
                selectionAnchorID = itemID
            }
        } catch is CancellationError {
            guard generation == searchGeneration else { return }
            isSearching = false
            isLoading = false
        } catch {
            guard generation == searchGeneration else { return }
            isSearching = false
            isLoading = false
            searchErrorMessage = error.localizedDescription
        }
    }

    private func resolvedSearchRoot() async -> URL? {
        guard let scopeRoot = searchScopeRoot, scopeRoot.isFileURL else { return nil }
        guard searchScope == .currentVolume else { return scopeRoot }
        return await Task.detached(priority: .userInitiated) {
            var info = statfs()
            guard statfs(scopeRoot.path, &info) == 0 else { return nil as URL? }
            let mountPoint = withUnsafePointer(to: &info.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            return URL(fileURLWithPath: mountPoint, isDirectory: true)
        }.value
    }

    /// Updates which extra (slow) per-file metadata is fetched, reloading only
    /// if it actually changed.
    func setListingOptions(_ options: DirectoryListingOptions) {
        guard options != listingOptions else {
            return
        }

        listingOptions = options
        reload()
    }

    private func reload(selecting itemID: FileItem.ID?) async {
        if isSearchActive {
            scheduleSearch(selecting: itemID)
            return
        }

        invalidatePendingDisplayUpdate()
        let target = currentURL
        let showHiddenFiles = showHiddenFiles
        let fileSystem = fileSystem
        let listingOptions = listingOptions
        let isRemoteVolume = target != Self.networkRootURL && isOnRemoteMountedVolume(target)
        loadsTagColors = target.isFileURL && !isRemoteVolume
        loadGeneration += 1
        let generation = loadGeneration
        progressiveLoadItems.removeAll(keepingCapacity: true)
        lastProgressiveDisplayUptime = 0
        isLoading = true
        isCurrentDirectoryWritable = false
        errorMessage = nil
        refreshVolumeStats()
        Task {
            do {
                let loadedItems: [FileItem]
                if target == Self.networkRootURL {
                    loadedItems = await networkItems()
                } else {
                    let initialOptions = isRemoteVolume ? DirectoryListingOptions() : listingOptions
                    loadedItems = try await fileSystem.listDirectory(
                        at: target,
                        showHiddenFiles: showHiddenFiles,
                        options: initialOptions,
                        onPartial: { batch in
                            await self.receiveProgressiveBatch(batch, generation: generation)
                        }
                    )
                }

                guard generation == loadGeneration else {
                    return
                }

                let writable = await Task.detached(priority: .utility) {
                    target.isFileURL && FileManager.default.isWritableFile(atPath: target.path)
                }.value
                guard generation == loadGeneration else { return }
                isCurrentDirectoryWritable = writable
                progressiveLoadItems.removeAll(keepingCapacity: false)
                isAwaitingLoadDisplay = true
                applyLoadedItems(loadedItems, selecting: itemID)
            } catch {
                guard generation == loadGeneration else {
                    return
                }

                progressiveLoadItems.removeAll(keepingCapacity: false)
                items = []
                isAwaitingLoadDisplay = false
                displayedItems = []
                displaySections = []
                selectedItemIDs = []
                selectionAnchorID = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Applies an intermediate listing batch without waiting for enumeration to
    /// finish. Updates are throttled because each one re-sorts the accumulated
    /// rows off the main actor.
    private func receiveProgressiveBatch(_ batch: [FileItem], generation: Int) {
        guard generation == loadGeneration else { return }
        progressiveLoadItems.append(contentsOf: batch)

        let now = DispatchTime.now().uptimeNanoseconds
        if lastProgressiveDisplayUptime != 0,
           now - lastProgressiveDisplayUptime < Self.progressiveDisplayIntervalNanoseconds {
            return
        }

        lastProgressiveDisplayUptime = now
        items = progressiveLoadItems
    }

    /// Queries capacity off the main actor so SMB or busy disks cannot stall a
    /// render. Stale results for a previous folder are discarded.
    private func refreshVolumeStats() {
        let target = currentURL
        volumeStatsLoadTask?.cancel()
        volumeStatsLoadTask = Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                VolumeCapacityReader.stats(for: target)
            }.value
            guard !Task.isCancelled, let self, self.currentURL == target else { return }
            self.volumeStats = stats
        }
    }

    private func startVolumeStatsRefreshLoop() {
        volumeStatsRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    self.refreshVolumeStats()
                }
                guard (try? await Task.sleep(for: .seconds(15))) != nil else {
                    return
                }
            }
        }
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        if isSearchActive {
            endSearch()
        }

        detailDestination = .files
        guard url != currentURL else {
            reload()
            return
        }

        if recordHistory {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }

        currentURL = url
        pathText = url == Self.networkRootURL ? "网络" : url.path
        filterText = ""
        reapplyRememberedSort()
        startMonitoringCurrentFolder()
        reload()
    }

    /// Restores the sort remembered for the current folder, or the default
    /// sort from Settings, without recording it as a new choice.
    func reapplyRememberedSort() {
        let comparators = FolderSortStore.shared.sort(for: currentURL).comparators
        guard comparators != sortOrder else { return }
        isRestoringSort = true
        sortOrder = comparators
        isRestoringSort = false
    }

    func showReadme() {
        isReadmePresented = true
    }

    private func startMonitoringCurrentFolder() {
        stopMonitoringCurrentFolder()
        guard !isSearchActive else { return }
        guard currentURL.isFileURL else { return }

        // DispatchSource directory events are reliable for local filesystems,
        // but SMB writes can produce reload storms while a queued copy is active.
        guard !isOnRemoteMountedVolume(currentURL) else { return }

        let descriptor = open(currentURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let monitoredURL = currentURL.standardizedFileURL
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, self.currentURL.standardizedFileURL == monitoredURL else { return }
            let event = source?.data ?? []
            // While a transfer writes into this folder, its completion batches
            // keep the rows current. Wait for the folder to go quiet before
            // paying for a full enumeration again.
            let debounceMilliseconds = self.hasActiveTransfer(into: self.currentURL) ? 1200 : 300
            self.monitorReloadTask?.cancel()
            self.monitorReloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
                guard !Task.isCancelled, let self else { return }
                if event.contains(.delete) || event.contains(.rename) {
                    self.startMonitoringCurrentFolder()
                }
                await self.reload(selecting: nil)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }

        folderMonitor = source
        source.resume()
    }

    private func stopMonitoringCurrentFolder() {
        monitorReloadTask?.cancel()
        monitorReloadTask = nil
        folderMonitor?.cancel()
        folderMonitor = nil
    }

    private func hasActiveTransfer(into directory: URL) -> Bool {
        let target = directory.standardizedFileURL
        return copyQueue.items.contains { item in
            item.state.isActive
                && item.destinationURL.deletingLastPathComponent().standardizedFileURL == target
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else {
            return
        }

        forwardStack.append(currentURL)
        navigate(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else {
            return
        }

        backStack.append(currentURL)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else {
            return
        }

        navigate(to: currentURL.deletingLastPathComponent())
    }

    func submitPath() {
        let expandedPath = NSString(string: pathText).expandingTildeInPath
        if expandedPath.trimmingCharacters(in: .whitespacesAndNewlines) == "网络"
            || expandedPath.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Network") == .orderedSame {
            navigate(to: Self.networkRootURL)
            return
        }

        if let networkURL = Self.serverURL(from: expandedPath) {
            connectToServer(networkURL)
            return
        }

        let url = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "路径不存在或不是文件夹。"
            pathText = currentURL.path
            return
        }

        navigate(to: url)
    }

    func showGoToFolder() {
        isGoToFolderPresented = true
    }

    func navigateToManualFolder(_ input: String) -> URL? {
        guard let url = manualFolderURL(from: input), isDirectory(url) else {
            errorMessage = "未找到路径"
            return nil
        }

        navigate(to: url.standardizedFileURL)
        return url.standardizedFileURL
    }

    func showConnectToServer() {
        isConnectToServerPresented = true
    }

    func connectToServer(_ address: String, onValidated: (URL) -> Void = { _ in }) {
        guard let serverURL = Self.serverURL(from: address) else {
            errorMessage = "请输入有效的服务器地址，例如 smb://server/share。"
            return
        }

        onValidated(serverURL)
        connectToServer(serverURL)
    }

    func openSelected() {
        guard let selectedItem else {
            return
        }

        if selectedItem.isNetworkLocation {
            SystemActions.connectToServer(selectedItem.url)
            return
        }

        if let navigationURL = selectedItem.navigationURL {
            navigate(to: navigationURL)
        } else {
            if !selectedItem.isDirectory { RecentFilesStore.shared.record(selectedItem.url) }
            SystemActions.open(selectedItem.url)
        }
    }

    func openRecentFile(_ url: URL) {
        Task {
            do {
                let item = try await fileSystem.fileItem(at: url, options: DirectoryListingOptions())
                guard !item.isDirectory, !item.isNetworkLocation else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                RecentFilesStore.shared.record(url)
                SystemActions.open(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func quickViewSelectedItem() {
        guard let selectedItem, canQuickView(selectedItem) else {
            return
        }

        Task {
            do {
                quickViewContent = try await fileSystem.quickViewContent(for: selectedItem.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearQuickView() {
        quickViewContent = nil
    }

    func canQuickView(_ item: FileItem) -> Bool {
        !item.isNetworkLocation && !item.isDirectory && !item.isPackage
    }

    func openWithApplications(for item: FileItem) -> [OpenWithApplication] {
        guard canOpenWith(item) else {
            return []
        }

        return SystemActions.applicationsForOpening(item.url)
    }

    func openSelected(with application: OpenWithApplication) {
        guard let selectedItem, canOpenWith(selectedItem) else {
            return
        }

        if !selectedItem.isDirectory { RecentFilesStore.shared.record(selectedItem.url) }
        SystemActions.open(selectedItem.url, with: application)
    }

    func canOpenWith(_ item: FileItem) -> Bool {
        !item.isNetworkLocation
    }

    func requestRenameSelected() {
        guard let selectedItem else {
            return
        }

        renameRequest = selectedItem
    }

    func requestTrashSelected() {
        let trashableItems = selectedItems.filter { !$0.isNetworkLocation }
        guard !trashableItems.isEmpty else {
            return
        }

        trashRequest = trashableItems
    }

    // MARK: - Item information

    func showInfoSelected() {
        infoItems = selectedItems.filter { !$0.isNetworkLocation }
        guard let first = infoItems.first else { return }
        showInfo(for: first)
    }

    func showInfo(for item: FileItem) {
        infoItem = item
        infoDetails = nil
        infoFolderSize = nil
        isInfoSizeLoading = true
        infoError = nil
        infoTask?.cancel()
        infoTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await BasicFileActions.fileInfo(for: item)
                }
                let details = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.infoItem?.id == item.id else { return }
                self.infoDetails = details
                if details.isDirectory {
                    let size = try await SafeFileOperations.totalByteCount(for: item.url)
                    guard !Task.isCancelled, self.infoItem?.id == item.id else { return }
                    self.infoFolderSize = size
                } else {
                    self.infoFolderSize = details.size
                }
                self.isInfoSizeLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.infoItem?.id == item.id else { return }
                self.infoError = error.localizedDescription
                self.isInfoSizeLoading = false
            }
        }
    }

    func cancelInfoLoad() {
        infoTask?.cancel()
        infoTask = nil
        isInfoSizeLoading = false
    }

    // MARK: - New file

    func showNewFile() {
        guard canCreateFolder else { return }
        isNewFilePresented = true
    }

    func createFile(named name: String) async {
        guard canCreateFolder else { return }
        let directory = currentURL
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try BasicFileActions.createEmptyFile(named: name, in: directory)
            }
            let target = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            if currentURL == directory { await reload(selecting: target) }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Duplicate / transfer to

    func duplicateSelected() {
        guard canDuplicateSelected else { return }
        let items = selectedItems.filter { !$0.isNetworkLocation }
        let reserved = Set(copyQueue.items.filter { $0.state.isActive }.map(\.destinationURL))
        isPreparingDuplicates = true
        duplicateTask = Task { [weak self] in
            defer { self?.isPreparingDuplicates = false }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try BasicFileActions.duplicateDestinations(for: items, reserved: reserved)
                }
                let duplicates = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self else { return }
                self.copyQueue.enqueueDuplicates(duplicates)
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func chooseDestination(for operation: CopyQueueOperation) {
        guard canCopySelectedItem else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = operation == .move ? "移动" : "复制"
        panel.message = operation == .move
            ? "选择要移动到哪个文件夹"
            : "选择要复制到哪个文件夹"
        if let lastDestinationURL = lastTransferDestinationURL {
            panel.directoryURL = lastDestinationURL
        }

        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rememberTransferDestination(destination)
                self.transferSelected(to: destination, operation: operation)
            }
        }
    }

    private func transferSelected(to destination: URL, operation: CopyQueueOperation) {
        let sources = selectedItems
            .filter { !$0.isNetworkLocation }
            .map(\.url)
        guard !sources.isEmpty else {
            errorMessage = "没有可传输的项目。"
            return
        }

        let destination = destination.standardizedFileURL
        switch operation {
        case .copy:
            beginConflictResolution(
                sources: sources,
                to: destination,
                operation: .copy(maximumConcurrentCopies: copyQueue.maximumConcurrentCopies)
            )
        case .move:
            beginConflictResolution(
                sources: sources,
                to: destination,
                operation: .move(shouldClearCut: false)
            )
        }
    }

    private static let lastTransferDestinationKey = "LastTransferDestination"

    private var lastTransferDestinationURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastTransferDestinationKey) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func rememberTransferDestination(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastTransferDestinationKey)
    }

    // MARK: - Batch rename

    var batchRenameCanApply: Bool {
        !batchRenameIsRunning
            && !batchRenamePreviewIsLoading
            && batchRenamePreviewOptions == batchRenameOptions
            && batchRenamePreview.allSatisfy { $0.issue == nil }
            && batchRenamePreview.contains { $0.isChange }
    }

    var batchRenameItemCount: Int {
        batchRenameSources.count
    }

    var batchRenameChangeCount: Int {
        batchRenamePreview.filter(\.isChange).count
    }

    var batchRenameIssueCount: Int {
        batchRenamePreview.filter { $0.issue != nil }.count
    }

    func beginBatchRename() {
        guard !batchRenameIsRunning else { return }
        let items = selectedItems.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard !items.isEmpty else { return }

        batchRenameSources = items.map(\.url)
        batchRenamePreview = []
        batchRenameProgress = 0
        isBatchRenamePresented = true
        refreshBatchRenamePreview(debounce: false)
    }

    /// Recomputes the preview off the main thread. Typing in the sheet calls
    /// this quickly, so the call is debounced and the previous task cancelled.
    func refreshBatchRenamePreview(debounce: Bool = true) {
        guard !batchRenameSources.isEmpty else { return }

        batchRenamePreviewTask?.cancel()
        batchRenamePreviewIsLoading = true

        let urls = batchRenameSources
        let options = batchRenameOptions
        batchRenamePreviewTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }

            let preview = await Task.detached(priority: .userInitiated) {
                BatchRenameService.preview(urls: urls, options: options)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.batchRenamePreview = preview
            self.batchRenamePreviewOptions = options
            self.batchRenamePreviewIsLoading = false
        }
    }

    func cancelBatchRename() {
        batchRenameExecutionTask?.cancel()
        batchRenamePreviewTask?.cancel()
    }

    func applyBatchRename() {
        guard batchRenameCanApply else { return }

        let preview = batchRenamePreview
        batchRenameIsRunning = true
        batchRenameProgress = 0

        // The task clears `batchRenameExecutionTask` when it finishes, so the
        // strong capture only lives as long as the rename itself.
        batchRenameExecutionTask = Task { [self] in
            let outcome = await BatchRenameService.execute(preview) { done, total in
                let fraction = total > 0 ? Double(done) / Double(total) : 0
                Task { @MainActor in
                    self.batchRenameProgress = fraction
                }
            }

            self.batchRenameIsRunning = false
            self.batchRenameExecutionTask = nil
            self.isBatchRenamePresented = false

            if !outcome.renamed.isEmpty {
                let states = await FileUndoService.states(of: outcome.renamed.map(\.to))
                self.undoJournal.record(
                    FileUndoEntry(kind: .renameBatch(items: outcome.renamed, expected: states))
                )
            }

            await self.reload(selecting: nil)

            if !outcome.failures.isEmpty {
                self.errorMessage = outcome.failures.joined(separator: "\n")
            } else if outcome.cancelled {
                self.errorMessage = "批量重命名已取消，已完成 \(outcome.renamed.count) 项。"
            }
        }
    }

    // MARK: - Undo

    func showUndoHistory() {
        isUndoHistoryPresented = true
    }

    func undoLastOperation() async {
        guard !isUndoInProgress, let entry = undoJournal.nextUndoableEntry else { return }
        isUndoInProgress = true
        defer { isUndoInProgress = false }

        do {
            let outcome = try await FileUndoService.undo(entry)
            switch outcome {
            case .completed:
                undoJournal.remove(id: entry.id)
                await reload(selecting: nil)
            case .partial(let remaining, let failures):
                undoJournal.replace(remaining)
                await reload(selecting: nil)
                errorMessage = failures.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recordUndoCompletion(
        sourceURL: URL,
        destinationURL: URL,
        operation: CopyQueueOperation,
        shouldOverwrite: Bool,
        batchID: UUID
    ) {
        var accumulator = undoBatchAccumulators[batchID] ?? UndoBatchAccumulator()
        if shouldOverwrite {
            accumulator.recordOverwrite(destinationURL)
        } else {
            switch operation {
            case .copy:
                accumulator.recordCopy(created: destinationURL)
            case .move:
                accumulator.recordMove(from: sourceURL, to: destinationURL)
            }
        }
        undoBatchAccumulators[batchID] = accumulator

        flushUndoBatchIfSettled(batchID)
    }

    /// Overwrites cannot be reverted, so the journal keeps a marked entry that
    /// the history sheet shows as "不可撤销" instead of offering a fake undo.
    private func recordNonRestorableOverwrite(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let detail: String
        if let name = urls.first?.lastPathComponent, urls.count == 1 {
            detail = "“\(name)”被覆盖，此操作无法撤销。"
        } else {
            detail = "\(urls.count) 个项目被覆盖，此操作无法撤销。"
        }
        undoJournal.record(
            FileUndoEntry(kind: .notRestorable(action: "覆盖", detail: detail))
        )
    }

    /// Records one finished copy/move batch as a single history entry. Queued
    /// items finish one after another, so this waits until nothing of the
    /// batch is pending or running.
    private func flushUndoBatchIfSettled(_ batchID: UUID) {
        guard let accumulator = undoBatchAccumulators[batchID] else { return }
        guard !copyQueue.hasActiveItems(inBatch: batchID) else { return }

        undoBatchAccumulators[batchID] = nil
        // The marker is recorded first so the restorable entry of the same
        // batch stays on top of the history.
        recordNonRestorableOverwrite(accumulator.overwrittenDestinations)
        if !accumulator.copiedDestinations.isEmpty {
            recordUndoCopy(created: accumulator.copiedDestinations)
        }
        if !accumulator.movedItems.isEmpty {
            recordUndoMoves(accumulator.movedItems)
        }
    }

    private func recordUndoCopy(created: [URL]) {
        guard !created.isEmpty else { return }

        Task { [weak self] in
            let states = await FileUndoService.states(of: created)
            guard let self else { return }
            self.undoJournal.record(FileUndoEntry(kind: .copy(created: created, expected: states)))
        }
    }

    private func recordUndoMoves(_ items: [UndoMovePair]) {
        guard !items.isEmpty else { return }

        Task { [weak self] in
            let states = await FileUndoService.states(of: items.map(\.to))
            guard let self else { return }
            self.undoJournal.record(FileUndoEntry(kind: .move(items: items, expected: states)))
        }
    }

    private func recordUndoRename(from: URL, to: URL) {
        Task { [weak self] in
            let state = await FileUndoService.state(of: to)
            guard let self else { return }
            self.undoJournal.record(FileUndoEntry(kind: .rename(from: from, to: to, expected: state)))
        }
    }

    // MARK: - Recovery

    func scanForRecoveryResidues() {
        guard !didScanRecoveryResidues else { return }
        didScanRecoveryResidues = true

        let uniqueRoots = RecentTransferDestinations.shared.recoveryRoots(including: [
            FileManager.default.homeDirectoryForCurrentUser, currentURL
        ])

        Task { [weak self] in
            let residues = await Task.detached(priority: .utility) {
                RecoveryScanner.scan(in: uniqueRoots)
            }.value

            guard let self, !residues.isEmpty else { return }
            self.recoveryResidues = residues
            self.isRecoveryNoticePresented = true
        }
    }

    func dismissRecoveryNotice() {
        isRecoveryNoticePresented = false
        recoveryResidues = []
    }

    func cleanUpRecoveryResidues() {
        let residues = recoveryResidues
        guard !residues.isEmpty else { return }

        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    for residue in residues {
                        try RecoveryScanner.remove(residue)
                    }
                }.value
                guard let self else { return }
                self.recoveryResidues = []
                self.isRecoveryNoticePresented = false
            } catch {
                guard let self else { return }
                self.errorMessage = "清理传输残留失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Archives

    func showCompressPanel(format: ArchiveFormat) {
        guard canCompress(format: format) else {
            errorMessage = "请选择同一文件夹中的项目进行压缩。"
            return
        }

        let items = selectedItems
            .filter { !$0.isNetworkLocation }
            .map(\.url)
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "压缩为 \(format.title)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultArchiveName(for: items, format: format)
        switch format {
        case .zip:
            panel.allowedContentTypes = [.zip]
        case .tar:
            panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        case .tarGz, .gzip:
            panel.allowedContentTypes = [UTType(filenameExtension: "gz") ?? .data]
        }

        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.beginArchiveCompression(items: items, destination: destination, format: format)
            }
        }
    }

    func showExtractPanel() {
        guard selectedItems.count == 1,
              let archive = selectedItem,
              !archive.isNetworkLocation,
              ArchiveService.isArchive(archive.url) else {
            errorMessage = "请选择一个压缩包。"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "解压到"
        panel.prompt = "解压"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if currentURL.isFileURL {
            panel.directoryURL = currentURL
        }

        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.beginArchiveExtraction(archive: archive.url, destination: destination)
            }
        }
    }

    func cancelArchiveOperation() {
        archiveOperationGeneration += 1
        archiveOperationTask?.cancel()
        archiveOperationTask = nil
        if let pendingArchiveExtraction {
            let staging = pendingArchiveExtraction.staging
            Task.detached { ArchiveService.removeStaging(staging) }
        }
        pendingArchiveExtraction = nil
        pendingArchiveCompression = nil
        archiveConflictRequest = nil
        isArchiveOperationPresented = false
        archiveOperationError = nil
    }

    func dismissArchiveOperation() {
        isArchiveOperationPresented = false
        archiveOperationError = nil
    }

    func cancelArchiveConflictPrompt() {
        resolveArchiveConflict(.cancel)
    }

    func resolveArchiveConflict(_ resolution: ArchiveConflictResolution) {
        if let pending = pendingArchiveCompression {
            pendingArchiveCompression = nil
            archiveConflictRequest = nil
            if resolution == .overwrite {
                beginArchiveCompression(items: pending.items, destination: pending.destination,
                                        format: pending.format, overwrite: true)
            }
            return
        }
        guard let pending = pendingArchiveExtraction else { return }
        pendingArchiveExtraction = nil
        archiveConflictRequest = nil
        if resolution == .cancel {
            Task.detached { ArchiveService.removeStaging(pending.staging) }
            return
        }

        archiveOperationGeneration += 1
        let generation = archiveOperationGeneration
        isArchiveOperationPresented = true
        archiveOperationTitle = "正在完成解压…"
        archiveOperationError = nil
        archiveOperationTask?.cancel()
        archiveOperationTask = Task { [weak self] in
            do {
                try await ArchiveService.moveExtractedItems(
                    from: pending.staging, to: pending.destinationDirectory,
                    overwrite: resolution == .overwrite
                )
                await Task.detached { ArchiveService.removeStaging(pending.staging) }.value
                guard let self, generation == self.archiveOperationGeneration else { return }
                self.isArchiveOperationPresented = false
                await self.reload(selecting: nil)
            } catch is CancellationError {
                await Task.detached { ArchiveService.removeStaging(pending.staging) }.value
                guard let self, generation == self.archiveOperationGeneration else { return }
                self.isArchiveOperationPresented = false
            } catch {
                guard let self, generation == self.archiveOperationGeneration else { return }
                self.archiveOperationError = "\(error.localizedDescription)\n临时目录保留在：\(pending.staging.path)"
                self.isArchiveOperationPresented = true
            }
        }
    }

    private func requestCompressionOverwrite(items: [URL], destination: URL, format: ArchiveFormat) {
        pendingArchiveCompression = PendingArchiveCompression(items: items, destination: destination, format: format)
        isArchiveOperationPresented = false
        archiveConflictRequest = ArchiveConflictRequest(
            archiveName: destination.lastPathComponent, conflictCount: 1, isCompression: true
        )
    }

    private func beginArchiveCompression(
        items: [URL], destination: URL, format: ArchiveFormat, overwrite: Bool = false
    ) {
        cancelArchiveOperation()
        let generation = archiveOperationGeneration
        isArchiveOperationPresented = true
        archiveOperationTitle = "正在压缩…"
        archiveOperationTask = Task { [weak self] in
            do {
                if !overwrite {
                    let exists = await Task.detached { SafeFileOperations.entryExists(at: destination) }.value
                    guard !Task.isCancelled, let self, generation == self.archiveOperationGeneration else { return }
                    if exists {
                        self.requestCompressionOverwrite(items: items, destination: destination, format: format)
                        return
                    }
                }
                try await ArchiveService.compress(items: items, to: destination, format: format, overwrite: overwrite)
                guard !Task.isCancelled, let self, generation == self.archiveOperationGeneration else { return }
                self.isArchiveOperationPresented = false
                await self.reload(selecting: destination)
            } catch is CancellationError {
                guard let self, generation == self.archiveOperationGeneration else { return }
                self.isArchiveOperationPresented = false
            } catch {
                guard let self, generation == self.archiveOperationGeneration else { return }
                let cocoa = error as NSError
                if !overwrite && cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteFileExistsError {
                    self.requestCompressionOverwrite(items: items, destination: destination, format: format)
                } else {
                    self.archiveOperationError = error.localizedDescription
                    self.isArchiveOperationPresented = true
                }
            }
        }
    }

    private func beginArchiveExtraction(archive: URL, destination: URL) {
        cancelArchiveOperation()
        let generation = archiveOperationGeneration
        isArchiveOperationPresented = true
        archiveOperationTitle = "正在解压…"
        archiveOperationTask = Task { [weak self] in
            var staging: URL?
            do {
                let created = try await ArchiveService.extract(archive: archive, toStagingIn: destination)
                staging = created
                let (items, conflicts) = try await Task.detached(priority: .utility) {
                    let items = try ArchiveService.topLevelItems(in: created)
                    return (items, ArchiveService.conflicts(items: items, in: destination))
                }.value
                try Task.checkCancellation()
                guard let self, generation == self.archiveOperationGeneration else {
                    await Task.detached { ArchiveService.removeStaging(created) }.value
                    return
                }
                if conflicts.isEmpty {
                    try await ArchiveService.moveExtractedItems(from: created, to: destination, overwrite: false)
                    await Task.detached { ArchiveService.removeStaging(created) }.value
                    staging = nil
                    guard generation == self.archiveOperationGeneration else { return }
                    self.isArchiveOperationPresented = false
                    await self.reload(selecting: nil)
                } else {
                    self.pendingArchiveExtraction = PendingArchiveExtraction(
                        staging: created, destinationDirectory: destination, items: items,
                        conflicts: conflicts, archiveName: archive.lastPathComponent
                    )
                    self.isArchiveOperationPresented = false
                    self.archiveConflictRequest = ArchiveConflictRequest(
                        archiveName: archive.lastPathComponent, conflictCount: conflicts.count
                    )
                }
            } catch is CancellationError {
                if let staging { await Task.detached { ArchiveService.removeStaging(staging) }.value }
                guard let self, generation == self.archiveOperationGeneration else { return }
                self.isArchiveOperationPresented = false
            } catch {
                guard let self, generation == self.archiveOperationGeneration else {
                    if let staging { await Task.detached { ArchiveService.removeStaging(staging) }.value }
                    return
                }
                if let staging {
                    self.archiveOperationError = "\(error.localizedDescription)\n临时目录保留在：\(staging.path)"
                } else {
                    self.archiveOperationError = error.localizedDescription
                }
                self.isArchiveOperationPresented = true
            }
        }
    }

    private func defaultArchiveName(for items: [URL], format: ArchiveFormat) -> String {
        let baseName: String
        if items.count == 1, let item = items.first {
            let isDirectory = selectedItems.first(where: { $0.url == item })?.isDirectory == true
            // GZIP has no member table: preserve the original extension in its filename.
            baseName = (isDirectory || format == .gzip) ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
        } else {
            baseName = "Archive"
        }
        return "\(baseName).\(format.fileExtension)"
    }

    func pinSelectedFolderToFavorites() {
        guard let selectedItem, selectedItem.opensInApp else {
            return
        }

        pinFavorite(selectedItem.navigationURL ?? selectedItem.url)
    }

    func pinDroppedFavorites(_ urls: [URL]) -> Bool {
        var didPin = false

        for url in urls where isDirectory(url) {
            let beforeCount = pinnedFavoriteURLs.count
            pinFavorite(url)
            didPin = didPin || pinnedFavoriteURLs.count > beforeCount
        }

        return didPin
    }

    func pinFavorite(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard isDirectory(standardizedURL) else {
            errorMessage = "只能将文件夹添加到收藏夹。"
            return
        }

        if isBuiltInFavorite(standardizedURL) {
            favoritesStore.removeRemovedBuiltIn(standardizedURL)
            return
        }

        guard !pinnedFavoriteURLs.contains(standardizedURL) else {
            return
        }

        favoritesStore.addPinned(standardizedURL)
    }

    func removeFavorite(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if isBuiltInFavorite(standardizedURL) {
            guard !removedBuiltInFavoriteURLs.contains(standardizedURL) else {
                return
            }

            favoritesStore.addRemovedBuiltIn(standardizedURL)
        } else {
            favoritesStore.removePinned(standardizedURL)
        }
    }

    func unpinFavorite(_ url: URL) {
        removeFavorite(url)
    }

    func canPinFolder(_ item: FileItem) -> Bool {
        guard item.opensInApp, let navigationURL = item.navigationURL else {
            return false
        }

        let url = navigationURL.standardizedFileURL
        if isBuiltInFavorite(url) {
            return removedBuiltInFavoriteURLs.contains(url)
        }

        return !pinnedFavoriteURLs.contains(url)
    }

    func createFolder() async {
        do {
            let createdURL = try await fileSystem.createFolder(named: "新建文件夹", in: currentURL)
            await reload(selecting: createdURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSelected(to newName: String) async {
        guard let selectedItem else {
            return
        }

        let sourceURL = selectedItem.url
        do {
            let renamedURL = try await fileSystem.renameItem(at: sourceURL, to: newName)
            if renamedURL != sourceURL {
                recordUndoRename(from: sourceURL, to: renamedURL)
            }
            await reload(selecting: renamedURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveItems(_ urls: [URL], to destinationFolder: URL) {
        let dest = destinationFolder.standardizedFileURL
        let sources = urls.map(\.standardizedFileURL).filter { $0.deletingLastPathComponent() != dest }
        guard !sources.isEmpty else { return }
        beginConflictResolution(sources: sources, to: dest, operation: .move(shouldClearCut: false))
    }

    func moveSelectedToTrash() async {
        let itemsToTrash = selectedItems.filter { !$0.isNetworkLocation }
        guard !itemsToTrash.isEmpty else {
            return
        }

        await moveItemsToTrash(itemsToTrash)
    }

    func moveItemToTrash(_ item: FileItem) async {
        await moveItemsToTrash([item])
    }

    func moveItemsToTrash(_ items: [FileItem]) async {
        await deleteItems(items)
    }

    func deleteItems(_ items: [FileItem]) async {
        let trashableItems = items.filter { !$0.isNetworkLocation }
        guard !trashableItems.isEmpty else {
            return
        }

        do {
            for item in trashableItems {
                if requiresPermanentDeletion(item) {
                    try await fileSystem.deletePermanently(item.url)
                } else {
                    try await fileSystem.moveToTrash(item.url)
                }
            }

            clearCutItems(containing: trashableItems.map(\.url))
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requiresPermanentDeletion(_ item: FileItem) -> Bool {
        !item.isNetworkLocation && isOnRemoteMountedVolume(item.url)
    }

    func cutSelectedItem() {
        cutSelectedItems()
    }

    func cutSelectedItems() {
        fileClipboard.cutItemURLs = selectedItems
            .filter { !$0.isNetworkLocation }
            .map { $0.url.standardizedFileURL }
        fileClipboard.copiedItemURLs = []
    }

    func copySelectedItem() {
        copySelectedItems()
    }

    func copySelectedItems() {
        let copiedURLs = selectedItems
            .filter { !$0.isNetworkLocation }
            .map { $0.url.standardizedFileURL }

        guard !copiedURLs.isEmpty else {
            return
        }

        fileClipboard.copiedItemURLs = copiedURLs
        fileClipboard.cutItemURLs = []
        SystemActions.copyFileURLs(copiedURLs)
    }

    func pasteItems(maximumConcurrentCopies: Int) {
        if !cutItemURLs.isEmpty {
            pasteCutItems()
            return
        }
        pasteCopiedItems(maximumConcurrentCopies: maximumConcurrentCopies)
    }

    func pasteCutItems() {
        guard !cutItemURLs.isEmpty, currentURL.isFileURL else { return }
        let dest = currentURL.standardizedFileURL
        let sources = cutItemURLs.filter { $0.deletingLastPathComponent() != dest }
        guard !sources.isEmpty else { return }
        beginConflictResolution(sources: sources, to: dest, operation: .move(shouldClearCut: true))
    }

    func pasteCopiedItems(maximumConcurrentCopies: Int) {
        guard currentURL.isFileURL else { return }
        let copiedSources = copiedItemURLs.isEmpty ? SystemActions.fileURLsFromPasteboard() : copiedItemURLs
        guard !copiedSources.isEmpty else { return }
        let dest = currentURL.standardizedFileURL
        let sources = copiedSources.filter { $0.standardizedFileURL.deletingLastPathComponent() != dest }
        guard !sources.isEmpty else { return }
        beginConflictResolution(sources: sources, to: dest, operation: .copy(maximumConcurrentCopies: maximumConcurrentCopies))
    }

    func resolveCopyConflict(_ resolution: CopyConflictResolution) {
        guard var session = conflictSession else { return }
        copyConflictRequest = nil

        switch resolution {
        case .cancel:
            conflictSession = nil
            return
        case .overwrite:
            if let idx = session.remainingConflictIndices.first {
                session.approvedItems.append((session.allSources[idx], true))
                session.remainingConflictIndices.removeFirst()
            }
        case .overwriteAll:
            for idx in session.remainingConflictIndices {
                session.approvedItems.append((session.allSources[idx], true))
            }
            session.remainingConflictIndices = []
        case .skip:
            if !session.remainingConflictIndices.isEmpty {
                session.remainingConflictIndices.removeFirst()
            }
        case .skipAll:
            session.remainingConflictIndices = []
        }

        conflictSession = session
        showNextConflictOrExecute()
    }

    /// Copies items dropped from Finder or another tab into this folder. Reuses
    /// the same conflict flow as paste.
    func importItems(_ urls: [URL], maximumConcurrentCopies: Int) {
        guard currentURL.isFileURL else { return }
        let dest = currentURL.standardizedFileURL
        let sources = urls.map(\.standardizedFileURL).filter { $0.deletingLastPathComponent() != dest }
        guard !sources.isEmpty else { return }
        beginConflictResolution(sources: sources, to: dest, operation: .copy(maximumConcurrentCopies: maximumConcurrentCopies))
    }

    private func beginConflictResolution(sources: [URL], to destinationDirectory: URL, operation: ConflictSession.Operation) {
        cancelTransferPlan()
        conflictPreparationGeneration += 1
        conflictSession = nil
        copyConflictRequest = nil
        let generation = transferPlanGeneration
        transferPlanTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                TransferPlanService.shouldShowPlan(for: sources)
                    || sources.contains { SafeFileOperations.entryExists(at: destinationDirectory.appendingPathComponent($0.lastPathComponent)) }
            }
            let showPlan = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, generation == self.transferPlanGeneration else { return }
            if showPlan {
                self.prepareTransferPlan(sources: sources, to: destinationDirectory, operation: operation)
            } else {
                self.startConflictResolution(sources: sources, to: destinationDirectory, operation: operation)
            }
        }
    }

    private func startConflictResolution(sources: [URL], to destinationDirectory: URL, operation: ConflictSession.Operation) {
        conflictPreparationGeneration += 1
        let generation = conflictPreparationGeneration

        Task { [weak self] in
            let preflight = await Task.detached(priority: .utility) {
                Self.preflightConflicts(sources: sources, destinationDirectory: destinationDirectory)
            }.value

            guard let self, generation == self.conflictPreparationGeneration else {
                return
            }

            self.conflictSession = ConflictSession(
                allSources: sources,
                destinationDirectory: destinationDirectory,
                operation: operation,
                approvedItems: preflight.approvedSources.map { ($0, false) },
                remainingConflictIndices: preflight.conflictIndices,
                totalConflicts: preflight.conflictIndices.count
            )

            self.showNextConflictOrExecute()
        }
    }

    // MARK: - Transfer plan

    func confirmTransferPlan() {
        guard let pendingTransfer,
              let transferPlan,
              transferPlan.canProceed else {
            return
        }

        isTransferPlanPresented = false
        isPreparingTransferPlan = false
        self.transferPlan = nil
        transferPlanError = nil
        self.pendingTransfer = nil

        startConflictResolution(
            sources: pendingTransfer.sources,
            to: pendingTransfer.destinationDirectory,
            operation: pendingTransfer.operation
        )
    }

    func cancelTransferPlan() {
        transferPlanGeneration += 1
        transferPlanTask?.cancel()
        transferPlanTask = nil
        isTransferPlanPresented = false
        isPreparingTransferPlan = false
        transferPlan = nil
        transferPlanError = nil
        pendingTransfer = nil
    }

    private func prepareTransferPlan(
        sources: [URL],
        to destinationDirectory: URL,
        operation: ConflictSession.Operation
    ) {
        transferPlanGeneration += 1
        let generation = transferPlanGeneration
        transferPlanTask?.cancel()
        pendingTransfer = PendingTransfer(
            sources: sources,
            destinationDirectory: destinationDirectory,
            operation: operation
        )
        transferPlan = nil
        transferPlanError = nil
        transferPlanScannedCount = 0
        transferPlanScannedBytes = 0
        isPreparingTransferPlan = true
        isTransferPlanPresented = true

        let displayOperation: CopyQueueOperation = {
            switch operation {
            case .copy:
                return .copy
            case .move:
                return .move
            }
        }()

        transferPlanTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .utility) { [weak self] in
                    try await TransferPlanService.makePlan(
                        sources: sources, destinationDirectory: destinationDirectory,
                        operation: displayOperation,
                        progress: { [weak self] count, bytes in
                            Task { @MainActor [weak self] in
                                guard let self, generation == self.transferPlanGeneration,
                                      self.isPreparingTransferPlan else { return }
                                self.transferPlanScannedCount = count
                                self.transferPlanScannedBytes = bytes
                            }
                        }
                    )
                }
                let plan = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }

                guard let self, generation == self.transferPlanGeneration else { return }
                self.transferPlan = plan
                self.isPreparingTransferPlan = false
            } catch is CancellationError {
                guard let self, generation == self.transferPlanGeneration else { return }
                self.isPreparingTransferPlan = false
            } catch {
                guard let self, generation == self.transferPlanGeneration else { return }
                self.transferPlanError = error.localizedDescription
                self.isPreparingTransferPlan = false
            }
        }
    }

    nonisolated private static func preflightConflicts(
        sources: [URL],
        destinationDirectory: URL
    ) -> ConflictPreflightResult {
        var approvedSources: [URL] = []
        var conflictIndices: [Int] = []
        approvedSources.reserveCapacity(sources.count)

        for (index, source) in sources.enumerated() {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            if SafeFileOperations.entryExists(at: destination) {
                conflictIndices.append(index)
            } else {
                approvedSources.append(source)
            }
        }

        return ConflictPreflightResult(
            approvedSources: approvedSources,
            conflictIndices: conflictIndices
        )
    }

    private func showNextConflictOrExecute() {
        guard let session = conflictSession else { return }

        guard let firstRemainingIdx = session.remainingConflictIndices.first else {
            copyConflictRequest = nil
            executeConflictSession()
            return
        }

        let conflictNumber = session.totalConflicts - session.remainingConflictIndices.count + 1
        copyConflictRequest = CopyConflictRequest(
            conflictingName: session.allSources[firstRemainingIdx].lastPathComponent,
            conflictNumber: conflictNumber,
            totalConflicts: session.totalConflicts
        )
    }

    private func executeConflictSession() {
        guard let session = conflictSession else { return }
        conflictSession = nil
        guard !session.approvedItems.isEmpty else { return }

        switch session.operation {
        case .copy(let maximumConcurrentCopies):
            copyQueue.maximumConcurrentCopies = maximumConcurrentCopies
            copyQueue.enqueue(session.approvedItems, to: session.destinationDirectory)

        case .move:
            copyQueue.enqueueMoves(session.approvedItems, to: session.destinationDirectory)
        }
    }

    /// Reorders a pinned favorite so it lands ahead of `targetURL`. Built-in
    /// favorites keep their fixed order; only user-pinned favorites reorder.
    func moveFavorite(_ url: URL, before targetURL: URL) {
        let source = url.standardizedFileURL
        let target = targetURL.standardizedFileURL
        guard source != target,
              pinnedFavoriteURLs.contains(source),
              pinnedFavoriteURLs.contains(target) else {
            return
        }

        favoritesStore.movePinned(source, before: target)
    }

    func isPinnedFavorite(_ url: URL) -> Bool {
        pinnedFavoriteURLs.contains(url.standardizedFileURL)
    }

    func showCopyQueue() {
        detailDestination = .copyQueue
    }

    func showCurrentFolder() {
        detailDestination = .files
    }

    func showAbout() {
        presentAuxiliaryDetail(.about)
    }

    func showSettings() {
        presentAuxiliaryDetail(.settings)
    }

    /// Returns from a transient About/Settings surface to whatever the user was
    /// viewing before (their folder/tab or the copy queue).
    func dismissAuxiliaryDetail() {
        detailDestination = destinationBeforeAuxiliaryDetail
    }

    private func presentAuxiliaryDetail(_ destination: DetailDestination) {
        if detailDestination != .about, detailDestination != .settings {
            destinationBeforeAuxiliaryDetail = detailDestination
        }

        detailDestination = destination
    }

    func isCut(_ item: FileItem) -> Bool {
        cutItemURLs.contains(item.url.standardizedFileURL)
    }

    var canSelectAll: Bool { !displayedItems.isEmpty }

    func selectAll() {
        let ids = displayedItems.map(\.id)
        selectedItemIDs = Set(ids)
        selectionAnchorID = ids.first
    }

    func select(_ item: FileItem, mode: SelectionMode) {
        switch mode {
        case .single:
            selectedItemIDs = [item.id]
            selectionAnchorID = item.id
        case .toggle:
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            selectionAnchorID = item.id
        case .range:
            selectRange(through: item)
        }
    }

    func revealSelectedInFinder() {
        SystemActions.revealInFinder(selectedItem?.url ?? currentURL)
    }

    func openCurrentFolderInTerminal() {
        SystemActions.openInTerminal(currentURL)
    }

    func openSelectedInTerminal() {
        SystemActions.openInTerminal(selectedItem?.url ?? currentURL)
    }

    func copySelectedPath() {
        SystemActions.copyPath(selectedItem?.url ?? currentURL)
    }

    func clearError() {
        errorMessage = nil
    }

    func clearRenameRequest() {
        renameRequest = nil
    }

    func clearTrashRequest() {
        trashRequest = []
    }

    private func connectToServer(_ url: URL) {
        isConnectToServerPresented = false

        if url.isFileURL {
            navigate(to: url)
        } else {
            SystemActions.connectToServer(url)
        }
    }

    private func networkItems() async -> [FileItem] {
        let mountedRemoteVolumes = mountedRemoteVolumeItems()
        let discoveredLocations = await networkBrowser.browse()
        let mountedURLs = Set(mountedRemoteVolumes.map(\.url))
        let discoveredItems = discoveredLocations
            .filter { !mountedURLs.contains($0.url) }
            .map { location in
                FileItem(
                    url: location.url,
                    name: location.name,
                    typeDescription: location.kind,
                    isDirectory: false,
                    isPackage: false,
                    isAlias: false,
                    aliasTargetURL: nil,
                    isAliasTargetDirectory: false,
                    isAliasTargetPackage: false,
                    isHidden: false,
                    size: nil,
                    modifiedAt: nil,
                    isNetworkLocation: true
                )
            }

        return (mountedRemoteVolumes + discoveredItems).sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func mountedRemoteVolumeItems() -> [FileItem] {
        volumeCatalog.mountedVolumes.filter { !$0.isLocal }.map { volume in
            FileItem(
                url: volume.url,
                name: volume.name,
                typeDescription: "已挂载的网络卷",
                isDirectory: true,
                isPackage: false,
                isAlias: false,
                aliasTargetURL: nil,
                isAliasTargetDirectory: false,
                isAliasTargetPackage: false,
                isHidden: false,
                size: nil,
                modifiedAt: volume.modifiedAt
            )
        }
    }

    private func isOnRemoteMountedVolume(_ url: URL) -> Bool {
        if let isLocal = volumeCatalog.isLocalVolume(containing: url) {
            return !isLocal
        }

        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey])
        if let isLocal = values?.volumeIsLocal {
            return !isLocal
        }

        guard let volume = values?.volume else {
            return false
        }

        let volumeValues = try? volume.resourceValues(forKeys: [.volumeIsLocalKey])
        return volumeValues?.volumeIsLocal == false
    }

    private func applyLoadedItems(_ loadedItems: [FileItem], selecting itemID: FileItem.ID?) {
        let loadedIDs = Set(loadedItems.map(\.id))
        items = loadedItems
        if let itemID, loadedIDs.contains(itemID) {
            selectedItemIDs = [itemID]
            selectionAnchorID = itemID
        } else {
            selectedItemIDs = selectedItemIDs.filter { loadedIDs.contains($0) }
            if let selectionAnchorID, !selectedItemIDs.contains(selectionAnchorID) {
                self.selectionAnchorID = selectedItemIDs.first
            }
        }
    }

    /// Completed transfers arrive one file at a time. Collect them briefly so a
    /// batch of small files updates the table once instead of re-enumerating and
    /// re-sorting the whole folder for every file.
    private func enqueueCompletedItem(_ destinationURL: URL) {
        let standardizedURL = destinationURL.standardizedFileURL
        guard pendingCompletedURLSet.insert(standardizedURL).inserted else {
            return
        }

        pendingCompletedURLs.append(standardizedURL)
        scheduleCompletionFlush()
    }

    private func scheduleCompletionFlush() {
        guard completionFlushTask == nil else {
            return
        }

        completionFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Self.completionFlushDelayMilliseconds))
            } catch {
                self?.completionFlushTask = nil
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.completionFlushTask = nil
            await self.flushCompletedItems()
        }
    }

    private func flushCompletedItems() async {
        guard !pendingCompletedURLs.isEmpty else {
            return
        }

        let completedURLs = pendingCompletedURLs
        pendingCompletedURLs.removeAll()
        pendingCompletedURLSet.removeAll()

        let target = currentURL
        let targetDirectory = target.standardizedFileURL
        guard target.isFileURL,
              completedURLs.allSatisfy({
                  $0.deletingLastPathComponent().standardizedFileURL == targetDirectory
              }) else {
            return
        }

        let generation = loadGeneration
        let options = isOnRemoteMountedVolume(target) ? DirectoryListingOptions() : listingOptions

        guard completedURLs.count <= Self.maximumIncrementalRefreshCount else {
            await reload(selecting: completedURLs.last)
            return
        }

        do {
            let fetched = try await fileItems(for: completedURLs, options: options)
            guard currentURL.standardizedFileURL == targetDirectory else {
                return
            }
            guard generation == loadGeneration else {
                // A full reload is already in flight. Let it finish, then apply
                // these completions against the newer listing.
                for url in completedURLs where pendingCompletedURLSet.insert(url).inserted {
                    pendingCompletedURLs.append(url)
                }
                scheduleCompletionFlush()
                return
            }
            guard !fetched.isEmpty else {
                return
            }

            let fetchedIDs = Set(fetched.map(\.id))
            var merged = items
            merged.removeAll { fetchedIDs.contains($0.id) }
            merged.append(contentsOf: fetched)
            items = merged

            if let lastURL = completedURLs.last,
               let lastItem = fetched.first(where: { $0.url.standardizedFileURL == lastURL }) {
                selectedItemIDs = [lastItem.id]
                selectionAnchorID = lastItem.id
            }
        } catch {
            guard currentURL.standardizedFileURL == targetDirectory else {
                return
            }
            await reload(selecting: nil)
        }
    }

    private func fileItems(for urls: [URL], options: DirectoryListingOptions) async throws -> [FileItem] {
        let fileSystem = self.fileSystem
        return try await withThrowingTaskGroup(of: FileItem.self) { group in
            let maximumConcurrency = 6
            var nextIndex = 0
            let primeCount = min(maximumConcurrency, urls.count)
            while nextIndex < primeCount {
                let url = urls[nextIndex]
                group.addTask { try await fileSystem.fileItem(at: url, options: options) }
                nextIndex += 1
            }

            var fetched: [FileItem] = []
            fetched.reserveCapacity(urls.count)
            while let item = try await group.next() {
                fetched.append(item)
                if nextIndex < urls.count {
                    let url = urls[nextIndex]
                    group.addTask { try await fileSystem.fileItem(at: url, options: options) }
                    nextIndex += 1
                }
            }
            return fetched
        }
    }

    private func homeSubfolder(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
    }

    private func sidebarName(for url: URL) -> String {
        if url.lastPathComponent.isEmpty {
            return url.path
        }

        return url.lastPathComponent
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func manualFolderURL(from input: String) -> URL? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        let expandedPath = NSString(string: trimmedInput).expandingTildeInPath
        if NSString(string: expandedPath).isAbsolutePath {
            return URL(fileURLWithPath: expandedPath)
        }

        let baseURL = currentURL.isFileURL ? currentURL : FileManager.default.homeDirectoryForCurrentUser
        return baseURL.appendingPathComponent(expandedPath)
    }

    private func isBuiltInFavorite(_ url: URL) -> Bool {
        let builtInURLs = builtInFavoriteLocations().map { $0.url.standardizedFileURL }

        return builtInURLs.contains(url.standardizedFileURL)
    }

    private func clearCutItems(containing urls: [URL]) {
        let standardizedURLs = Set(urls.map(\.standardizedFileURL))
        fileClipboard.cutItemURLs.removeAll { standardizedURLs.contains($0.standardizedFileURL) }
    }

    private func selectRange(through item: FileItem) {
        let anchor = selectionAnchorID ?? displayedItems.first(where: { selectedItemIDs.contains($0.id) })?.id
        let range = anchor.map {
            FileBrowserPresentation.selectionRange(from: $0, to: item.id, in: displaySections)
        } ?? []
        guard !range.isEmpty else {
            selectedItemIDs = [item.id]
            selectionAnchorID = item.id
            return
        }
        selectedItemIDs = Set(range.map(\.id))
    }

    private static func serverURL(from input: String) -> URL? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        if trimmedInput.hasPrefix("/") || trimmedInput.hasPrefix("~") {
            return nil
        }

        let address: String
        if trimmedInput.contains("://") {
            address = trimmedInput
        } else {
            address = "smb://\(trimmedInput)"
        }

        guard
            let url = URL(string: address),
            let scheme = url.scheme?.lowercased(),
            ["smb", "afp", "nfs", "ftp", "file"].contains(scheme)
        else {
            return nil
        }

        return url
    }
}
