import Foundation

/// Metadata-only predicates. Date ranges are [afterInclusive, beforeExclusive).
nonisolated struct SearchFilters: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case any, files, folders, packages
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case negativeSize
        case reversedSizeRange
        case invalidDateRange
        case invalidExtension(String)
        case invalidSizeMiB(String)

        var errorDescription: String? {
            switch self {
            case .negativeSize: return "文件大小不能为负数。"
            case .reversedSizeRange: return "最小大小不能大于最大大小。"
            case .invalidDateRange: return "日期范围的开始必须早于结束。"
            case .invalidExtension(let value): return "扩展名无效：\(value)"
            case .invalidSizeMiB(let value): return "大小必须为不超出范围的非负整数 MiB：\(value)"
            }
        }
    }

    var kind: Kind = .any
    var extensions: Set<String> = []
    var minimumSize: Int64?
    var maximumSize: Int64?
    var createdAfterInclusive: Date?
    var createdBeforeExclusive: Date?
    var modifiedAfterInclusive: Date?
    var modifiedBeforeExclusive: Date?

    var isActive: Bool {
        kind != .any || !extensions.isEmpty || minimumSize != nil || maximumSize != nil ||
            createdAfterInclusive != nil || createdBeforeExclusive != nil ||
            modifiedAfterInclusive != nil || modifiedBeforeExclusive != nil
    }

    func validate() throws {
        if let minimumSize, minimumSize < 0 { throw ValidationError.negativeSize }
        if let maximumSize, maximumSize < 0 { throw ValidationError.negativeSize }
        if let minimumSize, let maximumSize, minimumSize > maximumSize {
            throw ValidationError.reversedSizeRange
        }
        for (start, end) in [(createdAfterInclusive, createdBeforeExclusive),
                             (modifiedAfterInclusive, modifiedBeforeExclusive)] {
            if let start, let end, start >= end { throw ValidationError.invalidDateRange }
        }
        _ = try normalizedExtensions()
    }

    func matches(_ item: FileItem) -> Bool {
        // Invalid drafts fail closed even if a caller has not yet displayed validation.
        guard (try? validate()) != nil, let suffixes = try? normalizedExtensions() else { return false }
        switch kind {
        case .any: break
        case .files:
            guard !item.isDirectory, !item.isPackage, !item.isNetworkLocation else { return false }
        case .folders:
            guard item.isDirectory, !item.isPackage, !item.isNetworkLocation else { return false }
        case .packages:
            guard item.isPackage, !item.isNetworkLocation else { return false }
        }
        if !suffixes.isEmpty {
            guard suffixes.contains(item.url.pathExtension.precomposedStringWithCanonicalMapping.lowercased()) else { return false }
        }
        if minimumSize != nil || maximumSize != nil {
            guard !item.isDirectory, !item.isPackage, !item.isNetworkLocation,
                  let size = item.size, size >= 0 else { return false }
            if let minimumSize, size < minimumSize { return false }
            if let maximumSize, size > maximumSize { return false }
        }
        return Self.matches(item.createdAt, after: createdAfterInclusive, before: createdBeforeExclusive) &&
            Self.matches(item.modifiedAt, after: modifiedAfterInclusive, before: modifiedBeforeExclusive)
    }

    static func parseExtensions(_ text: String) throws -> Set<String> {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        var result = Set<String>()
        for part in parts {
            let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.insert(try normalizeExtension(value)) }
        }
        return result
    }

    /// Blank means no bound; integer MiB conversion never wraps.
    static func parseSizeMiB(_ text: String) throws -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Int64(value), number >= 0 else { throw ValidationError.invalidSizeMiB(text) }
        let (bytes, overflow) = number.multipliedReportingOverflow(by: 1_048_576)
        guard !overflow else { throw ValidationError.invalidSizeMiB(text) }
        return bytes
    }

    private func normalizedExtensions() throws -> Set<String> {
        try Set(extensions.map(Self.normalizeExtension))
    }

    private static func normalizeExtension(_ input: String) throws -> String {
        let value = String(input.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." }))
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
            throw ValidationError.invalidExtension(input)
        }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func matches(_ date: Date?, after: Date?, before: Date?) -> Bool {
        guard after != nil || before != nil else { return true }
        guard let date else { return false }
        if let after, date < after { return false }
        if let before, date >= before { return false }
        return true
    }
}
