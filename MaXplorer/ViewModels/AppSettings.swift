import AppKit
import Combine
import CoreFoundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private static let appearanceKey = "AppAppearance"
    private static let maximumConcurrentTabsKey = "MaximumConcurrentTabs"
    private static let manualFolderHistoryLimitKey = "ManualFolderHistoryLimit"
    private static let manualFolderHistoryKey = "ManualFolderHistory"
    private static let serverConnectionHistoryKey = "ServerConnectionHistory"
    private static let maximumConcurrentCopiedFilesKey = "MaximumConcurrentCopiedFiles"
    private static let transferHistoryLimitKey = "TransferHistoryLimit"
    private static let visibleColumnsKey = "VisibleFileColumns"
    private static let bandedFileRowsKey = "BandedFileRows"
    private static let folderIconStyleKey = "FolderIconStyle"
    private static let colorThemeKey = "AppColorTheme"
    private static let defaultSpaceAnalyzerModeKey = "DefaultSpaceAnalyzerMode"
    private static let columnCustomizationKey = "FileTableColumnCustomization"
    static let maximumConcurrentTabsRange = 5...50
    static let manualFolderHistoryLimitRange = 0...20
    static let maximumConcurrentCopiedFilesRange = 1...5
    static let transferHistoryLimitRange = 0...500

    private let presentationDefaults: UserDefaults
    @Published var browserViewMode: FileBrowserViewMode {
        didSet { presentationDefaults.set(browserViewMode.rawValue, forKey: "BrowserViewMode") }
    }
    @Published var browserGrouping: FileGroupingMode {
        didSet { presentationDefaults.set(browserGrouping.rawValue, forKey: "BrowserGrouping") }
    }
    @Published var browserIconSize: Double {
        didSet {
            let clamped = FileBrowserPresentation.clampedIconSize(browserIconSize)
            if browserIconSize != clamped { browserIconSize = clamped }
            presentationDefaults.set(clamped, forKey: "BrowserIconSize")
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }
    @Published private(set) var systemColorScheme: ColorScheme

    @Published var maximumConcurrentTabs: Int {
        didSet {
            let clampedValue = Self.clampedTabLimit(maximumConcurrentTabs)
            guard maximumConcurrentTabs == clampedValue else {
                maximumConcurrentTabs = clampedValue
                return
            }

            UserDefaults.standard.set(maximumConcurrentTabs, forKey: Self.maximumConcurrentTabsKey)
        }
    }

    @Published var manualFolderHistoryLimit: Int {
        didSet {
            let clampedValue = Self.clampedManualFolderHistoryLimit(manualFolderHistoryLimit)
            guard manualFolderHistoryLimit == clampedValue else {
                manualFolderHistoryLimit = clampedValue
                return
            }

            UserDefaults.standard.set(manualFolderHistoryLimit, forKey: Self.manualFolderHistoryLimitKey)
            trimManualFolderHistory()
        }
    }

    @Published var maximumConcurrentCopiedFiles: Int {
        didSet {
            let clampedValue = Self.clampedMaximumConcurrentCopiedFiles(maximumConcurrentCopiedFiles)
            guard maximumConcurrentCopiedFiles == clampedValue else {
                maximumConcurrentCopiedFiles = clampedValue
                return
            }

            UserDefaults.standard.set(maximumConcurrentCopiedFiles, forKey: Self.maximumConcurrentCopiedFilesKey)
        }
    }

    @Published var transferHistoryLimit: Int {
        didSet {
            let clampedValue = Self.clampedTransferHistoryLimit(transferHistoryLimit)
            guard transferHistoryLimit == clampedValue else {
                transferHistoryLimit = clampedValue
                return
            }

            UserDefaults.standard.set(transferHistoryLimit, forKey: Self.transferHistoryLimitKey)
        }
    }

    @Published var showsBandedFileRows: Bool {
        didSet {
            UserDefaults.standard.set(showsBandedFileRows, forKey: Self.bandedFileRowsKey)
        }
    }

    @Published var folderIconStyle: FolderIconStyle {
        didSet {
            UserDefaults.standard.set(folderIconStyle.rawValue, forKey: Self.folderIconStyleKey)
        }
    }

    @Published var colorTheme: AppColorTheme {
        didSet {
            UserDefaults.standard.set(colorTheme.rawValue, forKey: Self.colorThemeKey)
        }
    }

    @Published var defaultSpaceAnalyzerMode: SpaceAnalyzerMode {
        didSet {
            UserDefaults.standard.set(defaultSpaceAnalyzerMode.rawValue, forKey: Self.defaultSpaceAnalyzerModeKey)
        }
    }

    @Published var visibleColumns: Set<FileColumn> {
        didSet {
            // "Name" can never be turned off, so at least one column always remains.
            guard visibleColumns.contains(.name) else {
                visibleColumns.insert(.name)
                return
            }

            UserDefaults.standard.set(visibleColumns.map(\.rawValue), forKey: Self.visibleColumnsKey)
            syncColumnCustomization()
        }
    }

    /// Column order, widths, and visibility of the file table. Visibility is
    /// mirrored with `visibleColumns`, so the header's right-click menu and the
    /// toolbar column chooser always agree.
    @Published var columnCustomization: TableColumnCustomization<FileItem> {
        didSet {
            guard columnCustomization != oldValue else {
                return
            }

            if let data = try? JSONEncoder().encode(columnCustomization) {
                UserDefaults.standard.set(data, forKey: Self.columnCustomizationKey)
            }

            let shownColumns = Set(FileColumn.allCases.filter { Self.isColumnVisible($0, in: columnCustomization) })
            if shownColumns != visibleColumns {
                visibleColumns = shownColumns
            }
        }
    }

    @Published var defaultSortColumn: FileColumn {
        didSet {
            FolderSortStore.shared.defaultSort = defaultSort
        }
    }

    @Published var defaultSortAscending: Bool {
        didSet {
            FolderSortStore.shared.defaultSort = defaultSort
        }
    }

    @Published private(set) var manualFolderHistory: [String]
    @Published private(set) var serverConnectionHistory: [String]
    private var appearanceObservation: NSObjectProtocol?
    private var volumeMountObservation: NSObjectProtocol?
    private var pendingServerConnections: [URL] = []
    var onServerConnectionSucceeded: ((URL) -> Void)?

    init(defaults: UserDefaults = .standard) {
        presentationDefaults = defaults
        browserViewMode = defaults.string(forKey: "BrowserViewMode")
            .flatMap(FileBrowserViewMode.init(rawValue:)) ?? .details
        browserGrouping = defaults.string(forKey: "BrowserGrouping")
            .flatMap(FileGroupingMode.init(rawValue:)) ?? .none
        browserIconSize = FileBrowserPresentation.clampedIconSize(
            (defaults.object(forKey: "BrowserIconSize") as? Double) ?? 80
        )
        let rawValue = defaults.string(forKey: Self.appearanceKey)
        self.appearance = rawValue.flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.systemColorScheme = Self.currentSystemColorScheme

        let savedTabLimit = defaults.integer(forKey: Self.maximumConcurrentTabsKey)
        self.maximumConcurrentTabs = savedTabLimit == 0 ? 20 : Self.clampedTabLimit(savedTabLimit)

        let savedManualFolderHistoryLimit = defaults.object(forKey: Self.manualFolderHistoryLimitKey) as? Int
        self.manualFolderHistoryLimit = savedManualFolderHistoryLimit.map(Self.clampedManualFolderHistoryLimit) ?? 5
        self.manualFolderHistory = defaults.stringArray(forKey: Self.manualFolderHistoryKey) ?? []
        self.serverConnectionHistory = defaults.stringArray(forKey: Self.serverConnectionHistoryKey) ?? []

        let savedMaximumConcurrentCopiedFiles = defaults.object(forKey: Self.maximumConcurrentCopiedFilesKey) as? Int
        self.maximumConcurrentCopiedFiles = savedMaximumConcurrentCopiedFiles.map(Self.clampedMaximumConcurrentCopiedFiles) ?? 3
        let savedTransferHistoryLimit = defaults.object(forKey: Self.transferHistoryLimitKey) as? Int
        self.transferHistoryLimit = savedTransferHistoryLimit.map(Self.clampedTransferHistoryLimit) ?? 100
        self.showsBandedFileRows = defaults.object(forKey: Self.bandedFileRowsKey) as? Bool ?? true
        self.folderIconStyle = defaults.string(forKey: Self.folderIconStyleKey)
            .flatMap(FolderIconStyle.init(rawValue:)) ?? .mac
        self.colorTheme = defaults.string(forKey: Self.colorThemeKey)
            .flatMap(AppColorTheme.init(rawValue:)) ?? .default
        self.defaultSpaceAnalyzerMode = defaults.string(forKey: Self.defaultSpaceAnalyzerModeKey)
            .flatMap(SpaceAnalyzerMode.init(rawValue:)) ?? .allFiles

        if let savedColumns = defaults.stringArray(forKey: Self.visibleColumnsKey) {
            var columns = Set(savedColumns.compactMap(FileColumn.init(rawValue:)))
            columns.insert(.name)
            self.visibleColumns = columns
        } else {
            self.visibleColumns = FileColumn.defaultVisible
        }
        self.columnCustomization = defaults.data(forKey: Self.columnCustomizationKey)
            .flatMap { try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: $0) }
            ?? TableColumnCustomization<FileItem>()

        let defaultSort = FolderSortStore.shared.defaultSort
        self.defaultSortColumn = defaultSort.column
        self.defaultSortAscending = defaultSort.ascending

        syncColumnCustomization()

        trimManualFolderHistory()
        trimServerConnectionHistory()
        appearanceObservation = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemColorScheme = Self.currentSystemColorScheme
            }
        }
        volumeMountObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mountedVolumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }

            Task { @MainActor [weak self] in
                self?.recordPendingConnection(mountedAt: mountedVolumeURL)
            }
        }
    }

    var defaultSort: FileSortDescriptor {
        FileSortDescriptor(column: defaultSortColumn, ascending: defaultSortAscending)
    }

    func forgetFolderSortChoices() {
        FolderSortStore.shared.forgetAllFolders()
    }

    /// Restores the default columns, column order, and widths.
    func resetColumns() {
        columnCustomization = TableColumnCustomization<FileItem>()
        visibleColumns = FileColumn.defaultVisible
    }

    var preferredColorScheme: ColorScheme {
        appearance.colorScheme ?? systemColorScheme
    }

    func toggleColumn(_ column: FileColumn) {
        guard !column.isRequired else {
            return
        }

        if visibleColumns.contains(column) {
            visibleColumns.remove(column)
        } else {
            visibleColumns.insert(column)
        }
    }

    func addManualFolderToHistory(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        guard manualFolderHistoryLimit > 0 else {
            manualFolderHistory = []
            UserDefaults.standard.set(manualFolderHistory, forKey: Self.manualFolderHistoryKey)
            return
        }

        let path = url.standardizedFileURL.path
        manualFolderHistory.removeAll { $0 == path }
        manualFolderHistory.insert(path, at: 0)
        trimManualFolderHistory()
    }

    func expectServerConnection(to url: URL) {
        let sanitizedURL = Self.sanitizedServerURL(url)
        pendingServerConnections.removeAll { Self.serverURLsReferToSameShare($0, sanitizedURL) }
        pendingServerConnections.append(sanitizedURL)

        for mountedVolumeURL in FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey],
            options: [.skipHiddenVolumes]
        ) ?? [] {
            if recordPendingConnection(mountedAt: mountedVolumeURL) {
                break
            }
        }
    }

    private func syncColumnCustomization() {
        var customization = columnCustomization
        for column in FileColumn.allCases where !column.isRequired {
            customization[visibility: column.id] = visibleColumns.contains(column) ? .visible : .hidden
        }

        if customization != columnCustomization {
            columnCustomization = customization
        }
    }

    private static func isColumnVisible(_ column: FileColumn, in customization: TableColumnCustomization<FileItem>) -> Bool {
        guard !column.isRequired else {
            return true
        }

        switch customization[visibility: column.id] {
        case .visible:
            return true
        case .hidden:
            return false
        default:
            return FileColumn.defaultVisible.contains(column)
        }
    }

    private static func clampedTabLimit(_ value: Int) -> Int {
        min(max(value, maximumConcurrentTabsRange.lowerBound), maximumConcurrentTabsRange.upperBound)
    }

    private static func clampedManualFolderHistoryLimit(_ value: Int) -> Int {
        min(max(value, manualFolderHistoryLimitRange.lowerBound), manualFolderHistoryLimitRange.upperBound)
    }

    private static func clampedMaximumConcurrentCopiedFiles(_ value: Int) -> Int {
        min(max(value, maximumConcurrentCopiedFilesRange.lowerBound), maximumConcurrentCopiedFilesRange.upperBound)
    }

    private static func clampedTransferHistoryLimit(_ value: Int) -> Int {
        min(max(value, transferHistoryLimitRange.lowerBound), transferHistoryLimitRange.upperBound)
    }

    private static var currentSystemColorScheme: ColorScheme {
        let interfaceStyle = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
        return interfaceStyle == "Dark" ? .dark : .light
    }

    private func trimManualFolderHistory() {
        var seenPaths = Set<String>()
        manualFolderHistory = manualFolderHistory.compactMap { path in
            guard !seenPaths.contains(path) else {
                return nil
            }

            seenPaths.insert(path)
            return path
        }
        manualFolderHistory = Array(manualFolderHistory.prefix(manualFolderHistoryLimit))
        UserDefaults.standard.set(manualFolderHistory, forKey: Self.manualFolderHistoryKey)
    }

    @discardableResult
    private func recordPendingConnection(mountedAt mountedVolumeURL: URL) -> Bool {
        guard
            let values = try? mountedVolumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]),
            let remountURL = values.volumeURLForRemounting,
            let pendingIndex = pendingServerConnections.firstIndex(where: {
                Self.serverURLsReferToSameShare($0, remountURL)
            })
        else {
            return false
        }

        let connectedURL = pendingServerConnections.remove(at: pendingIndex)
        let address = connectedURL.absoluteString
        serverConnectionHistory.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        serverConnectionHistory.insert(address, at: 0)
        trimServerConnectionHistory()
        onServerConnectionSucceeded?(mountedVolumeURL)
        return true
    }

    private func trimServerConnectionHistory() {
        var seenAddresses = Set<String>()
        serverConnectionHistory = serverConnectionHistory.compactMap { address in
            let comparisonAddress = address.lowercased()
            guard seenAddresses.insert(comparisonAddress).inserted else {
                return nil
            }
            return address
        }
        serverConnectionHistory = Array(serverConnectionHistory.prefix(20))
        UserDefaults.standard.set(serverConnectionHistory, forKey: Self.serverConnectionHistoryKey)
    }

    private static func sanitizedServerURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.password = nil
        return components.url ?? url
    }

    private static func serverURLsReferToSameShare(_ lhs: URL, _ rhs: URL) -> Bool {
        guard
            let lhsComponents = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
            let rhsComponents = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
            lhsComponents.scheme?.caseInsensitiveCompare(rhsComponents.scheme ?? "") == .orderedSame,
            lhsComponents.host?.caseInsensitiveCompare(rhsComponents.host ?? "") == .orderedSame
        else {
            return false
        }

        let lhsShare = firstPathComponent(of: lhsComponents.path)
        let rhsShare = firstPathComponent(of: rhsComponents.path)
        return lhsShare.isEmpty
            || rhsShare.isEmpty
            || lhsShare.caseInsensitiveCompare(rhsShare) == .orderedSame
    }

    private static func firstPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}
