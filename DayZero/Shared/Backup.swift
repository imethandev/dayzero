import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Whole-household backup as one JSON file, for AirDrop or a USB drive.
/// Import replaces everything on the phone with the file's contents.
struct BackupFile: Codable {
    var app = "DayZero"
    var formatVersion = 1
    var exportedAt: Date
    var supplies: [Supply]
    var members: [Member]
    var notes: [NoteDTO]
    var contacts: [Contact]
    var pins: [Pin]

    struct Supply: Codable {
        var id: UUID, name: String, kind: String, quantity: Double, unit: String
        var caloriesPerUnit: Double, gallonsPerUnit: Double, expiresOn: Date?
        var storageLocation: String, notes: String, isBuiltIn: Bool, isHidden: Bool
        var sortOrder: Int, updatedAt: Date, catalogKey: String?
        var toolGroup: String? = nil // absent in backups made before tool pages existed
        var foodGroup: String? = nil // absent in backups made before food pages existed
    }

    struct Member: Codable {
        var id: UUID, name: String, birthYear: Int?, relationship: String
        var dailyCalories: Double, dailyWaterGallons: Double, isActive: Bool, notes: String
        var phone: String? = nil // absent in older backups
        var gender: String? = nil // absent in older backups
    }

    struct NoteDTO: Codable {
        var id: UUID, title: String, body: String, memberID: UUID?
        var isPinned: Bool, createdAt: Date, updatedAt: Date
    }

    struct Contact: Codable {
        var id: UUID, name: String, category: String, phone: String, address: String
        var latitude: Double?, longitude: Double?, website: String, notes: String
        var isBuiltIn: Bool, isFavorite: Bool, isHidden: Bool, seedKey: String?, userEdited: Bool
    }

    struct Pin: Codable {
        var id: UUID, title: String, kind: String, latitude: Double, longitude: Double, notes: String
    }

    var summary: String {
        "\(members.count) members, \(notes.count) notes, \(supplies.filter { $0.quantity > 0 }.count) stocked supplies, \(contacts.count) contacts, \(pins.count) pins"
    }
}

