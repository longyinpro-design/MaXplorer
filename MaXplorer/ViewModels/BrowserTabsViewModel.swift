import Foundation
import Combine

@MainActor
final class BrowserTabsViewModel: ObservableObject {
    struct BrowserTab: Identifiable {
        let id: UUID
        let model: FileBrowserViewModel
    }

    @Published private(set) var tabs: [BrowserTab]
    @Published var selectedTabID: BrowserTab.ID {
        didSet {
            observeActiveModel()
        }
    }
    @Published private(set) var maximumConcurrentTabs: Int
    @Published var showHiddenFiles = false {
        didSet { for tab in tabs { tab.model.showHiddenFiles = showHiddenFiles } }
    }
    @Published var showAliases = true {
        didSet { for tab in tabs { tab.model.showAliases = showAliases } }
    }

    // Forwards the active tab's model changes so that anything observing this
    // object (notably the App scene's `.commands`, which cannot observe the
    // per-tab model directly) re-evaluates when selection or contents change.
    // Without this, menu items whose `.disabled` state depends on the model
    // stay stuck at their launch-time value and their keyboard shortcuts never
    // fire once enabled.
    private var activeModelObservation: AnyCancellable?
    private var listingOptions = DirectoryListingOptions(columns: FileColumn.defaultVisible)
    private let fileClipboard: FileClipboard
    private let favoritesStore: FavoritesStore
    private let copyQueue: CopyQueueViewModel
    let undoJournal: FileUndoJournal

    init(maximumConcurrentTabs: Int = 20) {
        let fileClipboard = FileClipboard()
        let favoritesStore = FavoritesStore()
        let copyQueue = CopyQueueViewModel()
        let undoJournal = FileUndoJournal()
        let initialTab = Self.makeTab(
            fileClipboard: fileClipboard,
            favoritesStore: favoritesStore,
            copyQueue: copyQueue,
            undoJournal: undoJournal
        )
        self.fileClipboard = fileClipboard
        self.favoritesStore = favoritesStore
        self.copyQueue = copyQueue
        self.undoJournal = undoJournal
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id
        self.maximumConcurrentTabs = Self.clampedTabLimit(maximumConcurrentTabs)
        observeActiveModel()
        initialTab.model.scanForRecoveryResidues()
    }

