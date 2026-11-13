import Foundation
import ObjectiveC
import OSLog

/// Debug-only guard for the app's one rule: no network in normal use.
///
/// Compiled in when the `BLOCK_NETWORK` Swift condition is set (Debug builds,
/// via the `DAYZERO_BLOCK_NETWORK` build setting). It registers a URLProtocol
/// that logs and fails every http(s)/ws(s) request, for `URLSession.shared` and
/// for any session built from `.default` or `.ephemeral` configurations, so a
/// stray remote URL (a style file, a font, an SDK) is caught during testing.
enum NetworkBlocker {
    struct BlockedRequest: Identifiable, Hashable {
        let id = UUID()
        let url: String
        let date: Date
    }

    static let didBlock = Notification.Name("NetworkBlocker.didBlock")

    #if BLOCK_NETWORK
    static let isActive = true
    #else
    static let isActive = false
    #endif

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _blocked: [BlockedRequest] = []
    nonisolated(unsafe) private static var installed = false

    static var blocked: [BlockedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _blocked
    }

    static func install() {
        #if BLOCK_NETWORK
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(BlockingURLProtocol.self)
        swizzleClassGetter(#selector(getter: URLSessionConfiguration.default),
                           with: #selector(URLSessionConfiguration.dz_blockedDefault))
        swizzleClassGetter(#selector(getter: URLSessionConfiguration.ephemeral),
                           with: #selector(URLSessionConfiguration.dz_blockedEphemeral))
        Logger.network.notice("Network blocker installed: all outgoing requests will be logged and failed")
        #endif
    }

    /// A session for the actions the user starts on purpose (downloading a map of their area).
    /// It skips the debug blocker; everything else in the app stays blocked.
    static func userInitiatedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != BlockingURLProtocol.self }
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        Logger.network.notice("User-initiated network session created (map download)")
        return URLSession(configuration: config)
    }

    fileprivate static func record(_ url: URL?) {
        let entry = BlockedRequest(url: url?.absoluteString ?? "<nil>", date: .now)
        lock.lock()
        _blocked.append(entry)
        lock.unlock()
        Logger.network.error("BLOCKED outgoing request: \(entry.url, privacy: .public)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didBlock, object: nil)
        }
    }

    private static func swizzleClassGetter(_ original: Selector, with replacement: Selector) {
        let cls: AnyClass = URLSessionConfiguration.self
        guard let a = class_getClassMethod(cls, original),
              let b = class_getClassMethod(cls, replacement) else {
            Logger.network.fault("Network blocker could not swizzle \(NSStringFromSelector(original), privacy: .public)")
            return
        }
        method_exchangeImplementations(a, b)
    }
}

extension Logger {
    static let network = Logger(subsystem: AppInfo.bundleID, category: "network")
}

final class BlockingURLProtocol: URLProtocol {
    private static let blockedSchemes: Set<String> = ["http", "https", "ws", "wss"]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return blockedSchemes.contains(scheme)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        NetworkBlocker.record(request.url)
        let error = URLError(.notConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "Blocked by DayZero's offline guard (debug build)",
            NSURLErrorFailingURLErrorKey: request.url as Any,
        ])
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    // After swizzling, calling these names invokes the ORIGINAL getters.
    @objc class func dz_blockedDefault() -> URLSessionConfiguration {
        let config = dz_blockedDefault()
        config.protocolClasses = [BlockingURLProtocol.self] + (config.protocolClasses ?? [])
        return config
    }

    @objc class func dz_blockedEphemeral() -> URLSessionConfiguration {
        let config = dz_blockedEphemeral()
        config.protocolClasses = [BlockingURLProtocol.self] + (config.protocolClasses ?? [])
        return config
    }
}
