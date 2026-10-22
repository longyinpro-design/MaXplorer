import AppKit
import SwiftUI

/// The browser owns the preview selection; this adapter owns only its native
/// window. A regular window has no sheet attachment limiting its upper edge.
struct QuickViewWindowPresenter: NSViewRepresentable {
    @Binding var content: QuickViewContent?
    let colorTheme: AppColorTheme
    let colorScheme: ColorScheme?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> PreviewWindowAnchorView {
        let view = PreviewWindowAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.scheduleUpdate(owner: view?.window)
        }
        return view
    }

    func updateNSView(_ view: PreviewWindowAnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleUpdate(owner: view.window)
    }

    static func dismantleNSView(_ view: PreviewWindowAnchorView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.dismiss(clearSelection: true)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: QuickViewWindowPresenter
        private weak var owner: NSWindow?
        private var window: NSWindow?
        private var hosting: NSHostingController<AnyView>?
        private var contentID: UUID?
        private var observers: [NSObjectProtocol] = []
        private var fitWork: DispatchWorkItem?
        private var updateGeneration = 0

        init(parent: QuickViewWindowPresenter) { self.parent = parent }

        func scheduleUpdate(owner: NSWindow?) {
            updateGeneration += 1
            let generation = updateGeneration
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, generation == self.updateGeneration else { return }
                self.update(owner: owner)
            }
        }

        private func update(owner: NSWindow?) {
            guard let content = parent.content else {
                dismiss(clearSelection: false)
                return
            }
            guard let owner else { return }
            let isNewContent = contentID != content.id
            if window == nil {
                self.owner = owner
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.tabbingMode = .disallowed
                window.identifier = NSUserInterfaceItemIdentifier("MaXplorer.QuickView")
                let hosting = NSHostingController(rootView: rootView(content))
                // Quick Look's intrinsic size must not lock native edge resizing.
                hosting.sizingOptions = []
                window.contentViewController = hosting
                self.hosting = hosting
                self.window = window
                if let screen = owner.screen ?? NSScreen.main {
                    updateMinimumSize(on: screen)
                    let preferred = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1200, height: 820)).size
                    window.setFrame(PreviewWindowPlacement.initialFrame(
                        ownerFrame: owner.frame, preferredSize: preferred, visibleFrame: screen.visibleFrame
                    ), display: false)
                }
                window.delegate = self
                observeOwnerAndDisplays(owner)
            } else {
                hosting?.rootView = rootView(content)
            }
            contentID = content.id
            window?.title = "\(content.title) — 快速预览"
            if isNewContent { window?.makeKeyAndOrderFront(nil) }
        }

        private func rootView(_ content: QuickViewContent) -> AnyView {
            AnyView(QuickViewContentView(content: content) { [weak self] in
                self?.dismiss(clearSelection: true)
            }
            .id(content.id)
            .environment(\.appColorTheme, parent.colorTheme)
            .preferredColorScheme(parent.colorScheme)
            .tint(parent.colorTheme.tintColor))
        }

        private func observeOwnerAndDisplays(_ owner: NSWindow) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss(clearSelection: true) }
            })
            observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleFit() }
            })
        }

        private func currentScreen() -> NSScreen? {
            guard let window else { return nil }
            let screens = NSScreen.screens
            let fallback = screens.firstIndex { $0 === owner?.screen }
            guard let index = PreviewWindowPlacement.screenIndex(
                for: window.frame, visibleFrames: screens.map(\.visibleFrame), fallback: fallback
            ) else { return nil }
            return screens[index]
        }

        private func updateMinimumSize(on screen: NSScreen) {
            guard let window else { return }
            let availableContent = window.contentRect(forFrameRect: PreviewWindowPlacement.usableFrame(screen.visibleFrame)).size
            window.contentMinSize = NSSize(width: min(680, availableContent.width), height: min(460, availableContent.height))
        }

        private func scheduleFit() {
            fitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window else { return }
                // Never pull a window back while the user is dragging it between
                // displays or holding a resize edge. Fit once the gesture ends.
                guard !window.inLiveResize, NSEvent.pressedMouseButtons == 0 else {
                    self.scheduleFit()
                    return
                }
                guard let screen = self.currentScreen() else { return }
                self.updateMinimumSize(on: screen)
                let frame = PreviewWindowPlacement.constrainedFrame(window.frame, visibleFrame: screen.visibleFrame)
                if frame != window.frame { window.setFrame(frame, display: true) }
            }
            fitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func windowDidMove(_ notification: Notification) { scheduleFit() }
        func windowDidEndLiveResize(_ notification: Notification) { scheduleFit() }
        func windowDidChangeScreen(_ notification: Notification) { scheduleFit() }

        func windowWillClose(_ notification: Notification) {
            guard notification.object as? NSWindow === window else { return }
            dismiss(clearSelection: true, alreadyClosing: true)
        }

        func dismiss(clearSelection: Bool, alreadyClosing: Bool = false) {
            updateGeneration += 1
            fitWork?.cancel()
            fitWork = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            let window = self.window
            self.window = nil
            window?.delegate = nil
            if !alreadyClosing { window?.close() }
            // Release the hosting tree so FilePreviewView dismantles and closes QL.
            window?.contentViewController = nil
            hosting = nil
            owner = nil
            // Closing cancels the selection known now, including an update
            // queued behind the visible document. A later request stays intact.
            let oldID = parent.content?.id
            contentID = nil
            if clearSelection {
                let selection = parent.$content
                DispatchQueue.main.async {
                    if selection.wrappedValue?.id == oldID { selection.wrappedValue = nil }
                }
            }
        }
    }
}

final class PreviewWindowAnchorView: NSView {
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
