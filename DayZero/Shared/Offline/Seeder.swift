import Foundation
import OSLog
import SwiftData

/// Loads the bundled supply catalog and emergency contacts into SwiftData.
/// Seeding is keyed per item, so it is safe to run on every launch: existing
/// rows (including ones the user edited or hid) are never touched, and items
/// added to a later catalog version are inserted with quantity 0.
@MainActor
enum Seeder {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "seed")

    struct CatalogFile: Decodable {
        let version: Int
        let items: [CatalogItem]
    }

    struct CatalogItem: Decodable {
        let key: String
        let name: String
        let kind: SupplyKind
        let unit: String
        let caloriesPerUnit: Double?
        let gallonsPerUnit: Double?
        let group: ToolGroup?
        let foodGroup: FoodGroup?
    }

    struct ContactsFile: Decodable {
        let version: Int
        let contacts: [ContactSeed]
    }

    struct ContactSeed: Decodable {
        let key: String
        let name: String
        let category: ContactCategory
        let phone: String?
        let address: String?
        let latitude: Double?
        let longitude: Double?
        let website: String?
        let notes: String?
    }

    static func seedIfNeeded(_ context: ModelContext) {
        do {
            try seedCatalog(context)
            try seedContacts(context)
            if context.hasChanges { try context.save() }
        } catch {
            log.error("Seeding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func seedCatalog(_ context: ModelContext) throws {
        let file: CatalogFile = try loadJSON("supply_catalog")
        let existing = try context.fetch(FetchDescriptor<SupplyItem>())
        let byKey = Dictionary(existing.compactMap { i in i.catalogKey.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        var inserted = 0
        for (index, item) in file.items.enumerated() {
            if let current = byKey[item.key] {
                // Catalog-owned fields (read-only in the app for built-ins): name, unit, nutrition,
                // list position and page. Quantities, expiry, location and notes stay the user's.
                if current.sortOrder != index { current.sortOrder = index }
                if current.name != item.name { current.name = item.name }
                if current.unit != item.unit { current.unit = item.unit }
                if current.caloriesPerUnit != (item.caloriesPerUnit ?? 0) { current.caloriesPerUnit = item.caloriesPerUnit ?? 0 }
                if current.gallonsPerUnit != (item.gallonsPerUnit ?? 0) { current.gallonsPerUnit = item.gallonsPerUnit ?? 0 }
                if let g = item.group, current.toolGroupRaw != g.rawValue { current.toolGroupRaw = g.rawValue }
                if let g = item.foodGroup, current.foodGroupRaw != g.rawValue { current.foodGroupRaw = g.rawValue }
                continue
            }
            let new = SupplyItem(
                name: item.name,
                kind: item.kind,
                quantity: 0,
                unit: item.unit,
                caloriesPerUnit: item.caloriesPerUnit ?? 0,
                gallonsPerUnit: item.gallonsPerUnit ?? 0,
                isBuiltIn: true,
                sortOrder: index,
                catalogKey: item.key
            )
            new.toolGroupRaw = item.group?.rawValue
            new.foodGroupRaw = item.foodGroup?.rawValue
            context.insert(new)
            inserted += 1
        }
        if inserted > 0 { log.info("Seeded \(inserted) catalog items (catalog v\(file.version))") }
    }

    static func seedContacts(_ context: ModelContext) throws {
        let file: ContactsFile = try loadJSON("emergency_contacts")
        let existing = try context.fetch(FetchDescriptor<EmergencyContact>())
        let byKey = Dictionary(existing.compactMap { c in c.seedKey.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        var inserted = 0
        var refreshed = 0
        for seed in file.contacts {
            if let current = byKey[seed.key] {
                // Refresh built-ins from a newer seed file, unless the user has edited them.
                guard current.isBuiltIn, !current.userEdited else { continue }
                let changed = current.name != seed.name || current.phone != (seed.phone ?? "")
                    || current.address != (seed.address ?? "") || current.website != (seed.website ?? "")
                    || current.notes != (seed.notes ?? "") || current.latitude != seed.latitude
                    || current.longitude != seed.longitude || current.categoryRaw != seed.category.rawValue
                if changed {
                    current.name = seed.name
                    current.category = seed.category
                    current.phone = seed.phone ?? ""
                    current.address = seed.address ?? ""
                    current.latitude = seed.latitude
                    current.longitude = seed.longitude
                    current.website = seed.website ?? ""
                    current.notes = seed.notes ?? ""
                    refreshed += 1
                }
                continue
            }
            context.insert(EmergencyContact(
                name: seed.name,
                category: seed.category,
                phone: seed.phone ?? "",
                address: seed.address ?? "",
                latitude: seed.latitude,
                longitude: seed.longitude,
                website: seed.website ?? "",
                notes: seed.notes ?? "",
                isBuiltIn: true,
                seedKey: seed.key
            ))
            inserted += 1
        }
        if inserted + refreshed > 0 {
            log.info("Emergency contacts v\(file.version): \(inserted) added, \(refreshed) refreshed")
        }
    }

    static func loadJSON<T: Decodable>(_ name: String, bundle: Bundle = .main) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Offline")
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
