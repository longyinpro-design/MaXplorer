import Foundation

/// How a batch rename applies letter case to the generated names.
nonisolated enum RenameCaseMode: String, CaseIterable, Identifiable, Sendable {
    case unchanged
    case lowercase
    case uppercase
    case capitalized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: return "保持原样"
        case .lowercase: return "全部小写"
        case .uppercase: return "全部大写"
        case .capitalized: return "首字母大写"
        }
    }
}

nonisolated struct BatchRenameOptions: Equatable, Sendable {
    var template: String = BatchRenameOptions.defaultTemplate
    var findText: String = ""
    var replaceText: String = ""
    var replaceCaseSensitive: Bool = true
    var caseMode: RenameCaseMode = .unchanged
    var startNumber: Int = 1
    var step: Int = 1
    /// Zero or negative means "no zero padding".
    var padding: Int = 2
    var keepsExtension: Bool = true

    static let defaultTemplate = "{name}"
    static let templateHelp = "可用变量：{name} 原名、{ext} 扩展名、{index} 序号、{date} 日期、{parent} 上级文件夹名"
}

/// Expands the template for one item. Kept free of file-system access so the
/// preview and the execution can never disagree about the resulting name.
nonisolated enum BatchRenameName {
    static func expandedName(
        for url: URL,
        index: Int,
        options: BatchRenameOptions,
        date: Date = Date()
    ) -> String {
        let extendedName = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let sequence = options.startNumber + max(1, options.step) * index
        let numberText: String
        if options.padding > 0 {
            numberText = String(format: "%0\(min(options.padding, 12))d", sequence)
        } else {
            numberText = String(sequence)
        }

        let values = [
            "{name}": stem, "{ext}": extendedName, "{index}": numberText,
            "{date}": dateText(date), "{parent}": parentName,
        ]
        // Only tokens in the original template are expanded. Inserted file
        // names remain literal, even when they contain text such as {index}.
        var name = ""
        var remainder = options.template[...]
        while !remainder.isEmpty {
            if let token = values.keys.first(where: { remainder.hasPrefix($0) }) {
                name += values[token]!
                remainder = remainder.dropFirst(token.count)
            } else {
                name.append(remainder.removeFirst())
            }
        }

        if !options.findText.isEmpty {
            name = name.replacingOccurrences(
                of: options.findText,
                with: options.replaceText,
                options: options.replaceCaseSensitive ? [] : [.caseInsensitive]
            )
        }

        switch options.caseMode {
        case .unchanged:
            break
        case .lowercase:
            name = name.lowercased()
        case .uppercase:
            name = name.uppercased()
        case .capitalized:
            name = name.capitalized
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // When the template does not mention the extension, keep the original
        // one so a batch rename never silently turns "photo.jpg" into "photo".
        if options.keepsExtension,
           !options.template.contains("{ext}"),
           !extendedName.isEmpty,
           !name.isEmpty,
           !name.lowercased().hasSuffix(".\(extendedName.lowercased())") {
            name += ".\(extendedName)"
        }

        return name
    }

    static func dateText(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

nonisolated struct BatchRenamePreviewItem: Identifiable, Equatable, Sendable {
    let id: Int
    let source: URL
    let originalName: String
    let proposedName: String
    /// A user-facing reason why this item cannot be renamed, or nil when valid.
    let issue: String?

    var target: URL {
        source.deletingLastPathComponent().appendingPathComponent(proposedName)
    }

    var isChange: Bool {
        proposedName != originalName
    }
}
