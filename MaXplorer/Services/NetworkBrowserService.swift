import Foundation

struct NetworkLocation: Sendable {
    let name: String
    let url: URL
    let kind: String
}

@MainActor
final class NetworkBrowserService: NSObject {
    private var browsers: [NetServiceBrowser] = []
    private var discoveredServices: [NetService] = []
    private var continuation: CheckedContinuation<[NetworkLocation], Never>?

    func browse(timeout: Duration = .seconds(2)) async -> [NetworkLocation] {
        await withCheckedContinuation { continuation in
            if self.continuation != nil {
                finish()
            }

            self.continuation = continuation
            discoveredServices = []

            browsers = ["_smb._tcp.", "_afpovertcp._tcp."].map { serviceType in
                let browser = NetServiceBrowser()
                browser.delegate = self
                browser.searchForServices(ofType: serviceType, inDomain: "local.")
                return browser
            }

            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    private func finish() {
        for browser in browsers {
            browser.stop()
            browser.delegate = nil
        }
        browsers = []

        let locations = discoveredServices.compactMap(Self.location(for:))
        discoveredServices = []
        continuation?.resume(returning: locations)
        continuation = nil
    }

    private static func location(for service: NetService) -> NetworkLocation? {
        guard let host = service.hostName else {
            return nil
        }

        let scheme = service.type == "_afpovertcp._tcp." ? "afp" : "smb"
        guard let url = URL(string: "\(scheme)://\(host)") else {
            return nil
        }

        let kind = service.type == "_afpovertcp._tcp." ? "AFP 服务器" : "SMB 服务器"
        return NetworkLocation(name: service.name, url: url, kind: kind)
    }
}

extension NetworkBrowserService: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        discoveredServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 1)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }
}

extension NetworkBrowserService: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {}
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
}
