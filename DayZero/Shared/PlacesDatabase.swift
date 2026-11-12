import CoreLocation
import Foundation
import OSLog
import SQLite3
import SwiftUI

/// Kinds stored in places.sqlite (see pipeline/build_places_db.py).
enum PlaceKind: String, CaseIterable, Codable {
    case hospital, clinic, pharmacy, fire_station, police, fuel, drinking_water, shelter
    case city, town, village, hamlet

    var title: String {
        switch self {
        case .hospital: "Hospital"
        case .clinic: "Clinic"
        case .pharmacy: "Pharmacy"
        case .fire_station: "Fire station"
        case .police: "Police"
        case .fuel: "Fuel"
        case .drinking_water: "Drinking water"
        case .shelter: "Shelter"
        case .city: "City"
        case .town: "Town"
        case .village: "Village"
        case .hamlet: "Hamlet"
        }
    }

    var layer: FacilityLayer? {
        switch self {
        case .hospital, .clinic: .medical
        case .pharmacy: .pharmacies
        case .fire_station: .fire
        case .police: .police
        case .fuel: .fuel
        case .drinking_water: .water
        case .shelter: .shelters
        case .city, .town, .village, .hamlet: nil
        }
    }

    var symbol: String { layer?.symbol ?? "building.2.fill" }

    var contactCategory: ContactCategory {
        switch self {
        case .hospital, .clinic, .pharmacy: .medical
        case .fire_station: .fire
        case .police: .police
        case .shelter: .shelters
        default: .personal
        }
    }
}

/// The map's toggleable facility layers.
enum FacilityLayer: String, CaseIterable, Identifiable {
    case medical, fire, police, pharmacies, fuel, water, shelters
    var id: String { rawValue }

    var title: String {
        switch self {
        case .medical: "Hospitals & clinics"
        case .fire: "Fire stations"
        case .police: "Police"
        case .pharmacies: "Pharmacies"
        case .fuel: "Fuel"
        case .water: "Drinking water"
        case .shelters: "Shelters"
        }
    }

    var symbol: String {
        switch self {
        case .medical: "cross.fill"
        case .fire: "flame.fill"
        case .police: "shield.fill"
        case .pharmacies: "pills.fill"
        case .fuel: "fuelpump.fill"
        case .water: "drop.fill"
        case .shelters: "house.fill"
        }
    }

    var color: UIColor {
        switch self {
        case .medical: .systemRed
        case .fire: .systemOrange
        case .police: .systemBlue
        case .pharmacies: .systemGreen
        case .fuel: .systemBrown
        case .water: .systemCyan
        case .shelters: .systemPurple
        }
    }

    var kinds: [PlaceKind] { PlaceKind.allCases.filter { $0.layer == self } }
}

struct Place: Identifiable, Hashable {
    let id: Int64
    let name: String
    let kind: PlaceKind
    let latitude: Double
    let longitude: Double
    let address: String
    let phone: String
    let website: String

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Read-only access to the bundled places.sqlite (FTS5 search + nearest queries).
final class PlacesDatabase {
    static let shared = PlacesDatabase()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let log = Logger(subsystem: AppInfo.bundleID, category: "places")

    init(path: String? = MapBundle.url?.appendingPathComponent("places.sqlite").path) {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            log.error("places.sqlite missing from Map.bundle")
            return
        }
        // immutable=1: the file is read-only in the app bundle, so skip locking and journals.
        let uri = "file:\(path)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            log.error("Could not open places.sqlite")
            db = nil
        }
    }

    var isAvailable: Bool { db != nil }

    private static let columns = "p.id, p.name, p.kind, p.lat, p.lon, p.address, p.phone, p.website"

    /// Full-text search. Each word is matched as a prefix ("hosp" finds hospitals).
    /// Results are sorted by distance when a location is given, otherwise by relevance.
    func search(_ text: String, near location: CLLocationCoordinate2D?, limit: Int = 50) -> [Place] {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        let sql = """
            SELECT \(Self.columns) FROM places_fts f JOIN places p ON p.id = f.rowid
            WHERE places_fts MATCH ?1 ORDER BY bm25(places_fts, 10.0, 2.0, 1.0) LIMIT 400
            """
        var results = query(sql) { stmt in sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT) }
        if let location {
            let here = CLLocation(latitude: location.latitude, longitude: location.longitude)
            results.sort {
                here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < here.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }
        }
        return Array(results.prefix(limit))
    }

    /// Nearest places of the given kinds (equirectangular ordering, exact enough at state scale).
    func nearest(_ kinds: [PlaceKind], to c: CLLocationCoordinate2D, limit: Int) -> [Place] {
        guard !kinds.isEmpty else { return [] }
        let k = cos(c.latitude * .pi / 180)
        let placeholders = kinds.indices.map { "?\($0 + 4)" }.joined(separator: ",")
        let sql = """
            SELECT \(Self.columns) FROM places p WHERE p.kind IN (\(placeholders))
            ORDER BY (p.lat - ?1) * (p.lat - ?1) + ((p.lon - ?2) * ?3) * ((p.lon - ?2) * ?3)
            LIMIT \(limit)
            """
        return query(sql) { stmt in
            sqlite3_bind_double(stmt, 1, c.latitude)
            sqlite3_bind_double(stmt, 2, c.longitude)
            sqlite3_bind_double(stmt, 3, k)
            for (i, kind) in kinds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 4), kind.rawValue, -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Every facility (not settlements), for the map layers.
    func allFacilities() -> [Place] {
        let kinds = PlaceKind.allCases.filter { $0.layer != nil }.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return query("SELECT \(Self.columns) FROM places p WHERE p.kind IN (\(kinds))") { _ in }
    }

    func place(id: Int64) -> Place? {
        query("SELECT \(Self.columns) FROM places p WHERE p.id = ?1") { sqlite3_bind_int64($0, 1, id) }.first
    }

    // MARK: - SQLite plumbing

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) -> [Place] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("SQL prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Place] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = PlaceKind(rawValue: text(stmt, 2)) else { continue }
            out.append(Place(
                id: sqlite3_column_int64(stmt, 0),
                name: text(stmt, 1),
                kind: kind,
                latitude: sqlite3_column_double(stmt, 3),
                longitude: sqlite3_column_double(stmt, 4),
                address: text(stmt, 5),
                phone: text(stmt, 6),
                website: text(stmt, 7)
            ))
        }
        return out
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
