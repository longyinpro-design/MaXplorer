import AppKit
import Darwin
import Foundation
import SwiftUI

/// The seven Finder tag colors, using the same numbering Finder stores in the
/// `_kMDItemUserTags` extended attribute (`"Name\n<color>"`).
nonisolated enum FinderTagColor: Int, CaseIterable, Hashable, Sendable {
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    var color: Color {
        switch self {
        case .gray: return Color(nsColor: .systemGray)
        case .green: return Color(nsColor: .systemGreen)
        case .purple: return Color(nsColor: .systemPurple)
        case .blue: return Color(nsColor: .systemBlue)
        case .yellow: return Color(nsColor: .systemYellow)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        }
    }
}

/// Reads Finder tag colors straight from the file's extended attributes.
/// `URLResourceKey.tagNamesKey` only exposes names, while the attribute also
/// carries each tag's color, including for custom tags.
nonisolated enum FinderTagReader {
    private static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// Finder draws at most three overlapping dots per item.
    static let maximumDisplayedColors = 3

    static func tagColors(for url: URL) -> [FinderTagColor] {
        url.withUnsafeFileSystemRepresentation { path -> [FinderTagColor] in
            guard let path else {
                return []
            }

            let length = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0 else {
                return []
            }

            var data = Data(count: length)
            let bytesRead = data.withUnsafeMutableBytes { buffer in
                getxattr(path, attributeName, buffer.baseAddress, length, 0, XATTR_NOFOLLOW)
            }
            guard bytesRead > 0 else {
                return []
            }

            return colors(fromPropertyList: data.prefix(bytesRead))
        }
    }

    static func colors(fromPropertyList data: Data) -> [FinderTagColor] {
        guard let tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }

        var colors: [FinderTagColor] = []
        for tag in tags {
            guard
                let colorNumber = tag.split(separator: "\n").last.flatMap({ Int($0) }),
                let color = FinderTagColor(rawValue: colorNumber),
                !colors.contains(color)
            else {
                continue
            }

            colors.append(color)
            if colors.count == maximumDisplayedColors {
                break
            }
        }
        return colors
    }
}

/// Reads tags for rows that are actually on screen. Directory listings skip
/// tag xattrs entirely, so a large folder pays for only its visible rows.
nonisolated enum FinderTagLoader {
    static func colors(for url: URL) async -> [FinderTagColor] {
        await Task.detached(priority: .utility) {
            FinderTagReader.tagColors(for: url)
        }.value
    }
}
