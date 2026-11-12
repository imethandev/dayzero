import Foundation
import SwiftData

// MARK: - Enums (stored as raw strings so predicates and exports stay simple)

enum SupplyKind: String, Codable, CaseIterable, Identifiable {
    case food, water, tool
    var id: String { rawValue }
    var title: String {
        switch self {
        case .food: "Food"
        case .water: "Water"
        case .tool: "Tools"
        }
    }
}

/// The three tool pages. Stored on tool items; nil (older or custom items) counts as survival.
enum ToolGroup: String, Codable, CaseIterable, Identifiable {
    case power, water, sanitation, survival
    var id: String { rawValue }
    var title: String {
        switch self {
        case .power: "Power Tools"
        case .water: "Water Tools"
        case .sanitation: "Sanitation"
        case .survival: "Survival Tools"
        }
    }
}

/// The three food pages. Stored on food items; nil (older or custom items) counts as regular food.
enum FoodGroup: String, Codable, CaseIterable, Identifiable {
    case regular, baby, pet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "Food"
        case .baby: "Baby Food"
        case .pet: "Pet Food"
        }
    }
    /// Pet food never counts toward the household's days of food.
    var feedsHousehold: Bool { self != .pet }
}

enum Gender: String, Codable, CaseIterable, Identifiable {
    case notSelected, male, female
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notSelected: "Not selected"
        case .male: "Male"
        case .female: "Female"
        }
    }
}

enum ContactCategory: String, Codable, CaseIterable, Identifiable {
    case emergency, medical, fire, police, poison, utilities, shelters, government, personal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .emergency: "Emergency"
        case .medical: "Medical"
        case .fire: "Fire"
        case .police: "Police"
        case .poison: "Poison control"
        case .utilities: "Utilities"
        case .shelters: "Shelters"
        case .government: "Government"
        case .personal: "Personal"
        }
    }
}

enum MapPinKind: String, Codable, CaseIterable, Identifiable {
    case cache, meetingPoint, waterSource, shelter, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cache: "Cache"
        case .meetingPoint: "Meeting point"
        case .waterSource: "Water source"
        case .shelter: "Shelter"
        case .other: "Other"
        }
    }
}

// MARK: - SupplyItem

@Model
final class SupplyItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var quantity: Double
    var unit: String
    var caloriesPerUnit: Double
    var gallonsPerUnit: Double
    var expiresOn: Date?
    var storageLocation: String
    var notes: String
    var isBuiltIn: Bool
    var isHidden: Bool
    var sortOrder: Int
    var updatedAt: Date
    /// Stable key from supply_catalog.json, so later catalog versions can be merged. Nil for user-added items.
    var catalogKey: String?
    /// Tool page this item belongs on (tools only).
    var toolGroupRaw: String? = nil

    /// Food page this item belongs on (food only).
    var foodGroupRaw: String? = nil

    var foodGroup: FoodGroup {
        get { foodGroupRaw.flatMap(FoodGroup.init(rawValue:)) ?? .regular }
        set { foodGroupRaw = newValue.rawValue }
    }

    var toolGroup: ToolGroup {
        get { toolGroupRaw.flatMap(ToolGroup.init(rawValue:)) ?? .survival }
        set { toolGroupRaw = newValue.rawValue }
    }

    var kind: SupplyKind {
        get { SupplyKind(rawValue: kindRaw) ?? .tool }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: SupplyKind,
        quantity: Double = 0,
        unit: String,
        caloriesPerUnit: Double = 0,
        gallonsPerUnit: Double = 0,
        expiresOn: Date? = nil,
        storageLocation: String = "",
        notes: String = "",
        isBuiltIn: Bool = false,
        isHidden: Bool = false,
        sortOrder: Int = 0,
        updatedAt: Date = .now,
        catalogKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.quantity = quantity
        self.unit = unit
        self.caloriesPerUnit = caloriesPerUnit
        self.gallonsPerUnit = gallonsPerUnit
        self.expiresOn = expiresOn
        self.storageLocation = storageLocation
        self.notes = notes
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.catalogKey = catalogKey
    }
}

// MARK: - HouseholdMember

@Model
final class HouseholdMember {
    static let defaultDailyCalories = 2_000.0
    static let defaultDailyWaterGallons = 1.0

    @Attribute(.unique) var id: UUID
    var name: String
    var birthYear: Int?
    var relationship: String
    var dailyCalories: Double
    var dailyWaterGallons: Double
    var isActive: Bool
    var notes: String
    var phone: String = ""
    /// Nil means not selected.
    var genderRaw: String? = nil

    var gender: Gender {
        get { genderRaw.flatMap(Gender.init(rawValue:)) ?? .notSelected }
        set { genderRaw = newValue == .notSelected ? nil : newValue.rawValue }
    }
    @Relationship(deleteRule: .nullify, inverse: \Note.member)
    var linkedNotes: [Note] = []

    init(
        id: UUID = UUID(),
        name: String,
        birthYear: Int? = nil,
        relationship: String = "",
        dailyCalories: Double = HouseholdMember.defaultDailyCalories,
        dailyWaterGallons: Double = HouseholdMember.defaultDailyWaterGallons,
        isActive: Bool = true,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.birthYear = birthYear
        self.relationship = relationship
        self.dailyCalories = dailyCalories
        self.dailyWaterGallons = dailyWaterGallons
        self.isActive = isActive
        self.notes = notes
    }
}

// MARK: - Note

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var member: HouseholdMember?
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        member: HouseholdMember? = nil,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.member = member
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - EmergencyContact

@Model
final class EmergencyContact {
    @Attribute(.unique) var id: UUID
    var name: String
    var categoryRaw: String
    var phone: String
    var address: String
    var latitude: Double?
    var longitude: Double?
    var website: String
    var notes: String
    var isBuiltIn: Bool
    var isFavorite: Bool
    /// Built-in entries can be hidden instead of deleted, so reseeding never brings them back.
    var isHidden: Bool
    var seedKey: String?
    /// True once the user edits a built-in entry; seed updates then leave it alone.
    var userEdited: Bool = false

    var category: ContactCategory {
        get { ContactCategory(rawValue: categoryRaw) ?? .personal }
        set { categoryRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        category: ContactCategory,
        phone: String = "",
        address: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        website: String = "",
        notes: String = "",
        isBuiltIn: Bool = false,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        seedKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.phone = phone
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.website = website
        self.notes = notes
        self.isBuiltIn = isBuiltIn
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.seedKey = seedKey
    }
}

// MARK: - MapPin

@Model
final class MapPin {
    @Attribute(.unique) var id: UUID
    var title: String
    var kindRaw: String
    var latitude: Double
    var longitude: Double
    var notes: String

    var kind: MapPinKind {
        get { MapPinKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), title: String, kind: MapPinKind, latitude: Double, longitude: Double, notes: String = "") {
        self.id = id
        self.title = title
        self.kindRaw = kind.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.notes = notes
    }
}

enum DayZeroSchema {
    static let models: [any PersistentModel.Type] = [
        SupplyItem.self, HouseholdMember.self, Note.self, EmergencyContact.self, MapPin.self,
    ]
}
