import Foundation

nonisolated enum FileBrowserViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case details, icons, tiles
    var systemImage: String {
        switch self {
        case .details: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .tiles: return "rectangle.grid.1x2"
        }
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .details: return "详细信息"
        case .icons: return "图标"
        case .tiles: return "平铺"
        }
    }
}

nonisolated enum FileGroupingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, kind, modifiedDate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不分组"
        case .kind: return "类型"
        case .modifiedDate: return "修改日期"
        }
    }
}

nonisolated struct FilePresentationSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [FileItem]
}

nonisolated enum FileBrowserNavigationDirection: Sendable {
    case up, down, left, right
}

/// Operates on the already sorted input. Grouping never reorders items inside a group.
nonisolated enum FileBrowserPresentation {
    static func sections(
        from sortedItems: [FileItem], grouping: FileGroupingMode,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [FilePresentationSection] {
        switch grouping {
        case .none:
            return [FilePresentationSection(id: "all", title: "", items: sortedItems)]
        case .kind:
            let groups = Dictionary(grouping: sortedItems, by: \.displayKind)
            return groups.keys.sorted { lhs, rhs in
                let comparison = lhs.localizedStandardCompare(rhs)
                return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
            }.map { FilePresentationSection(id: "kind:\($0)", title: $0, items: groups[$0]!) }
        case .modifiedDate:
            let today = calendar.startOfDay(for: now)
            // Calendar arithmetic preserves civil-day boundaries across DST transitions.
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let week = calendar.date(byAdding: .day, value: -7, to: today)!
            let month = calendar.date(byAdding: .day, value: -30, to: today)!
            let groups = Dictionary(grouping: sortedItems) { item -> Int in
                guard let date = item.modifiedAt else { return 6 }
                if date > now { return 0 }
                if date >= today { return 1 }
                if date >= yesterday { return 2 }
                if date >= week { return 3 }
                if date >= month { return 4 }
                return 5
            }
            let labels = [("future", "未来"), ("today", "今天"), ("yesterday", "昨天"),
                          ("last7days", "过去 7 天"), ("last30days", "过去 30 天"),
                          ("older", "更早"), ("unknown", "未知")]
            return labels.enumerated().compactMap { index, label in
                guard let items = groups[index] else { return nil }
                return FilePresentationSection(id: label.0, title: label.1, items: items)
            }
        }
    }

    /// Selection and keyboard navigation must use this same order as the visible sections.
    static func flattenedItems(in sections: [FilePresentationSection]) -> [FileItem] {
        sections.flatMap(\.items)
    }

    static func selectionRange(from anchor: URL, to target: URL, in sections: [FilePresentationSection]) -> [FileItem] {
        let items = flattenedItems(in: sections)
        guard let start = items.firstIndex(where: { $0.url == anchor }),
              let end = items.firstIndex(where: { $0.url == target }) else { return [] }
        return Array(items[min(start, end)...max(start, end)])
    }

    static func clampedIconSize(_ size: Double) -> Double {
        guard size.isFinite else { return 80 }
        return min(160, max(48, size))
    }

    /// Each section starts a new grid row. Left/right stay in that row; up/down
    /// use the nearest available column in the adjacent row, including across sections.
    static func navigationIndex(from index: Int?, direction: FileBrowserNavigationDirection, itemCount: Int, columns: Int) -> Int? {
        navigationIndex(from: index, direction: direction, sectionCounts: [itemCount], columns: columns)
    }

    static func navigationIndex(from index: Int?, direction: FileBrowserNavigationDirection, sectionCounts: [Int], columns: Int) -> Int? {
        let width = max(1, columns)
        var rows: [Range<Int>] = []
        var offset = 0
        for count in sectionCounts where count > 0 {
            var remaining = count
            while remaining > 0 {
                let length = min(width, remaining)
                rows.append(offset..<(offset + length))
                offset += length
                remaining -= length
            }
        }
        guard offset > 0 else { return nil }
        guard let index, let rowIndex = rows.firstIndex(where: { $0.contains(index) }) else { return 0 }
        let row = rows[rowIndex]
        let column = index - row.lowerBound
        switch direction {
        case .left: return max(row.lowerBound, index - 1)
        case .right: return min(row.upperBound - 1, index + 1)
        case .up, .down:
            let next = direction == .up ? rowIndex - 1 : rowIndex + 1
            guard rows.indices.contains(next) else { return index }
            return rows[next].lowerBound + min(column, rows[next].count - 1)
        }
    }
}
