import AppKit
import Combine
import Foundation

struct MountedVolume: Identifiable, Equatable, Sendable {
    var id: URL { url }

    let url: URL
    let name: String
    let isLocal: Bool
    let modifiedAt: Date?
}

/// Caches mounted-volume metadata so sidebar and status rendering never runs a
/// synchronous volume query. Mount, unmount, and rename notifications trigger a
/// coalesced off-main refresh. The root volume stays in the list for sidebar and
/// network filtering, but path matching ignores it so a just-mounted volume that
/// has not reached the catalog yet falls back to a live query instead of being
/// mistaken for local storage.
@MainActor
final class VolumeCatalog: ObservableObject {
    static let shared = VolumeCatalog()

    @Published private(set) var mountedVolumes: [MountedVolume] = []

    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshTask: Task<Void, Never>?

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        for name in names {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
        }

        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let volumes = await Task.detached(priority: .utility) {
                Self.loadMountedVolumes()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.mountedVolumes = volumes
        }
    }

    /// Which volume backs `url`, or nil when the catalog has no matching mount
    /// (for example before the first asynchronous refresh completes).
    func isLocalVolume(containing url: URL) -> Bool? {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        var matched: MountedVolume?

        for volume in mountedVolumes where volume.url.path != "/" {
            let root = volume.url.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path == root || path.hasPrefix(prefix) else { continue }
            let matchedLength = matched?.url.standardizedFileURL.path.count ?? 0
            if root.count > matchedLength {
                matched = volume
            }
        }

        return matched?.isLocal
    }

    /// A burst of notifications arrives around a single mount or unmount.
    private func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else {
                return
            }
            self?.refresh()
        }
    }

    private nonisolated static func loadMountedVolumes() -> [MountedVolume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeIsLocalKey,
                .volumeNameKey,
                .contentModificationDateKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [
                .volumeIsLocalKey,
                .volumeNameKey,
                .contentModificationDateKey
            ])
            return MountedVolume(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isLocal: values?.volumeIsLocal ?? true,
                modifiedAt: values?.contentModificationDate
            )
        }
    }
}
