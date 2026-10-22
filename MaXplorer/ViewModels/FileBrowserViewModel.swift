import Foundation
import Combine
import Darwin

enum SelectionMode {
    case single
    case toggle
    case range
}

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
            resortItems()
        }
    }
    /// `items` sorted and filtered for display. Kept as stored state and only
    /// rebuilt when the items, sort, or filter change, because the table,
    /// status bar, and selection logic all read it on every render.
    @Published private(set) var displayedItems: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var isConnectToServerPresented = false
    @Published var isGoToFolderPresented = false
    @Published var detailDestination: DetailDestination = .files
    @Published var copyConflictRequest: CopyConflictRequest?
    @Published var pathText: String
    @Published var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            refilterItems()
        }
    }
    let filterFocusProxy = FilterFocusProxy()
    @Published var selectedItemIDs: Set<FileItem.ID> = []
    @Published var sortOrder = FileSortDescriptor.fallback.comparators {
        didSet {
            guard sortOrder != oldValue else { return }
            resortItems()
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
            refilterItems()
        }
    }
    @Published var isIntegratedTerminalPresented = false
    @Published var isReadmePresented = false

    let fileSystem: any FileSystemService
    let copyQueue: CopyQueueViewModel
    private let fileClipboard: FileClipboard
    private let favoritesStore: FavoritesStore
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
    private var sortedItems: [FileItem] = []
    private var isRestoringSort = false

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

    init(
        fileSystem: FileSystemService,
        fileClipboard: FileClipboard,
        favoritesStore: FavoritesStore,
        copyQueue: CopyQueueViewModel
    ) {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        self.fileSystem = fileSystem
        self.fileClipboard = fileClipboard
        self.favoritesStore = favoritesStore
        self.copyQueue = copyQueue
        self.currentURL = homeURL
        self.pathText = homeURL.path
        self.sortOrder = FolderSortStore.shared.sort(for: homeURL).comparators
        self.copyQueue.observeItemCompletions { [weak self] destinationURL in
            guard let self, destinationURL.deletingLastPathComponent().standardizedFileURL == self.currentURL.standardizedFileURL else {
                return
            }

            Task { await self.refreshAfterCompletedItem(destinationURL) }
        }
        self.copyQueue.observeMoveCompletions { [weak self] sourceURL in
            self?.clearCutItems(containing: [sourceURL])
        }
        self.clipboardObservation = fileClipboard.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.favoritesObservation = favoritesStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

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

    private func resortItems() {
        sortedItems = FileSorter.sorted(items, by: FileSortDescriptor(sortOrder) ?? FolderSortStore.shared.defaultSort)
        refilterItems()
    }

    private func refilterItems() {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || !showAliases else {
            displayedItems = sortedItems
            return
        }

        displayedItems = sortedItems.filter { item in
            if !showAliases && item.isAlias {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            return item.name.localizedCaseInsensitiveContains(query)
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

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.isFileURL && currentURL.path != "/" }
    var canCreateFolder: Bool { currentURL.isFileURL }
    var canCutSelectedItem: Bool { selectedItems.contains { !$0.isNetworkLocation } }
    var canCopySelectedItem: Bool { selectedItems.contains { !$0.isNetworkLocation } }
    var canPasteItems: Bool { currentURL.isFileURL && (!cutItemURLs.isEmpty || !copiedItemURLs.isEmpty || !SystemActions.fileURLsFromPasteboard().isEmpty) }
    var canPasteCutItems: Bool { currentURL.isFileURL && !cutItemURLs.isEmpty }
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
            return "Network"
        }

        return currentURL.isFileURL ? currentURL.path : currentURL.absoluteString
    }

    /// Used/free/total bytes for the volume backing the current folder.
    /// Nil while browsing the network root or when the volume can't be queried.
    var volumeStats: VolumeCapacityStats? {
        VolumeCapacityReader.stats(for: currentURL)
    }
    var tabTitle: String {
        if currentURL == Self.networkRootURL {
            return "Network"
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
                name: "Browse Network",
                url: Self.networkRootURL,
                group: .network,
                systemImage: "network"
            )
        )

        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes where volume.path != "/" {
            let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeNameKey])
            let isLocal = values?.volumeIsLocal ?? true
            locations.append(
                SidebarLocation(
                    name: values?.volumeName ?? volume.lastPathComponent,
                    url: volume,
                    group: isLocal ? .devices : .network,
                    systemImage: isLocal ? "externaldrive.fill" : "server.rack"
                )
            )
        }

        return locations
    }

    private func builtInFavoriteLocations() -> [SidebarLocation] {
        [
            SidebarLocation(name: "Home", url: FileManager.default.homeDirectoryForCurrentUser, group: .favorites, systemImage: "house.fill", canRemoveFromFavorites: true),
            SidebarLocation(name: "Desktop", url: homeSubfolder("Desktop"), group: .favorites, systemImage: "desktopcomputer", canRemoveFromFavorites: true),
            SidebarLocation(name: "Documents", url: homeSubfolder("Documents"), group: .favorites, systemImage: "folder.fill", canRemoveFromFavorites: true),
            SidebarLocation(name: "Downloads", url: homeSubfolder("Downloads"), group: .favorites, systemImage: "arrow.down.circle.fill", canRemoveFromFavorites: true)
        ]
    }

    func reload() {
        Task { await self.reload(selecting: nil) }
    }

    func focusFilterField() {
        filterFocusProxy.focus()
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
        let target = currentURL
        let showHiddenFiles = showHiddenFiles
        let fileSystem = fileSystem
        let listingOptions = listingOptions
        let isRemoteVolume = target != Self.networkRootURL && isOnRemoteMountedVolume(target)
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
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
                        options: initialOptions
                    )
                }

                guard generation == loadGeneration else {
                    return
                }

                applyLoadedItems(loadedItems, selecting: itemID)
                isLoading = false
            } catch {
                guard generation == loadGeneration else {
                    return
                }

                items = []
                selectedItemIDs = []
                selectionAnchorID = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
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
        pathText = url == Self.networkRootURL ? "Network" : url.path
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
            self.monitorReloadTask?.cancel()
            self.monitorReloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
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
        if expandedPath.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Network") == .orderedSame {
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
            errorMessage = "The path does not exist or is not a folder."
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
            errorMessage = "Path not found"
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
            errorMessage = "Enter a valid server address, such as smb://server/share."
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
            SystemActions.open(selectedItem.url)
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
            errorMessage = "Only folders can be added to Favorites."
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
            let createdURL = try await fileSystem.createFolder(named: "New Folder", in: currentURL)
            await reload(selecting: createdURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSelected(to newName: String) async {
        guard let selectedItem else {
            return
        }

        do {
            let renamedURL = try await fileSystem.renameItem(at: selectedItem.url, to: newName)
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
        remoteMountedVolumes().map { volume in
            let values = try? volume.resourceValues(forKeys: [.contentModificationDateKey, .volumeNameKey])
            return FileItem(
                url: volume,
                name: values?.volumeName ?? volume.lastPathComponent,
                typeDescription: "Mounted Network Volume",
                isDirectory: true,
                isPackage: false,
                isAlias: false,
                aliasTargetURL: nil,
                isAliasTargetDirectory: false,
                isAliasTargetPackage: false,
                isHidden: false,
                size: nil,
                modifiedAt: values?.contentModificationDate
            )
        }
    }

    private func remoteMountedVolumes() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.filter { volume in
            guard volume.path != "/" else {
                return false
            }

            let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey])
            return values?.volumeIsLocal == false
        }
    }

    private func isOnRemoteMountedVolume(_ url: URL) -> Bool {
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
        items = loadedItems
        if let itemID, loadedItems.contains(where: { $0.id == itemID }) {
            selectedItemIDs = [itemID]
            selectionAnchorID = itemID
        } else {
            selectedItemIDs = selectedItemIDs.filter { selectedID in
                loadedItems.contains { $0.id == selectedID }
            }
            if let selectionAnchorID, !selectedItemIDs.contains(selectionAnchorID) {
                self.selectionAnchorID = selectedItemIDs.first
            }
        }
    }

    private func refreshAfterCompletedItem(_ destinationURL: URL) async {
        let destinationDirectory = destinationURL.deletingLastPathComponent().standardizedFileURL
        guard destinationDirectory == currentURL.standardizedFileURL else {
            return
        }

        guard isOnRemoteMountedVolume(destinationDirectory) else {
            await reload(selecting: destinationURL)
            return
        }

        do {
            // Keep completion feedback responsive on SMB. Optional Owner and
            // Date Taken lookups can each require additional remote round trips.
            let item = try await fileSystem.fileItem(at: destinationURL, options: DirectoryListingOptions())
            guard destinationDirectory == currentURL.standardizedFileURL else {
                return
            }

            items.removeAll { $0.id == item.id }
            items.append(item)
            selectedItemIDs = [item.id]
            selectionAnchorID = item.id
        } catch {
            errorMessage = error.localizedDescription
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
        guard
            let anchorID = selectionAnchorID ?? selectedItemIDs.first,
            let anchorIndex = displayedItems.firstIndex(where: { $0.id == anchorID }),
            let targetIndex = displayedItems.firstIndex(where: { $0.id == item.id })
        else {
            selectedItemIDs = [item.id]
            selectionAnchorID = item.id
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedItemIDs = Set(bounds.map { displayedItems[$0].id })
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
