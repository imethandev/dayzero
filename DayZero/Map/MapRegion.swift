import CoreLocation
import Foundation
import Observation
import OSLog
import SQLite3

/// A map area the user downloaded in the app: vector tiles in an MBTiles file plus a
/// places database, stored in Application Support. It replaces the bundled map when present.
struct RegionManifest: Codable, Equatable {
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusKm: Double
    /// west, south, east, north of the full-detail (zoom 14) area.
    var bounds: [Double]
    var downloadedAt: Date
    var tileCount: Int
    var bytes: Int
    var placeCount: Int
    var attribution: String
    /// True when the download stopped at the 50 MB limit before covering the whole area.
    var stoppedAtLimit: Bool? = nil
    /// ISO 3166 country code of the area's center ("US"), for emergency numbers.
    var countryCode: String? = nil
}

/// Where the downloaded map lives, and which map the app should use.
@Observable
final class MapRegionStore {
    static let shared = MapRegionStore()

    /// Bumped whenever the downloaded map changes, so the map view rebuilds.
    private(set) var revision = 0
    private(set) var manifest: RegionManifest?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Map", isDirectory: true)
    }()
    static var tilesURL: URL { directory.appendingPathComponent("region.mbtiles") }
    static var placesURL: URL { directory.appendingPathComponent("places.sqlite") }
    static var manifestURL: URL { directory.appendingPathComponent("region.json") }

    private init() {
        manifest = Self.readManifest()
    }

    var hasRegion: Bool { manifest != nil }

    private static func readManifest() -> RegionManifest? {
        guard FileManager.default.fileExists(atPath: tilesURL.path),
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RegionManifest.self, from: data)
    }

    /// Moves a finished download into place, replacing any earlier one.
    func install(tiles: URL, places: URL?, manifest: RegionManifest) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        PlacesDatabase.closeShared()
        for url in [Self.tilesURL, Self.placesURL, Self.manifestURL] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tiles, to: Self.tilesURL)
        if let places { try fm.moveItem(at: places, to: Self.placesURL) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: Self.manifestURL, options: .atomic)
        // Keep the map out of iCloud and iTunes backups; it can be downloaded again.
        var dir = Self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        changed()
    }

    func delete() {
        PlacesDatabase.closeShared()
        try? FileManager.default.removeItem(at: Self.directory)
        changed()
    }

    private func changed() {
        manifest = Self.readManifest()
        PlacesDatabase.reloadShared()
        RegionModel.shared.refresh()
        revision += 1
    }
}

// MARK: Tile math

struct TileID: Hashable, Sendable {
    let z: Int, x: Int, y: Int
}

enum TileMath {
    static let maxZoom = 14

    static func tile(_ c: CLLocationCoordinate2D, z: Int) -> (x: Int, y: Int) {
        let n = Double(1 << z)
        let lat = min(max(c.latitude, -85.0511), 85.0511) * .pi / 180
        let x = Int(((c.longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - asinh(tan(lat)) / .pi) / 2 * n).rounded(.down))
        let maxIndex = (1 << z) - 1
        return (min(max(x, 0), maxIndex), min(max(y, 0), maxIndex))
    }

