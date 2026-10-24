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
            return query.withCString { pattern in
                name.withCString { candidate in
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
