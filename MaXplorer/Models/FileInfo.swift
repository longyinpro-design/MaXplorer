import Foundation

nonisolated struct FileInfo: Sendable, Equatable {
    let name: String
    let path: String
    let kind: String
    let size: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let owner: String?
    let group: String?
    let permissions: String?
    let tagNames: [String]
    let isDirectory: Bool
    let dateTaken: Date?

    init(
        name: String, path: String, kind: String, size: Int64?,
        createdAt: Date?, modifiedAt: Date?, owner: String?, group: String?,
        permissions: String?, tagNames: [String], isDirectory: Bool,
        dateTaken: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.owner = owner
        self.group = group
        self.permissions = permissions
        self.tagNames = tagNames
        self.isDirectory = isDirectory
        self.dateTaken = dateTaken
    }
}
