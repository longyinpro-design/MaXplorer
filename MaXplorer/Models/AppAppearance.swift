import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum FolderIconStyle: String, CaseIterable, Identifiable {
    case mac
    case xplorer

    var id: Self { self }

    var displayName: String {
        switch self {
        case .mac: "macOS 风格"
        case .xplorer: "Windows 风格"
        }
    }
}