    private func observeActiveModel() {
        activeModelObservation = activeModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    var activeTab: BrowserTab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    var activeModel: FileBrowserViewModel {
        activeTab.model
    }

    var canAddTab: Bool {
        tabs.count < maximumConcurrentTabs
    }

    var canCycleTabs: Bool {
        tabs.count > 1
    }

    func addTab() {
        guard canAddTab else {
            return
        }

        let tab = makeTab()
        tab.model.setListingOptions(listingOptions)
        tab.model.showHiddenFiles = showHiddenFiles
        tab.model.showAliases = showAliases
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func browseLocation(_ url: URL) {
        guard selectBrowserTabForSidebarAction() else {
            return
        }

        activeModel.navigate(to: url)
    }

    func openLocationInNewTab(_ url: URL) {
        guard canAddTab else {
            activeModel.navigate(to: url)
            return
        }

        let tab = makeTab()
        tab.model.setListingOptions(listingOptions)
        tab.model.showHiddenFiles = showHiddenFiles
        tab.model.showAliases = showAliases
        tab.model.navigate(to: url)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openOrSelectLocation(_ url: URL) {
        let location = url.standardizedFileURL
        if let existingTab = tabs.first(where: {
            !isSpecialTab($0.id) &&
            $0.model.currentURL.standardizedFileURL == location
        }) {
            selectedTabID = existingTab.id
            existingTab.model.showCurrentFolder()
            return
        }

        if canAddTab {
            openLocationInNewTab(location)
        } else if let browserTab = tabs.first(where: {
            !isSpecialTab($0.id)
        }) {
            selectedTabID = browserTab.id
            browserTab.model.navigate(to: location)
        }
    }

    func showCopyQueue() {
        if let existingID = copyQueueTabID {
            selectedTabID = existingID
            return
        }

        guard canAddTab else { return }

        let tab = makeTab()
        let insertionIndex = spaceAnalyzerTabID == nil ? 0 : 1
        tabs.insert(tab, at: insertionIndex)
        copyQueueTabID = tab.id
        selectedTabID = tab.id
    }

    func showSettings() {
        guard selectExistingBrowserTabForSidebarSurface() else {
            return
        }

        activeModel.showSettings()
    }

    func showAbout() {
        guard selectExistingBrowserTabForSidebarSurface() else {
            return
        }

        activeModel.showAbout()
    }

    /// Propagates the file-listing options (which slow columns to fetch) to
    /// every tab so switching tabs stays consistent.
    func applyListingOptions(_ options: DirectoryListingOptions) {
        listingOptions = options
        for tab in tabs {
            tab.model.setListingOptions(options)
        }
    }

    /// Re-applies each tab's remembered sort, e.g. after the default sort
    /// changed in Settings.
    func reapplyRememberedSorts() {
        for tab in tabs {
            tab.model.reapplyRememberedSort()
        }
    }

    func updateMaximumConcurrentTabs(_ maximumConcurrentTabs: Int) {
        self.maximumConcurrentTabs = Self.clampedTabLimit(maximumConcurrentTabs)
    }

    func selectTab(_ tabID: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        selectedTabID = tabID
        if !isSpecialTab(tabID) {
            activeModel.showCurrentFolder()
        }
    }

    func canPasteItems(to tabID: BrowserTab.ID) -> Bool {
        guard !isSpecialTab(tabID),
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return false
        }

        return tab.model.canPasteItems
    }

    func pasteItems(to tabID: BrowserTab.ID, maximumConcurrentCopies: Int) {
        guard canPasteItems(to: tabID) else {
            return
        }

        selectTab(tabID)
        activeModel.pasteItems(maximumConcurrentCopies: maximumConcurrentCopies)
    }

    func closeTab(_ tabID: BrowserTab.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        if tabID == searchTabID {
            tabs[index].model.endSearch()
            searchTabID = nil
        }

        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)

        if wasSelected {
            let neighbor = tabs[min(index, tabs.count - 1)]
            selectedTabID = neighbor.id
        }
    }

    /// Moves the dragged tab so that it lands ahead of `targetID` (used by the
    /// tab strip's drag-to-reorder).
    func moveTab(_ tabID: BrowserTab.ID, before targetID: BrowserTab.ID) {
        guard tabID != targetID,
              !isSpecialTab(tabID),
              !isSpecialTab(targetID),
              let fromIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let moved = tabs.remove(at: fromIndex)
        let insertionIndex = tabs.firstIndex(where: { $0.id == targetID }) ?? targetIndex
        tabs.insert(moved, at: insertionIndex)
    }

    func duplicateTab(_ tabID: BrowserTab.ID) {
        guard canAddTab,
              !isSpecialTab(tabID),
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let source = tabs[index]
        let tab = makeTab()
        tab.model.setListingOptions(listingOptions)
        tab.model.showHiddenFiles = showHiddenFiles
        tab.model.showAliases = showAliases
        tab.model.navigate(to: source.model.currentURL)
        tabs.insert(tab, at: index + 1)
        selectedTabID = tab.id
    }

    func sortTabsByName() {
        let specialIDs = [spaceAnalyzerTabID, copyQueueTabID, searchTabID].compactMap { $0 }
        let specialTabs = specialIDs.compactMap { id in tabs.first { $0.id == id } }
        let browserTabs = tabs.filter { !specialIDs.contains($0.id) }.sorted { lhs, rhs in
            lhs.model.tabTitle.localizedStandardCompare(rhs.model.tabTitle) == .orderedAscending
        }
        tabs = specialTabs + browserTabs
    }

    /// Keeps the first tab pointing at each location and closes the rest.
    func closeDuplicateTabs() {
        var seenLocations = Set<String>()
        var survivors: [BrowserTab] = []

        for tab in tabs {
            if isSpecialTab(tab.id) {
                survivors.append(tab)
                continue
            }

            let key = tab.model.currentURL.standardizedFileURL.absoluteString
            if seenLocations.insert(key).inserted {
                survivors.append(tab)
            }
        }

        guard survivors.count != tabs.count else {
            return
        }

        tabs = survivors
        if !survivors.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = survivors[0].id
        }
    }

    // MARK: – Space Analyzer

    @Published private(set) var spaceAnalyzerTabID: UUID?
    let spaceAnalyzerViewModel = SpaceAnalyzerViewModel()

