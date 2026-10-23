import Foundation

/// A selectable column in the file table. `name` is always shown and cannot be
/// hidden; the rest can be toggled from the column chooser and are persisted.
/// Declaration order here is the canonical left-to-right display order.
enum FileColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case kind
    case size
    case dateModified
    case dateCreated
    case dateTaken
    case owner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .kind: return "类型"
        case .size: return "大小"
        case .dateModified: return "修改日期"
        case .dateCreated: return "创建日期"
        case .dateTaken: return "拍摄日期"
        case .owner: return "所有者"
        }
    }

    /// Required columns are always visible and cannot be unchecked.
    var isRequired: Bool {
        self == .name
    }

    static let defaultVisible: Set<FileColumn> = [.name, .kind, .size, .dateModified]
}

extension DirectoryListingOptions {
    /// Only fetch the slow per-file metadata when its column is visible. Finder
    /// tag colors are loaded lazily by the icon renderer for visible rows, so
    /// listing a large folder does not pay one xattr read per item.
    init(columns: Set<FileColumn>) {
        self.init(
            includeOwner: columns.contains(.owner),
            includeDateTaken: columns.contains(.dateTaken),
            includeTags: false
        )
    }
}

/// A single-column sort: the column the table is sorted by and its direction.
/// Stored per folder and as the app-wide default, so it has to be Codable,
/// which `KeyPathComparator` is not.
struct FileSortDescriptor: Equatable, Codable, Sendable {
    var column: FileColumn
    var ascending: Bool

    static let fallback = FileSortDescriptor(column: .name, ascending: true)

    /// Columns offered as the default sort. Owner and Date Taken are left out
    /// because their values are only loaded while their columns are visible.
    static let defaultSortColumns: [FileColumn] = [.name, .kind, .size, .dateModified, .dateCreated]

    init(column: FileColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Reads the primary sort from the table's comparators. The key paths match
    /// the ones the table columns declare, so clicking a header round-trips.
    init?(_ sortOrder: [KeyPathComparator<FileItem>]) {
        guard
            let primary = sortOrder.first,
            let column = FileColumn.allCases.first(where: { $0.comparator(order: .forward).keyPath == primary.keyPath })
        else {
            return nil
        }

        self.init(column: column, ascending: primary.order == .forward)
    }

    var comparators: [KeyPathComparator<FileItem>] {
        [column.comparator(order: ascending ? .forward : .reverse)]
    }
}

extension FileColumn {
    func comparator(order: SortOrder) -> KeyPathComparator<FileItem> {
        switch self {
        case .name: return KeyPathComparator(\FileItem.name, order: order)
        case .kind: return KeyPathComparator(\FileItem.displayKind, order: order)
        case .size: return KeyPathComparator(\FileItem.sortSize, order: order)
        case .dateModified: return KeyPathComparator(\FileItem.sortModifiedAt, order: order)
        case .dateCreated: return KeyPathComparator(\FileItem.sortCreatedAt, order: order)
        case .dateTaken: return KeyPathComparator(\FileItem.sortDateTaken, order: order)
        case .owner: return KeyPathComparator(\FileItem.sortOwner, order: order)
        }
    }
}

/// Sorts a folder listing quickly. `sorted(using: KeyPathComparator)` walks the
/// key path (and rebuilds computed values such as the kind string) on every
/// comparison; here each item's sort key is computed once and the comparisons
/// run on plain arrays. Ties fall back to the name, like Finder.
nonisolated enum FileSorter {
    static func sorted(_ items: [FileItem], by descriptor: FileSortDescriptor) -> [FileItem] {
        guard items.count > 1 else {
            return items
        }

        let names = items.map(\.name)
        let primary: (Int, Int) -> ComparisonResult

        switch descriptor.column {
        case .name:
            primary = { names[$0].localizedStandardCompare(names[$1]) }
        case .kind:
            primary = stringOrder(items.map(\.displayKind))
        case .owner:
            primary = stringOrder(items.map(\.sortOwner))
        case .size:
            primary = numericOrder(items.map { Double($0.sortSize) })
        case .dateModified:
            primary = numericOrder(items.map(\.sortModifiedAt.timeIntervalSinceReferenceDate))
        case .dateCreated:
            primary = numericOrder(items.map(\.sortCreatedAt.timeIntervalSinceReferenceDate))
        case .dateTaken:
            primary = numericOrder(items.map(\.sortDateTaken.timeIntervalSinceReferenceDate))
        }

        let ascending = descriptor.ascending
        let breaksTiesByName = descriptor.column != .name
        let indices = Array(items.indices).sorted { lhs, rhs in
            var result = primary(lhs, rhs)
            if !ascending {
                result = result.reversed
            }
            if result == .orderedSame && breaksTiesByName {
                result = names[lhs].localizedStandardCompare(names[rhs])
            }
            if result == .orderedSame {
                // Keep the listing order for exact ties so the sort is stable.
                return lhs < rhs
            }
            return result == .orderedAscending
        }

        return indices.map { items[$0] }
    }

    private static func stringOrder(_ keys: [String]) -> (Int, Int) -> ComparisonResult {
        { keys[$0].localizedStandardCompare(keys[$1]) }
    }

    private static func numericOrder(_ keys: [Double]) -> (Int, Int) -> ComparisonResult {
        { lhs, rhs in
            if keys[lhs] < keys[rhs] { return .orderedAscending }
            if keys[lhs] > keys[rhs] { return .orderedDescending }
            return .orderedSame
        }
    }
}

nonisolated private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
