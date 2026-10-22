import Foundation
import SwiftUI

struct SidebarLocation: Identifiable, Hashable {
    enum Group: String {
        case favorites = "Favorites"
        case devices = "Devices"
        case network = "Network"

        var displayName: String {
            switch self {
            case .favorites: "收藏夹"
            case .devices: "设备"
            case .network: "网络"
            }
        }
    }

    var id: URL { url }

    let name: String
    let url: URL
    let group: Group
    let systemImage: String
    let canRemoveFromFavorites: Bool

    init(name: String, url: URL, group: Group, systemImage: String, canRemoveFromFavorites: Bool = false) {
        self.name = name
        self.url = url
        self.group = group
        self.systemImage = systemImage
        self.canRemoveFromFavorites = canRemoveFromFavorites
    }
}
