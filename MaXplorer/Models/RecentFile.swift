import Foundation

struct RecentFile: Identifiable, Codable, Equatable, Sendable {
    enum Availability: String, Codable, Sendable {
        case available
        case missing
        case unavailable
    }

    nonisolated var id: URL { url }
    let url: URL
    let name: String
    let lastOpened: Date
    var status: Availability

    nonisolated init(url: URL, lastOpened: Date, status: Availability = .unavailable) {
        self.url = url
        self.name = url.lastPathComponent
        self.lastOpened = lastOpened
        self.status = status
    }
}
