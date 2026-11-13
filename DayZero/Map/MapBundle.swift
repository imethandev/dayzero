import CoreLocation
import Foundation
import OSLog

/// The offline map the app shows. That's the area the user downloaded in the app
/// (`MapRegionStore`) when there is one, otherwise tiles bundled at build time by
/// `pipeline/build_offline_data.sh`. Styles, glyphs and sprites always come from
/// `Map.bundle`; styles reference them through a `{{BUNDLE}}` token, replaced here
/// with the bundle's on-device file URL.
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

    /// The bundled tiles file, if this build includes one.
    static var bundledTiles: URL? {
        guard let url, let name = bundledTilesName else { return nil }
        let file = url.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static var bundledTilesName: String? {
        guard let url, let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return names.first { $0.hasSuffix(".pmtiles") }
    }

    private static var region: RegionManifest? { MapRegionStore.shared.manifest }

    /// Bounds of the map in use.
    static var bounds: (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) {
        let b = region?.bounds ?? manifest?.bounds ?? [-180, -85, 180, 85]
        return (CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                CLLocationCoordinate2D(latitude: b[3], longitude: b[2]))
    }

    static func contains(_ c: CLLocationCoordinate2D) -> Bool {
        let (sw, ne) = bounds
        return (sw.latitude...ne.latitude).contains(c.latitude) && (sw.longitude...ne.longitude).contains(c.longitude)
    }

    static var hasTiles: Bool { region != nil || bundledTiles != nil }

    static var attribution: String {
        region?.attribution ?? manifest?.attribution ?? "© OpenMapTiles © OpenStreetMap contributors"
    }

    /// Human-readable date of the map data, for the About screen.
    static var dataDate: String? {
        if let region { return region.downloadedAt.formatted(date: .long, time: .omitted) }
        guard bundledTiles != nil, let ts = manifest?.osmTimestamp,
              let date = ISO8601DateFormatter().date(from: ts) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Writes the resolved style for a theme into Caches and returns its file URL.
    static func styleURL(_ theme: Theme) -> URL? {
        guard hasTiles, let bundleURL = url,
              let template = try? String(contentsOf: bundleURL.appendingPathComponent("style-\(theme.rawValue).json"), encoding: .utf8)
        else {
            log.error("Map.bundle or style-\(theme.rawValue, privacy: .public).json missing")
            return nil
        }
        // file:///…/DayZero.app/Map.bundle  (no trailing slash; the style adds "/…")
        let base = bundleURL.absoluteString.hasSuffix("/") ? String(bundleURL.absoluteString.dropLast()) : bundleURL.absoluteString
        let tilesURL: String
        if region != nil {
            // MapLibre reads MBTiles from an absolute path: mbtiles:///var/…/region.mbtiles
            tilesURL = "mbtiles://" + MapRegionStore.tilesURL.path
        } else if let name = bundledTilesName {
            tilesURL = "pmtiles://\(base)/\(name)"
        } else {
            return nil
        }
        guard let data = template.replacingOccurrences(of: "{{BUNDLE}}", with: base).data(using: .utf8),
              var style = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sources = style["sources"] as? [String: Any],
              var omt = sources["openmaptiles"] as? [String: Any]
        else {
            log.error("style-\(theme.rawValue, privacy: .public).json has no openmaptiles source")
            return nil
        }
        omt["url"] = tilesURL
        omt["attribution"] = attribution
        sources["openmaptiles"] = omt
        style["sources"] = sources
        guard let out = try? JSONSerialization.data(withJSONObject: style),
              let resolved = String(data: out, encoding: .utf8) else { return nil }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let file = caches.appendingPathComponent("style-\(theme.rawValue)-\(MapRegionStore.shared.revision)-resolved.json")
        do {
            try resolved.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            log.error("Could not write resolved style: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
