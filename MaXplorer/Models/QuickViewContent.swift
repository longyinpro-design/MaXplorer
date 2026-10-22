import Foundation

struct QuickViewContent: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let detail: String
    let allowsTextEncoding: Bool

    /// An advisory only: neither the extension nor Quick Look's display state
    /// tells us whether a document is encrypted or rendered successfully.
    var isLegacyOfficeDocument: Bool {
        ["doc", "dot", "xls", "xlt", "ppt", "pot", "pps"].contains(url.pathExtension.lowercased())
    }
}
