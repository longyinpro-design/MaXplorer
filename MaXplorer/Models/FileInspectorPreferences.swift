import Foundation

struct FileInspectorPreferences: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case preview, details
        var id: String { rawValue }
        var title: String { self == .preview ? "预览" : "详情" }
    }
    static let defaultWidth = 320.0
    static let widthRange = 240.0...520.0
    var isVisible = false
    var mode: Mode = .preview
    var width = defaultWidth
    init(isVisible: Bool = false, mode: Mode = .preview, width: Double = defaultWidth) {
        self.isVisible = isVisible
        self.mode = mode
        self.width = Self.clampedWidth(width)
    }
    init(defaults: UserDefaults) {
        isVisible = defaults.bool(forKey: "fileInspector.visible")
        mode = Mode(rawValue: defaults.string(forKey: "fileInspector.mode") ?? "") ?? .preview
        if defaults.object(forKey: "fileInspector.width") != nil {
            width = Self.clampedWidth(defaults.double(forKey: "fileInspector.width"))
        }
    }
    static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(widthRange.upperBound, max(widthRange.lowerBound, width))
    }
    func save(to defaults: UserDefaults) {
        defaults.set(isVisible, forKey: "fileInspector.visible")
        defaults.set(mode.rawValue, forKey: "fileInspector.mode")
        defaults.set(Self.clampedWidth(width), forKey: "fileInspector.width")
    }
}
