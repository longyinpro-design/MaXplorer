import AppKit
import SwiftUI

struct ResizableSheetWindowBridge: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> ResizableSheetWindowView {
        ResizableSheetWindowView(minSize: minSize)
    }

    func updateNSView(_ nsView: ResizableSheetWindowView, context: Context) {
        nsView.minSize = minSize
        nsView.configureWindow()
    }
}

final class ResizableSheetWindowView: NSView {
    var minSize: NSSize

    init(minSize: NSSize) {
        self.minSize = minSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else {
            return
        }

        window.styleMask.insert(.resizable)
        window.contentMinSize = minSize
        window.standardWindowButton(.zoomButton)?.isEnabled = true

    }
}
