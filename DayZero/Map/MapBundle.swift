import CoreLocation
import Foundation
import OSLog

/// The read-only offline map data shipped in `Map.bundle`, produced by
/// `pipeline/build_offline_data.sh`. Styles reference bundled files through a
/// `{{BUNDLE}}` token, replaced here with the bundle's on-device file URL.
enum MapBundle {
    enum Theme: String { case light, dark }

    struct Manifest: Decodable {
        let osmTimestamp: String?
        let builtAt: String?
        let bounds: [Double] // west, south, east, north
        let attribution: String
        let places: [String: Int]?
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "map")

    static let url: URL? = Bundle.main.url(forResource: "Map", withExtension: "bundle")

    static let manifest: Manifest? = {
        guard let url = url?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    /// Bounds of the bundled tiles. Falls back to Washington's extent.
    static var bounds: (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) {
        let b = manifest?.bounds ?? [-124.85, 45.54, -116.91, 49.01]
        return (CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                CLLocationCoordinate2D(latitude: b[3], longitude: b[2]))
    }

    static func contains(_ c: CLLocationCoordinate2D) -> Bool {
        let (sw, ne) = bounds
        return (sw.latitude...ne.latitude).contains(c.latitude) && (sw.longitude...ne.longitude).contains(c.longitude)
    }

    static var hasTiles: Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("washington.pmtiles").path)
    }

    /// Human-readable date of the OSM extract, for the About screen.
    static var dataDate: String? {
        guard let ts = manifest?.osmTimestamp,
              let date = ISO8601DateFormatter().date(from: ts) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Writes the resolved style for a theme into Caches and returns its file URL.
    static func styleURL(_ theme: Theme) -> URL? {
        guard let bundleURL = url,
              let template = try? String(contentsOf: bundleURL.appendingPathComponent("style-\(theme.rawValue).json"), encoding: .utf8)
        else {
            log.error("Map.bundle or style-\(theme.rawValue, privacy: .public).json missing")
            return nil
        }
        // file:///…/DayZero.app/Map.bundle  (no trailing slash; the style adds "/…")
        let base = bundleURL.absoluteString.hasSuffix("/") ? String(bundleURL.absoluteString.dropLast()) : bundleURL.absoluteString
        let resolved = template.replacingOccurrences(of: "{{BUNDLE}}", with: base)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let out = caches.appendingPathComponent("style-\(theme.rawValue)-resolved.json")
        do {
            try resolved.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            log.error("Could not write resolved style: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
