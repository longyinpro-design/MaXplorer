import SwiftUI

enum AppColorTheme: String, CaseIterable, Identifiable {
    case `default`
    case water
    case earth
    case fire
    case air

    var id: Self { self }

    var displayName: String {
        switch self {
        case .default: "默认"
        case .water: "水"
        case .earth: "地"
        case .fire: "火"
        case .air: "风"
        }
    }

    var settingsDisplayName: String {
        switch self {
        case .default: displayName
        case .water: "💧 \(displayName)"
        case .earth: "🌍 \(displayName)"
        case .fire: "🔥 \(displayName)"
        case .air: "🌬️ \(displayName)"
        }
    }

    var tintColor: Color {
        switch self {
        case .default: .accentColor
        case .water: .blue
        case .earth: .green
        case .fire: .orange
        case .air: .gray
        }
    }

    var usesElevatedTransparency: Bool {
        self == .air
    }

    func surfaceTint(for colorScheme: ColorScheme, intensity: Double = 1) -> Color {
        guard self != .default else {
            return .clear
        }

        let baseOpacity = colorScheme == .dark ? 0.16 : 0.10
        return tintColor.opacity(baseOpacity * intensity)
    }

    func backdropTint(for colorScheme: ColorScheme) -> Color {
        guard self != .default else {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.08)
        }

        return tintColor.opacity(colorScheme == .dark ? 0.24 : 0.15)
    }
}

private struct AppColorThemeKey: EnvironmentKey {
    static let defaultValue = AppColorTheme.default
}

extension EnvironmentValues {
    var appColorTheme: AppColorTheme {
        get { self[AppColorThemeKey.self] }
        set { self[AppColorThemeKey.self] = newValue }
    }
}

struct ThemedSurfaceBackground: View {
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    let intensity: Double

    init(intensity: Double = 1) {
        self.intensity = intensity
    }

    var body: some View {
        ZStack {
            if colorTheme.usesElevatedTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            colorTheme.surfaceTint(for: colorScheme, intensity: intensity)
        }
    }
}

struct ThemedBarBackground: View {
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorTheme.usesElevatedTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
            colorTheme.surfaceTint(for: colorScheme, intensity: 0.75)
        }
    }
}

struct ThemedContentBackground: View {
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorTheme.usesElevatedTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
            colorTheme.surfaceTint(for: colorScheme, intensity: 0.5)
        }
    }
}

struct ThemedControlBackground: View {
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorTheme.usesElevatedTransparency {
                Rectangle().fill(.thinMaterial)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
            colorTheme.surfaceTint(for: colorScheme, intensity: 0.9)
        }
    }
}