enum Backup {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @MainActor
    static func make(from context: ModelContext, now: Date = .now) throws -> BackupFile {
        BackupFile(
            exportedAt: now,
            supplies: try context.fetch(FetchDescriptor<SupplyItem>(sortBy: [SortDescriptor(\.sortOrder)])).map {
                .init(id: $0.id, name: $0.name, kind: $0.kindRaw, quantity: $0.quantity, unit: $0.unit,
                      caloriesPerUnit: $0.caloriesPerUnit, gallonsPerUnit: $0.gallonsPerUnit, expiresOn: $0.expiresOn,
                      storageLocation: $0.storageLocation, notes: $0.notes, isBuiltIn: $0.isBuiltIn, isHidden: $0.isHidden,
                      sortOrder: $0.sortOrder, updatedAt: $0.updatedAt, catalogKey: $0.catalogKey,
                      toolGroup: $0.toolGroupRaw, foodGroup: $0.foodGroupRaw)
            },
            members: try context.fetch(FetchDescriptor<HouseholdMember>()).map {
                .init(id: $0.id, name: $0.name, birthYear: $0.birthYear, relationship: $0.relationship,
                      dailyCalories: $0.dailyCalories, dailyWaterGallons: $0.dailyWaterGallons, isActive: $0.isActive, notes: $0.notes,
                      phone: $0.phone, gender: $0.genderRaw)
            },
            notes: try context.fetch(FetchDescriptor<Note>()).map {
                .init(id: $0.id, title: $0.title, body: $0.body, memberID: $0.member?.id,
                      isPinned: $0.isPinned, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            contacts: try context.fetch(FetchDescriptor<EmergencyContact>()).map {
                .init(id: $0.id, name: $0.name, category: $0.categoryRaw, phone: $0.phone, address: $0.address,
                      latitude: $0.latitude, longitude: $0.longitude, website: $0.website, notes: $0.notes,
                      isBuiltIn: $0.isBuiltIn, isFavorite: $0.isFavorite, isHidden: $0.isHidden,
                      seedKey: $0.seedKey, userEdited: $0.userEdited)
            },
            pins: try context.fetch(FetchDescriptor<MapPin>()).map {
                .init(id: $0.id, title: $0.title, kind: $0.kindRaw, latitude: $0.latitude, longitude: $0.longitude, notes: $0.notes)
            }
        )
    }

    /// Writes the backup to a protected temporary file for the share sheet.
    @MainActor
    static func export(from context: ModelContext) throws -> URL {
        let file = try make(from: context)
        let day = file.exportedAt.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayZero-backup-\(day).json")
        try encoder().encode(file).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func read(_ url: URL) throws -> BackupFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try decoder().decode(BackupFile.self, from: Data(contentsOf: url))
        guard file.app == "DayZero" else { throw CocoaError(.fileReadCorruptFile) }
        guard file.formatVersion <= 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        return file
    }

    /// Replaces all user data with the backup. Missing catalog items are re-seeded afterwards.
    @MainActor
    static func restore(_ file: BackupFile, into context: ModelContext) throws {
        try context.delete(model: Note.self)
        try context.delete(model: HouseholdMember.self)
        try context.delete(model: SupplyItem.self)
        try context.delete(model: EmergencyContact.self)
        try context.delete(model: MapPin.self)
        try context.save()

        for s in file.supplies {
            let item = SupplyItem(id: s.id, name: s.name, kind: SupplyKind(rawValue: s.kind) ?? .tool, quantity: s.quantity,
                                  unit: s.unit, caloriesPerUnit: s.caloriesPerUnit, gallonsPerUnit: s.gallonsPerUnit,
                                  expiresOn: s.expiresOn, storageLocation: s.storageLocation, notes: s.notes,
                                  isBuiltIn: s.isBuiltIn, isHidden: s.isHidden, sortOrder: s.sortOrder,
                                  updatedAt: s.updatedAt, catalogKey: s.catalogKey)
            item.toolGroupRaw = s.toolGroup
            item.foodGroupRaw = s.foodGroup
            context.insert(item)
        }
        var membersByID: [UUID: HouseholdMember] = [:]
        for m in file.members {
            let member = HouseholdMember(id: m.id, name: m.name, birthYear: m.birthYear, relationship: m.relationship,
                                         dailyCalories: m.dailyCalories, dailyWaterGallons: m.dailyWaterGallons,
                                         isActive: m.isActive, notes: m.notes)
            member.phone = m.phone ?? ""
            member.genderRaw = m.gender
            context.insert(member)
            membersByID[m.id] = member
        }
        for n in file.notes {
            let note = Note(id: n.id, title: n.title, body: n.body, isPinned: n.isPinned, createdAt: n.createdAt, updatedAt: n.updatedAt)
            context.insert(note)
            note.member = n.memberID.flatMap { membersByID[$0] }
        }
        for c in file.contacts {
            let contact = EmergencyContact(id: c.id, name: c.name, category: ContactCategory(rawValue: c.category) ?? .personal,
                                           phone: c.phone, address: c.address, latitude: c.latitude, longitude: c.longitude,
                                           website: c.website, notes: c.notes, isBuiltIn: c.isBuiltIn,
                                           isFavorite: c.isFavorite, isHidden: c.isHidden, seedKey: c.seedKey)
            contact.userEdited = c.userEdited
            context.insert(contact)
        }
        for p in file.pins {
            context.insert(MapPin(id: p.id, title: p.title, kind: MapPinKind(rawValue: p.kind) ?? .other,
                                  latitude: p.latitude, longitude: p.longitude, notes: p.notes))
        }
        try context.save()
        Seeder.seedIfNeeded(context)
    }
}
