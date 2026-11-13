import CoreLocation
import Foundation
import Observation
import SwiftUI
import OSLog
import SwiftData

// MARK: Region

/// The user's country (ISO 3166 code, like "US"), for emergency numbers and contacts.
struct UserRegion: Equatable {
    enum Source: Equatable { case manual, map, device, none }

    var country: String?
    var source: Source

    var displayName: String {
        country.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "Not set"
    }

    var sourceText: String {
        switch source {
        case .manual: "Chosen by you"
        case .map: "From your offline map"
        case .device: "From your iPhone's region setting"
        case .none: "Unknown"
        }
    }
}

/// The user's country: their own choice first, then the downloaded map's area, then the iPhone's region setting.
enum RegionSettings {
    static let manualCountryKey = "region.manualCountry"
    static let changed = Notification.Name("RegionSettings.changed")

    static var manualCountry: String? {
        UserDefaults.standard.string(forKey: manualCountryKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var detected: UserRegion {
        if let country = MapRegionStore.shared.manifest?.countryCode {
            return UserRegion(country: country, source: .map)
        }
        if let country = Locale.current.region?.identifier, country.count == 2 {
            return UserRegion(country: country, source: .device)
        }
        return UserRegion(country: nil, source: .none)
    }

    static var current: UserRegion {
        if let country = manualCountry { return UserRegion(country: country, source: .manual) }
        return detected
    }

    /// nil goes back to automatic.
    static func setManual(country: String?) {
        UserDefaults.standard.set(country ?? "", forKey: manualCountryKey)
        RegionModel.shared.refresh()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Observable copy of the region for SwiftUI views (the call button, the region row).
@Observable
final class RegionModel {
    static let shared = RegionModel()
    private(set) var current = RegionSettings.current

    var emergencyNumber: String { ContactPacks.emergencyNumber(for: current) }

    func refresh() { current = RegionSettings.current }
}

/// The big red button: calls the emergency number for the user's country.
struct EmergencyCallButton: View {
    var prominent = true
    private var region = RegionModel.shared

    init(prominent: Bool = true) { self.prominent = prominent }

    var body: some View {
        CallButton(label: "Call \(region.emergencyNumber)", phone: region.emergencyNumber, prominent: prominent)
    }
}

// MARK: Packs

/// National emergency numbers for many countries (emergency_numbers.json).
struct EmergencyNumbersFile: Decodable {
    struct Country: Decodable {
        let code: String
        let general: String?
        let police: String?
        let fire: String?
        let ambulance: String?
        let notes: String?

        /// The number for the big call button.
        var primary: String { general ?? ambulance ?? police ?? "112" }
    }

    let version: Int
    let countries: [Country]
}

/// A national contact pack (contacts_<country>.json in Resources/Offline, e.g. contacts_US.json)
/// with national lines beyond the emergency number. Contributors add a country by adding a file.
struct ContactPack: Decodable {
    let version: Int
    let region: String
    let name: String
    let verifiedOn: String?
    let contacts: [Seeder.ContactSeed]
}

enum ContactPacks {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "contacts")

    static let packs: [ContactPack] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let more = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Offline") ?? []
        return (urls + more)
            .filter { $0.lastPathComponent.hasPrefix("contacts_") }
            .compactMap { url in
                do { return try JSONDecoder().decode(ContactPack.self, from: Data(contentsOf: url)) }
                catch { log.error("Bad contact pack \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"); return nil }
            }
            .sorted { $0.region < $1.region }
    }()

    static let numbers: EmergencyNumbersFile? = {
        guard let url = Bundle.main.url(forResource: "emergency_numbers", withExtension: "json")
            ?? Bundle.main.url(forResource: "emergency_numbers", withExtension: "json", subdirectory: "Offline")
        else { return nil }
        return try? JSONDecoder().decode(EmergencyNumbersFile.self, from: Data(contentsOf: url))
    }()

    static func pack(for region: String) -> ContactPack? { packs.first { $0.region == region } }

    static func country(_ code: String?) -> EmergencyNumbersFile.Country? {
        guard let code else { return nil }
        return numbers?.countries.first { $0.code == code }
    }

    /// The number for the big "Call" button. 112 also reaches emergency services from
    /// mobile phones in most of the world.
    static func emergencyNumber(for region: UserRegion = RegionSettings.current) -> String {
        country(region.country)?.primary ?? "112"
    }

    /// Contacts for the user's country: its pack when there is one, otherwise its emergency numbers.
    static func seeds(for region: UserRegion) -> [Seeder.ContactSeed] {
        if let code = region.country, let national = pack(for: code) { return national.contacts }
        return numberSeeds(for: region.country)
    }

    private static func numberSeeds(for code: String?) -> [Seeder.ContactSeed] {
        guard let code, let c = country(code) else {
            return [Seeder.ContactSeed(key: "world.112", name: "Emergency (112)", category: .emergency, phone: "112",
                                       notes: "112 reaches emergency services from mobile phones in most countries. Your iPhone's Emergency SOS (hold the side and a volume button) calls the local number.")]
        }
        var out: [Seeder.ContactSeed] = []
        if let g = c.general {
            out.append(.init(key: "world.\(code).general", name: "Emergency (police, fire, ambulance)", category: .emergency,
                             phone: g, notes: c.notes))
        }
        if let p = c.police, p != c.general {
            out.append(.init(key: "world.\(code).police", name: "Police", category: .police, phone: p))
        }
        if let a = c.ambulance, a != c.general {
            out.append(.init(key: "world.\(code).ambulance", name: c.fire == a ? "Ambulance and fire" : "Ambulance",
                             category: .medical, phone: a))
        }
        if let f = c.fire, f != c.general, f != c.ambulance {
            out.append(.init(key: "world.\(code).fire", name: "Fire", category: .fire, phone: f))
        }
        return out
    }

    /// Brings built-in contacts in line with the region: adds and refreshes the region's
    /// contacts, and removes other regions' built-ins the user hasn't starred or edited.
    /// "Near you" contacts (seedKey "near.…") are managed by `NearbyContacts`.
    @MainActor
    static func sync(_ context: ModelContext, region: UserRegion = RegionSettings.current) {
        let wanted = seeds(for: region)
        let wantedKeys = Set(wanted.map(\.key))
        do {
            let existing = try context.fetch(FetchDescriptor<EmergencyContact>())
            var removed = 0
            for c in existing where c.isBuiltIn {
                guard let key = c.seedKey, !key.hasPrefix(NearbyContacts.keyPrefix), !wantedKeys.contains(key) else { continue }
                if c.isFavorite || c.userEdited { continue }
                context.delete(c)
                removed += 1
            }
            let (inserted, refreshed) = Seeder.apply(wanted, existing: existing.filter { !$0.isDeleted }, in: context)
            if context.hasChanges { try context.save() }
            if inserted + refreshed + removed > 0 {
                log.info("Contacts for \(region.displayName, privacy: .public): \(inserted) added, \(refreshed) refreshed, \(removed) removed")
            }
        } catch {
            log.error("Contact sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: Near you

/// The closest hospitals, police and fire stations with phone numbers, from the downloaded
/// map's places, added to the Emergency page as a "Near you" group.
enum NearbyContacts {
    static let keyPrefix = "near."
    private static let wanted: [(PlaceKind, Int)] = [(.hospital, 3), (.police, 2), (.fire_station, 2)]

    @MainActor
    static func refresh(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<EmergencyContact>())) ?? []
        let old = existing.filter { $0.seedKey?.hasPrefix(keyPrefix) == true }
        guard let region = MapRegionStore.shared.manifest else {
            for c in old where !c.isFavorite && !c.userEdited { context.delete(c) }
            try? context.save()
            return
        }
        let center = CLLocationCoordinate2DMake(region.centerLatitude, region.centerLongitude)
        let day = region.downloadedAt.formatted(date: .abbreviated, time: .omitted)
        var seeds: [Seeder.ContactSeed] = []
        for (kind, count) in wanted {
            let places = PlacesDatabase.shared.nearest([kind], to: center, limit: 25).filter { !$0.phone.isEmpty }.prefix(count)
            for p in places {
                seeds.append(.init(
                    key: keyPrefix + "\(kind.rawValue).\(String(format: "%.5f,%.5f", p.latitude, p.longitude))",
                    name: p.name, category: kind.contactCategory, phone: p.phone, address: p.address,
                    latitude: p.latitude, longitude: p.longitude, website: p.website,
                    notes: "Near your map area. From OpenStreetMap, downloaded \(day). Confirm the number before you rely on it."))
            }
        }
        let keep = Set(seeds.map(\.key))
        for c in old where !keep.contains(c.seedKey ?? "") && !c.isFavorite && !c.userEdited { context.delete(c) }
        _ = Seeder.apply(seeds, existing: existing.filter { !$0.isDeleted }, in: context)
        try? context.save()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
