import Foundation
import Darwin

nonisolated enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolder
    case currentVolume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentFolder: return "当前文件夹"
        case .currentVolume: return "当前卷"
        }
    }

    var description: String {
        switch self {
        case .currentFolder: return "搜索当前文件夹及其所有子文件夹"
        case .currentVolume: return "搜索当前文件夹所在卷"
        }
    }
}

nonisolated enum SearchMatchMode: String, CaseIterable, Identifiable, Sendable {
    case contains
    case glob

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "包含"
        case .glob: return "通配符"
        }
    }

    var placeholder: String {
        switch self {
        case .contains: return "搜索文件名"
        case .glob: return "例如 *.jpg"
        }
    }

    func matches(_ name: String, query: String) -> Bool {
        switch self {
        case .contains:
            return name.localizedCaseInsensitiveContains(query)
        case .glob:
            // fnmatch reads LC_CTYPE. A thread-local UTF-8 locale preserves its
            // Unicode character boundaries and bracket-class definitions without
            // changing the process locale or expanding ß/ﬃ/İ via full case folding.
            let previous = uselocale(SearchGlobLocale.shared.value)
            defer { uselocale(previous) }
            return query.precomposedStringWithCanonicalMapping.withCString { pattern in
                name.precomposedStringWithCanonicalMapping.withCString { candidate in
                    fnmatch(pattern, candidate, FNM_CASEFOLD) == 0
                }
            }
        }
    }
}

nonisolated struct SearchProgress: Sendable, Equatable {
    let scannedCount: Int
    let skippedCount: Int
}

nonisolated struct SearchSummary: Sendable, Equatable {
    let scannedCount: Int
    let skippedCount: Int
}

nonisolated enum SearchEvent: Sendable {
    case batch([FileItem])
    case progress(SearchProgress)
    case finished(SearchSummary)
}

/// Darwin ships this UTF-8 locale. The immutable handle is shared, but uselocale
/// changes only the calling thread and is restored before this synchronous match returns.
private nonisolated final class SearchGlobLocale: @unchecked Sendable {
    static let shared = SearchGlobLocale()
    let value: locale_t

    private init() {
        guard let value = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
            preconditionFailure("Unable to create the macOS UTF-8 glob locale")
        }
        self.value = value
    }

    deinit { freelocale(value) }
}