    var isSpaceAnalyzerActive: Bool { selectedTabID == spaceAnalyzerTabID }

    func openSpaceAnalyzer(url: URL? = nil) {
        if let existingID = spaceAnalyzerTabID {
            selectedTabID = existingID
            if let url { spaceAnalyzerViewModel.startScan(url: url) }
            return
        }
        let tab = makeTab()
        tabs.insert(tab, at: 0)
        spaceAnalyzerTabID = tab.id
        selectedTabID = tab.id
        if let url { spaceAnalyzerViewModel.startScan(url: url) }
    }

    func closeSpaceAnalyzer() {
        guard let id = spaceAnalyzerTabID else { return }
        spaceAnalyzerTabID = nil
        spaceAnalyzerViewModel.cancelScan()
        closeTab(id)
    }

    // MARK: – Copy Queue

    @Published private(set) var copyQueueTabID: UUID?

    var isCopyQueueActive: Bool { selectedTabID == copyQueueTabID }

    func closeCopyQueue() {
        guard let id = copyQueueTabID else { return }
        copyQueueTabID = nil
        closeTab(id)
    }

    // MARK: – Search

    @Published private(set) var searchTabID: UUID?

    var isSearchActive: Bool { selectedTabID == searchTabID }

    var searchModel: FileBrowserViewModel? {
        guard let searchTabID else { return nil }
        return tabs.first(where: { $0.id == searchTabID })?.model
    }

    func openSearch(scopeRoot: URL, query: String = "") {
        guard scopeRoot.isFileURL else { return }

        if let existingID = searchTabID,
           let existingTab = tabs.first(where: { $0.id == existingID }) {
            selectedTabID = existingID
            existingTab.model.beginSearch(scopeRoot: scopeRoot, query: query)
            return
        }

        guard canAddTab else { return }

        let tab = makeTab()
        tab.model.setListingOptions(listingOptions)
        tab.model.showHiddenFiles = showHiddenFiles
        tab.model.showAliases = showAliases
        tabs.insert(tab, at: 0)
        searchTabID = tab.id
        selectedTabID = tab.id
        tab.model.beginSearch(scopeRoot: scopeRoot, query: query)
    }

    func closeSearch() {
        guard let searchTabID else { return }
        closeTab(searchTabID)
    }

    func selectNextTab() {
        selectTab(offset: 1)
    }

    func selectPreviousTab() {
        selectTab(offset: -1)
    }

    private func selectTab(offset: Int) {
        guard
            tabs.count > 1,
            let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
        else {
            return
        }

        let nextIndex = (selectedIndex + offset + tabs.count) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    private func makeTab() -> BrowserTab {
        Self.makeTab(
            fileClipboard: fileClipboard,
            favoritesStore: favoritesStore,
            copyQueue: copyQueue,
            undoJournal: undoJournal
        )
    }

    static func makeTab(
        fileClipboard: FileClipboard,
        favoritesStore: FavoritesStore,
        copyQueue: CopyQueueViewModel,
        undoJournal: FileUndoJournal
    ) -> BrowserTab {
        BrowserTab(
            id: UUID(),
            model: FileBrowserViewModel(
                fileSystem: LocalFileSystemService(),
                fileClipboard: fileClipboard,
                favoritesStore: favoritesStore,
                copyQueue: copyQueue,
                undoJournal: undoJournal
            )
        )
    }

    private func selectBrowserTabForSidebarAction() -> Bool {
        guard isSpaceAnalyzerActive || isCopyQueueActive || isSearchActive else {
            return true
        }

        guard canAddTab else {
            return false
        }

        addTab()
        return true
    }

    private func selectExistingBrowserTabForSidebarSurface() -> Bool {
        guard isSpaceAnalyzerActive || isCopyQueueActive || isSearchActive else {
            return true
        }

        guard let browserTab = tabs.first(where: {
            !isSpecialTab($0.id)
        }) else {
            return false
        }

        selectedTabID = browserTab.id
        return true
    }

    private func isSpecialTab(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return id == spaceAnalyzerTabID || id == copyQueueTabID || id == searchTabID
    }

    private static func clampedTabLimit(_ value: Int) -> Int {
        min(max(value, AppSettings.maximumConcurrentTabsRange.lowerBound), AppSettings.maximumConcurrentTabsRange.upperBound)
    }
}
