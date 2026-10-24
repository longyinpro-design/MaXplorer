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
}
