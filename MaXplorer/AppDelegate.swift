import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var transferQueue: CopyQueueViewModel?
    private var isWaitingForTransfers = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let transferQueue, transferQueue.hasActiveOperations else { return .terminateNow }
        if !isWaitingForTransfers {
            isWaitingForTransfers = true
            Task {
                await transferQueue.cancelAllAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIconFactory.makeIcon()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
