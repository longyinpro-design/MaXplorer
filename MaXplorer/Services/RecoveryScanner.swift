import Foundation

nonisolated struct RecoveryResidue: Identifiable, Equatable, Sendable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated enum RecoveryScanner {
    private static let prefixes = [
        ".maxplorer-transfer-",
        ".maxplorer-backup-",
        ".maxplorer-probe-"
    ]

    static func scan(in directories: [URL]) -> [RecoveryResidue] {
        var seen = Set<URL>()
        var residues: [RecoveryResidue] = []

        for directory in directories {
            guard directory.isFileURL else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                let standardized = entry.standardizedFileURL
                if seen.insert(standardized).inserted {
                    residues.append(RecoveryResidue(url: standardized))
                }
            }
        }

        return residues.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    static func remove(_ residue: RecoveryResidue) throws {
        try remove(at: residue.url)
    }

    static func remove(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true {
            try FileManager.default.removeItem(at: url)
            return
        }
        if values.isDirectory == true {
            try makeWritable(url)
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func makeWritable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o700
        try FileManager.default.setAttributes(
            [.posixPermissions: mode | 0o700],
            ofItemAtPath: url.path
        )

        for child in try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) {
            try makeWritable(child)
        }
    }
}