    /// Longitude/latitude of a tile's north-west corner.
    static func corner(x: Int, y: Int, z: Int) -> CLLocationCoordinate2D {
        let n = Double(1 << z)
        let lon = Double(x) / n * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// west, south, east, north of a square-ish box around a point.
    static func box(center c: CLLocationCoordinate2D, radiusKm r: Double) -> [Double] {
        let dLat = r / 111.32
        let dLon = r / (111.32 * max(cos(c.latitude * .pi / 180), 0.05))
        return [c.longitude - dLon, max(c.latitude - dLat, -85), c.longitude + dLon, min(c.latitude + dLat, 85)]
    }

    /// Every tile from zoom 0 to 14 covering the box, lowest zoom first, and within
    /// each zoom nearest the center first, so a download that stops early keeps the middle.
    static func tiles(center c: CLLocationCoordinate2D, radiusKm r: Double) -> [TileID] {
        let b = box(center: c, radiusKm: r)
        var out: [TileID] = []
        for z in 0...maxZoom {
            let nw = tile(CLLocationCoordinate2D(latitude: b[3], longitude: b[0]), z: z)
            let se = tile(CLLocationCoordinate2D(latitude: b[1], longitude: b[2]), z: z)
            let mid = tile(c, z: z)
            var level: [TileID] = []
            for x in nw.x...se.x { for y in nw.y...se.y { level.append(TileID(z: z, x: x, y: y)) } }
            level.sort { a, b in
                let da = (a.x - mid.x) * (a.x - mid.x) + (a.y - mid.y) * (a.y - mid.y)
                let db = (b.x - mid.x) * (b.x - mid.x) + (b.y - mid.y) * (b.y - mid.y)
                return da < db
            }
            out += level
        }
        return out
    }

    /// Bounds actually covered by a set of zoom-14 tiles.
    static func bounds(of tiles: [TileID]) -> [Double]? {
        let deep = tiles.filter { $0.z == maxZoom }
        guard let minX = deep.map(\.x).min(), let maxX = deep.map(\.x).max(),
              let minY = deep.map(\.y).min(), let maxY = deep.map(\.y).max() else { return nil }
        let nw = corner(x: minX, y: minY, z: maxZoom)
        let se = corner(x: maxX + 1, y: maxY + 1, z: maxZoom)
        return [nw.longitude, se.latitude, se.longitude, nw.latitude]
    }
}

// MARK: Download

/// Downloads a map of the area around the user. This is one of DayZero's two network
/// actions, and it only runs when the user taps Download.
///
/// Tiles come from OpenFreeMap (OpenMapTiles schema, so the bundled styles work unchanged),
/// within its offline rules: at most 3,000 tiles or 50 MB per download, at most 4 parallel
/// requests, and a User-Agent naming the app. Facilities and place names for search come from
/// one OpenStreetMap Overpass query.
@Observable
final class MapDownloader {
    enum Phase: Equatable {
        case idle
        case tiles(done: Int, total: Int, bytes: Int)
        case places
        case finished(RegionManifest)
        case failed(String)
    }

    static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
    static let overpassURL = URL(string: "https://overpass-api.de/api/interpreter")!
    static let maxTiles = 3_000
    static let maxBytes = 50 * 1_000_000
    static let parallelRequests = 4
    static let radiusOptions: [Double] = [5, 10, 20, 30]
    static let attribution = "© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors"

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "map-download")

    var isRunning: Bool {
        switch phase {
        case .tiles, .places: true
        default: false
        }
    }

