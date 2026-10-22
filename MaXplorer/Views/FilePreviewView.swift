import QuickLookUI
import SwiftUI

/// Keep file format rendering and text encoding in the system preview provider.
struct FilePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Preserve page/zoom state across unrelated SwiftUI updates.
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // A sheet can disappear without closing its parent window.
        view.close()
    }
}
