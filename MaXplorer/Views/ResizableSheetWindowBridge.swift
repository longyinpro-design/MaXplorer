import AppKit
import SwiftUI

struct ResizableSheetWindowBridge: NSViewRepresentable {
    let minSize: NSSize
    var initialSize: NSSize? = nil

    func makeNSView(context: Context) -> ResizableSheetWindowView {
        ResizableSheetWindowView(minSize: minSize, initialSize: initialSize)
    }

    func updateNSView(_ nsView: ResizableSheetWindowView, context: Context) {
        nsView.minSize = minSize
        nsView.initialSize = initialSize
        nsView.configureWindow()
    }
}

final class ResizableSheetWindowView: NSView {
    var minSize: NSSize
    var initialSize: NSSize?
    private weak var sizedWindow: NSWindow?

    init(minSize: NSSize, initialSize: NSSize?) {
        self.minSize = minSize
        self.initialSize = initialSize
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
        guard let initialSize, sizedWindow !== window else { return }
        sizedWindow = window
        // SwiftUI gives Quick Look its intrinsic minimum width. Set the requested
        // opening size after attachment, once, so later user resizing is preserved.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.setContentSize(initialSize)
        }
    }
}