    static var userAgent: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "DayZero/\(v) (open-source emergency prep app; https://github.com/imethandev/dayzero)"
    }

    /// Radii whose tile count fits the per-download limit at this latitude.
    static func allowedRadii(at c: CLLocationCoordinate2D) -> [Double] {
        radiusOptions.filter { TileMath.tiles(center: c, radiusKm: $0).count <= maxTiles }
    }

    func start(center: CLLocationCoordinate2D, radiusKm: Double) {
        guard !isRunning else { return }
        let tiles = Array(TileMath.tiles(center: center, radiusKm: radiusKm).prefix(Self.maxTiles))
        phase = .tiles(done: 0, total: tiles.count, bytes: 0)
        task = Task { [weak self] in
            await self?.run(center: center, radiusKm: radiusKm, tiles: tiles)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func reset() { if !isRunning { phase = .idle } }

    private func run(center: CLLocationCoordinate2D, radiusKm: Double, tiles: [TileID]) async {
        let session = NetworkBlocker.userInitiatedSession()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("map-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 1. Where the tiles are, and their layer list.
            let (tjData, tjResponse) = try await session.data(for: request(Self.tileJSONURL))
            try check(tjResponse)
            let tileJSON = try JSONSerialization.jsonObject(with: tjData) as? [String: Any] ?? [:]
            guard let template = (tileJSON["tiles"] as? [String])?.first else {
                throw DownloadError.message("The map server didn't say where its tiles are.")
            }

            // 2. Tiles, 4 at a time, written into MBTiles as they arrive.
            let tilesFile = work.appendingPathComponent("region.mbtiles")
            let writer = try MBTilesWriter(url: tilesFile)
            var done = 0, bytes = 0
            var saved: [TileID] = []
            var capped = false
            try await withThrowingTaskGroup(of: (TileID, Data?).self) { group in
                var next = tiles.makeIterator()
                func add(_ t: TileID) {
                    let url = URL(string: template
                        .replacingOccurrences(of: "{z}", with: "\(t.z)")
                        .replacingOccurrences(of: "{x}", with: "\(t.x)")
                        .replacingOccurrences(of: "{y}", with: "\(t.y)"))!
                    let req = request(url)
                    group.addTask {
                        let (data, response) = try await session.data(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 204 || status == 404 { return (t, nil) } // empty sea or land tile
                        guard (200..<300).contains(status) else { throw DownloadError.message("The map server answered \(status).") }
                        return (t, data)
                    }
                }
                for _ in 0..<Self.parallelRequests { if let t = next.next() { add(t) } }
                while let (t, data) = try await group.next() {
                    try Task.checkCancellation()
                    if let data, !data.isEmpty {
                        // Stored gzipped (standard for MBTiles); the compressed size is also
                        // close to what came over the network, which is what the 50 MB cap means.
                        let packed = Gzip.compress(data) ?? data
                        try writer.put(t, packed)
                        bytes += packed.count
                        saved.append(t)
                    }
                    done += 1
                    let progress = Phase.tiles(done: done, total: tiles.count, bytes: bytes)
                    await MainActor.run { self.phase = progress }
                    if bytes >= Self.maxBytes {
                        log.notice("Stopped at the 50 MB download limit after \(done) tiles")
                        capped = true
                        group.cancelAll()
                        break
                    }
                    if let t = next.next() { add(t) }
                }
            }
            let bounds = TileMath.bounds(of: saved) ?? TileMath.box(center: center, radiusKm: radiusKm)
            try writer.finish(metadata: [
                "name": "DayZero area",
                "format": "pbf",
                "type": "baselayer",
                "minzoom": "0",
                "maxzoom": "\(TileMath.maxZoom)",
                "bounds": bounds.map { String(format: "%.6f", $0) }.joined(separator: ","),
                "center": String(format: "%.6f,%.6f,%d", center.longitude, center.latitude, 12),
                "attribution": Self.attribution,
                "json": vectorLayersJSON(tileJSON),
            ])

            // 3. Facilities and place names for search. The map still works if this fails.
            await MainActor.run { self.phase = .places }
            try Task.checkCancellation()
            let placesFile = work.appendingPathComponent("places.sqlite")
            var placeCount = 0
            do {
                placeCount = try await downloadPlaces(bounds: bounds, session: session, to: placesFile)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Places download failed: \(error.localizedDescription, privacy: .public)")
            }

            let places = placeCount
            let country = try? await detectCountry(center, session: session)
            // If the size limit cut the download short, report the area actually covered.
            let widthKm = (bounds[2] - bounds[0]) * 111.32 * cos(center.latitude * .pi / 180)
            let heightKm = (bounds[3] - bounds[1]) * 111.32
            let covered = capped ? min(radiusKm, (min(widthKm, heightKm) / 2 * 10).rounded() / 10) : radiusKm
            let manifest = RegionManifest(
                centerLatitude: center.latitude, centerLongitude: center.longitude, radiusKm: covered,
                bounds: bounds, downloadedAt: .now, tileCount: saved.count, bytes: bytes,
                placeCount: places, attribution: Self.attribution, stoppedAtLimit: capped, countryCode: country)
            try await MainActor.run {
                try MapRegionStore.shared.install(
                    tiles: tilesFile,
                    places: places > 0 ? placesFile : nil,
                    manifest: manifest)
                self.phase = .finished(manifest)
            }
        } catch is CancellationError {
            await MainActor.run { self.phase = .idle }
        } catch {
            let message = (error as? DownloadError)?.text ?? error.localizedDescription
            log.error("Map download failed: \(message, privacy: .public)")
            await MainActor.run { self.phase = .failed(message) }
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    private func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError.message("The map server answered \(status).") }
    }

    private func vectorLayersJSON(_ tileJSON: [String: Any]) -> String {
        let layers = tileJSON["vector_layers"] ?? []
        guard let data = try? JSONSerialization.data(withJSONObject: ["vector_layers": layers]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The country the area's center is in, from OpenStreetMap's country boundary.
    private func detectCountry(_ c: CLLocationCoordinate2D, session: URLSession) async throws -> String? {
        let query = String(format: """
            [out:json][timeout:25];
            is_in(%.5f,%.5f)->.a;
            area.a["boundary"="administrative"]["admin_level"="2"];
            out tags;
            """, c.latitude, c.longitude)
        var req = request(Self.overpassURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        try check(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tags = (json?["elements"] as? [[String: Any]])?.compactMap { $0["tags"] as? [String: String] } ?? []
        return tags.lazy.compactMap { $0["ISO3166-1:alpha2"] ?? $0["ISO3166-1"] }.first { $0.count == 2 }
    }

    private func downloadPlaces(bounds b: [Double], session: URLSession, to file: URL) async throws -> Int {
        let bbox = String(format: "%.5f,%.5f,%.5f,%.5f", b[1], b[0], b[3], b[2]) // south,west,north,east
        let query = """
        [out:json][timeout:90];
        (
          nwr["amenity"~"^(hospital|clinic|doctors|pharmacy|fire_station|police|fuel|drinking_water|water_point|shelter)$"](\(bbox));
          nwr["man_made"="water_tap"](\(bbox));
          nwr["natural"="spring"](\(bbox));
          nwr["man_made"="water_well"]["pump"="manual"](\(bbox));
          nwr["healthcare"~"^(hospital|clinic)$"](\(bbox));
          nwr["emergency"~"^(drinking_water|assembly_point)$"](\(bbox));
          nwr["social_facility"="shelter"](\(bbox));
          node["place"~"^(city|town|village|hamlet)$"](\(bbox));
        );
        out center tags;
        """
        var req = request(Self.overpassURL)
        req.timeoutInterval = 120
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        try check(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let elements = json?["elements"] as? [[String: Any]] ?? []
        return try PlacesWriter.write(elements: elements, to: file)
    }

    private enum DownloadError: Error {
        case message(String)
        var text: String { if case .message(let m) = self { m } else { "" } }
    }
}

// MARK: Writers

/// Minimal MBTiles 1.3 writer (TMS row order, as the spec requires).
final class MBTilesWriter {
    private var db: OpaquePointer?
    private var insert: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try exec("""
            PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
            CREATE TABLE metadata (name TEXT, value TEXT);
            CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
            CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
            BEGIN;
            """)
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", -1, &insert, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit {
        sqlite3_finalize(insert)
        sqlite3_close(db)
    }

    func put(_ t: TileID, _ data: Data) throws {
        sqlite3_reset(insert)
        sqlite3_bind_int(insert, 1, Int32(t.z))
        sqlite3_bind_int(insert, 2, Int32(t.x))
        sqlite3_bind_int(insert, 3, Int32((1 << t.z) - 1 - t.y))
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(insert, 4, raw.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(insert) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    func finish(metadata: [String: String]) throws {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO metadata VALUES (?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        for (k, v) in metadata {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, k, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
        try exec("COMMIT;")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Builds places.sqlite from Overpass results, with the same schema as pipeline/build_places_db.py.
enum PlacesWriter {
    /// Same rules as the pipeline; the first match decides the kind.
    static func kind(of t: [String: String]) -> PlaceKind? {
        let a = t["amenity"]
        if a == "hospital" || t["healthcare"] == "hospital" { return .hospital }
        if a == "clinic" || a == "doctors" || t["healthcare"] == "clinic" { return .clinic }
        if a == "pharmacy" { return .pharmacy }
        if a == "fire_station" { return .fire_station }
        if a == "police" { return .police }
        if a == "fuel" { return .fuel }
        if a == "drinking_water" || t["emergency"] == "drinking_water" || t["man_made"] == "water_tap" { return .drinking_water }
        if a == "water_point" { return .water_point }
        if t["natural"] == "spring" { return .spring }
        if t["man_made"] == "water_well", t["pump"] == "manual" { return .well }
        if a == "shelter" || t["social_facility"] == "shelter" || t["emergency"] == "assembly_point" {
            let notEmergency: Set<String> = ["picnic_shelter", "public_transport", "weather_shelter", "lean_to", "basic_hut", "field_shelter"]
            if a == "shelter", let type = t["shelter_type"], notEmergency.contains(type) { return nil }
            return .shelter
        }
        if let p = t["place"], let k = PlaceKind(rawValue: p), [.city, .town, .village, .hamlet].contains(k) { return k }
        return nil
    }

    static func address(_ t: [String: String]) -> String {
        let street = [t["addr:housenumber"], t["addr:street"]].compactMap { $0 }.joined(separator: " ")
        let region = [t["addr:state"], t["addr:postcode"]].compactMap { $0 }.joined(separator: " ")
        return [street, t["addr:city"] ?? "", region].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @discardableResult
    static func write(elements: [[String: Any]], to url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE places (
                id INTEGER PRIMARY KEY, osm_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
                lat REAL NOT NULL, lon REAL NOT NULL, address TEXT NOT NULL DEFAULT '',
                phone TEXT NOT NULL DEFAULT '', website TEXT NOT NULL DEFAULT '', population INTEGER);
            CREATE INDEX places_kind ON places(kind);
            CREATE VIRTUAL TABLE places_fts USING fts5(name, kind, address, content='places', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2');
            BEGIN;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO places(osm_id,name,kind,lat,lon,address,phone,website,population) VALUES (?,?,?,?,?,?,?,?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var seen = Set<String>()
        var rows = 0
        for e in elements {
            let tags = e["tags"] as? [String: String] ?? [:]
            guard let kind = kind(of: tags) else { continue }
            var name = tags["name"] ?? tags["official_name"]
            if name == nil {
                switch kind {
                case .drinking_water: name = "Drinking water"
                case .water_point: name = "Water refill point"
                case .spring: name = "Spring"
                case .well: name = "Hand-pump well"
                case .fuel: name = tags["brand"] ?? "Fuel"
                default: continue
                }
            }
            if kind.layer == .water, tags["drinking_water"] == "no" { name! += Place.notDrinkableSuffix }
            let type = (e["type"] as? String)?.prefix(1) ?? "?"
            let osmID = "\(type)\(e["id"] as? Int ?? 0)"
            guard seen.insert(osmID).inserted else { continue }
            let center = e["center"] as? [String: Double]
            guard let lat = (e["lat"] as? Double) ?? center?["lat"],
                  let lon = (e["lon"] as? Double) ?? center?["lon"] else { continue }
            let population = tags["population"].flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }

            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, osmID, -1, transient)
            sqlite3_bind_text(stmt, 2, name!, -1, transient)
            sqlite3_bind_text(stmt, 3, kind.rawValue, -1, transient)
            sqlite3_bind_double(stmt, 4, (lat * 1e6).rounded() / 1e6)
            sqlite3_bind_double(stmt, 5, (lon * 1e6).rounded() / 1e6)
            sqlite3_bind_text(stmt, 6, address(tags), -1, transient)
            sqlite3_bind_text(stmt, 7, tags["phone"] ?? tags["contact:phone"] ?? "", -1, transient)
            sqlite3_bind_text(stmt, 8, tags["website"] ?? tags["contact:website"] ?? "", -1, transient)
            if let population { sqlite3_bind_int64(stmt, 9, Int64(population)) } else { sqlite3_bind_null(stmt, 9) }
            if sqlite3_step(stmt) == SQLITE_DONE { rows += 1 }
        }
        sqlite3_exec(db, "COMMIT; INSERT INTO places_fts(places_fts) VALUES ('rebuild');", nil, nil, nil)
        return rows
    }
}

// MARK: Gzip

/// Gzip (RFC 1952) built on Foundation's raw DEFLATE, for storing tiles compressed.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }
}
