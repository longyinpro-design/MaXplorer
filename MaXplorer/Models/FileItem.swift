import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }

    let url: URL
    let name: String
    let typeDescription: String
    let isDirectory: Bool
    let isPackage: Bool
    let isAlias: Bool
    let aliasTargetURL: URL?
    let isAliasTargetDirectory: Bool
    let isAliasTargetPackage: Bool
    let isHidden: Bool
    let size: Int64?
    let modifiedAt: Date?
    let createdAt: Date?
    let dateTaken: Date?
    let owner: String?
    let tagColors: [FinderTagColor]
    let isNetworkLocation: Bool

    nonisolated init(
        url: URL,
        name: String,
        typeDescription: String,
        isDirectory: Bool,
        isPackage: Bool,
        isAlias: Bool,
        aliasTargetURL: URL?,
        isAliasTargetDirectory: Bool,
        isAliasTargetPackage: Bool,
        isHidden: Bool,
        size: Int64?,
        modifiedAt: Date?,
        createdAt: Date? = nil,
        dateTaken: Date? = nil,
        owner: String? = nil,
        tagColors: [FinderTagColor] = [],
        isNetworkLocation: Bool = false
    ) {
        self.url = url
        self.name = name
        self.typeDescription = typeDescription
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAlias = isAlias
        self.aliasTargetURL = aliasTargetURL
        self.isAliasTargetDirectory = isAliasTargetDirectory
        self.isAliasTargetPackage = isAliasTargetPackage
        self.isHidden = isHidden
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.dateTaken = dateTaken
        self.owner = owner
        self.tagColors = tagColors
        self.isNetworkLocation = isNetworkLocation
    }
}

extension FileItem {
    nonisolated var opensInApp: Bool {
        guard !isNetworkLocation else {
            return false
        }

        return (isDirectory && !isPackage) || (isAlias && isAliasTargetDirectory && !isAliasTargetPackage && aliasTargetURL != nil)
    }

    var navigationURL: URL? {
        if isDirectory && !isPackage {
            return url
        }

        if isAlias && isAliasTargetDirectory && !isAliasTargetPackage {
            return aliasTargetURL
        }

        return nil
    }

    nonisolated var displayKind: String {
        if isNetworkLocation {
            return typeDescription.isEmpty ? "网络位置" : typeDescription
        }

        if isAlias && isAliasTargetDirectory && !isAliasTargetPackage {
            return "文件夹替身"
        }

        if isAlias {
            return typeDescription.isEmpty ? "替身" : typeDescription
        }

        if isPackage {
            return typeDescription.isEmpty ? "软件包" : typeDescription
        }

        if isDirectory {
            return "文件夹"
        }

        return FileTypeDisplayName.name(for: url, fallback: typeDescription.isEmpty ? "文件" : typeDescription)
    }

    var displaySize: String {
        guard !opensInApp, let size else {
            return ""
        }

        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    nonisolated var sortSize: Int64 {
        guard !opensInApp, let size else {
            return -1
        }

        return size
    }

    nonisolated var sortModifiedAt: Date {
        modifiedAt ?? .distantPast
    }

    nonisolated var sortCreatedAt: Date {
        createdAt ?? .distantPast
    }

    nonisolated var sortDateTaken: Date {
        dateTaken ?? .distantPast
    }

    nonisolated var sortOwner: String {
        owner ?? ""
    }

    var displayCreated: String {
        createdAt.map(Self.columnDateFormatter.string(from:)) ?? ""
    }

    var displayModified: String {
        modifiedAt.map(Self.columnDateFormatter.string(from:)) ?? ""
    }

    var displayDateTaken: String {
        dateTaken.map(Self.columnDateFormatter.string(from:)) ?? ""
    }

    var displayOwner: String {
        owner ?? ""
    }

    private static let columnDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// Some Office installations register only English type descriptions, even in a
// Chinese app. These are display labels only; previewing still uses the original URL.
nonisolated enum FileTypeDisplayName {
    static func name(for url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        let name: String
        switch ext {
        case "xls": name = "Excel 97–2004 工作簿"
        case "xlsx": name = "Excel 工作簿"
        case "xlsm": name = "Excel 启用宏的工作簿"
        case "xlsb": name = "Excel 二进制工作簿"
        case "xlt": name = "Excel 97–2004 模板"
        case "xltx": name = "Excel 模板"
        case "xltm": name = "Excel 启用宏的模板"
        case "doc": name = "Word 97–2004 文稿"
        case "docx": name = "Word 文稿"
        case "docm": name = "Word 启用宏的文稿"
        case "dot": name = "Word 97–2004 模板"
        case "dotx": name = "Word 模板"
        case "dotm": name = "Word 启用宏的模板"
        case "ppt": name = "PowerPoint 97–2003 演示文稿"
        case "pptx": name = "PowerPoint 演示文稿"
        case "pptm": name = "PowerPoint 启用宏的演示文稿"
        case "pps": name = "PowerPoint 97–2003 放映"
        case "ppsx": name = "PowerPoint 放映"
        case "ppsm": name = "PowerPoint 启用宏的放映"
        case "pot": name = "PowerPoint 97–2003 模板"
        case "potx": name = "PowerPoint 模板"
        case "potm": name = "PowerPoint 启用宏的模板"
        default: return fallback
        }
        return "\(name)（.\(ext)）"
    }
}
