import OSLog
import SwiftUI
import WebKit

/// "Save for offline": the only network use in DayZero, and only when the user taps it.
/// Pages are stored as Safari web archives under Application Support/SavedPages.
enum SavedPages {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "savedPages")

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SavedPages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.complete])
        }
        return dir
    }

    static func fileURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).webarchive") }

    static func savedDate(for id: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL(for: id).path))?[.modificationDate] as? Date
    }

    static func delete(for id: UUID) { try? FileManager.default.removeItem(at: fileURL(for: id)) }

    @MainActor
    static func save(_ url: URL, for id: UUID) async throws {
        let data = try await PageArchiver().archive(url)
        try data.write(to: fileURL(for: id), options: [.atomic, .completeFileProtection])
        log.info("Saved offline copy of \(url.absoluteString, privacy: .public) (\(data.count) bytes)")
    }
}

/// Loads a page in an off-screen web view and captures it as a web archive.
@MainActor
private final class PageArchiver: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    func archive(_ url: URL) async throws -> Data {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.navigationDelegate = self
        webView = web
        defer { webView = nil }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in
                    self.continuation = cont
                    web.load(URLRequest(url: url, timeoutInterval: 30))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(40))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
        // Give late images and styles a moment before capturing.
        try await Task.sleep(for: .seconds(1.5))
        return try await web.webArchiveData()
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

private extension WKWebView {
    func webArchiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            createWebArchiveData { cont.resume(with: $0) }
        }
    }
}

/// Shows a saved copy with JavaScript off, so the archived page can't start new requests by script.
struct SavedPageView: View {
    let id: UUID
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = try? Data(contentsOf: SavedPages.fileURL(for: id)) {
                    ArchiveWebView(data: data)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("No saved copy", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                 baseURL: URL(string: "about:blank")!)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
