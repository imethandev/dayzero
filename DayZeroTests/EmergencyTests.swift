import Foundation
import SwiftData
import Testing
@testable import DayZero

@Suite("Emergency")
struct EmergencyTests {
    @Test(arguments: [
        ("911", "tel:911"),
        ("1-800-222-1222", "tel:18002221222"),
        ("(360) 555-0100", "tel:3605550100"),
        ("+1 206 555 0100", "tel:+12065550100"),
        ("211", "tel:211"),
    ])
    func phoneLinksKeepOnlyDigits(input: String, expected: String) {
        #expect(PhoneLink.url(for: input)?.absoluteString == expected)
    }

    @Test func emptyPhoneHasNoLink() {
        #expect(PhoneLink.url(for: "") == nil)
        #expect(PhoneLink.url(for: "n/a") == nil)
    }

    @MainActor
    @Test func bundledContactsDecodeAndIncludeCoreNumbers() throws {
        let file: Seeder.ContactsFile = try Seeder.loadJSON("emergency_contacts")
        let byKey = Dictionary(uniqueKeysWithValues: file.contacts.map { ($0.key, $0) })
        #expect(byKey["emergency.911"]?.phone == "911")
        #expect(byKey["poison.national"]?.phone == "1-800-222-1222")
        #expect(byKey["gov.wa211"]?.phone == "211")
        #expect(Set(file.contacts.map(\.key)).count == file.contacts.count, "seed keys must be unique")
        for c in file.contacts {
            if let lat = c.latitude, let lon = c.longitude {
                // Everything seeded should sit in or near Washington.
                #expect((45.0...49.5).contains(lat), "\(c.key) latitude")
                #expect((-125.0...(-116.5)).contains(lon), "\(c.key) longitude")
            }
        }
    }

    @MainActor
    @Test func seedingIsIdempotentAndRespectsUserEdits() throws {
        let container = try ModelContainer(
            for: Schema(DayZeroSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        Seeder.seedIfNeeded(context)
        let first = try context.fetch(FetchDescriptor<EmergencyContact>())
        let supplies = try context.fetch(FetchDescriptor<SupplyItem>())
        #expect(!first.isEmpty)
        #expect(supplies.allSatisfy { $0.quantity == 0 && $0.isBuiltIn })

        // Simulate a user edit on one built-in and a stale value on another.
        let poison = try #require(first.first { $0.seedKey == "poison.national" })
        poison.phone = "555-0000"
        poison.userEdited = true
        let wa211 = try #require(first.first { $0.seedKey == "gov.wa211" })
        wa211.phone = "stale"
        try context.save()

        Seeder.seedIfNeeded(context)
        let second = try context.fetch(FetchDescriptor<EmergencyContact>())
        #expect(second.count == first.count, "re-seeding must not duplicate")
        #expect(try context.fetch(FetchDescriptor<SupplyItem>()).count == supplies.count)
        #expect(poison.phone == "555-0000", "user edits survive seed refresh")
        #expect(wa211.phone == "211", "unedited built-ins refresh from the seed file")
    }
}

@Suite("Tool catalog")
@MainActor
struct ToolCatalogTests {
    @Test func everyToolHasAGroupAndEachPageHasItems() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        let tools = file.items.filter { $0.kind == .tool }
        #expect(tools.allSatisfy { $0.group != nil })
        for g in ToolGroup.allCases {
            #expect(tools.filter { $0.group == g }.count >= 10, "\(g) page should be well stocked")
        }
        #expect(Set(file.items.map(\.key)).count == file.items.count, "catalog keys must be unique")
    }

    @Test func existingInstallGetsGroupsAndKeepsQuantities() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        // Simulate a phone seeded by the previous catalog: a tool with no group and a quantity.
        let old = SupplyItem(name: "Headlamp", kind: .tool, quantity: 2, unit: "each", isBuiltIn: true,
                             sortOrder: 99, catalogKey: "tool.headlamp")
        ctx.insert(old)
        try ctx.save()

        Seeder.seedIfNeeded(ctx)

        #expect(old.toolGroup == .power)
        #expect(old.quantity == 2, "upgrading the catalog never touches quantities")
        let all = try ctx.fetch(FetchDescriptor<SupplyItem>())
        #expect(all.filter { $0.catalogKey == "tool.headlamp" }.count == 1)
        #expect(all.contains { $0.catalogKey == "tool.gravity_water_filter" && $0.toolGroup == .water && $0.quantity == 0 })
    }

    @Test func sanitationItemsMoveOutOfSurvivalOnUpgrade() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        // Seeded by the previous catalog: toilet paper lived under Survival Tools.
        let tp = SupplyItem(name: "Toilet paper", kind: .tool, quantity: 12, unit: "roll", isBuiltIn: true, catalogKey: "tool.toilet_paper")
        tp.toolGroupRaw = "survival"
        ctx.insert(tp)
        try ctx.save()
        Seeder.seedIfNeeded(ctx)
        #expect(tp.toolGroup == .sanitation)
        #expect(tp.quantity == 12)
    }
}

@Suite("Food pages and member phone")
@MainActor
struct FoodPagesTests {
    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test func everyFoodItemHasAPageAndEachPageHasItems() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        let food = file.items.filter { $0.kind == .food }
        #expect(food.allSatisfy { $0.foodGroup != nil })
        for g in FoodGroup.allCases {
            #expect(food.filter { $0.foodGroup == g }.count >= 5, "\(g) page should have items")
        }
        #expect(food.filter { $0.foodGroup == .pet }.allSatisfy { ($0.caloriesPerUnit ?? 0) == 0 })
    }

    @Test func formulaAndPetFoodMoveOnUpgradeAndKeepQuantities() throws {
        let ctx = try memoryContext()
        let formula = SupplyItem(name: "Infant formula", kind: .food, quantity: 3, unit: "can (12 oz powder)",
                                 caloriesPerUnit: 1750, isBuiltIn: true, catalogKey: "food.infant_formula")
        let pet = SupplyItem(name: "Pet food", kind: .food, quantity: 20, unit: "lb", isBuiltIn: true, catalogKey: "food.pet_food")
        ctx.insert(formula); ctx.insert(pet)
        try ctx.save()
        Seeder.seedIfNeeded(ctx)
        #expect(formula.foodGroup == .baby && formula.quantity == 3)
        #expect(pet.foodGroup == .pet && pet.quantity == 20 && pet.name == "Dry dog food")
    }

    @Test func petFoodNeverCountsTowardDaysOfFood() throws {
        let ctx = try memoryContext()
        let rice = SupplyItem(name: "Rice", kind: .food, quantity: 1, unit: "lb", caloriesPerUnit: 2000)
        let baby = SupplyItem(name: "Formula", kind: .food, quantity: 1, unit: "can", caloriesPerUnit: 1000)
        baby.foodGroup = .baby
        let pet = SupplyItem(name: "Custom kibble", kind: .food, quantity: 10, unit: "lb", caloriesPerUnit: 1500)
        pet.foodGroup = .pet
        let s = DaysRemainingCalculator.summarize(items: [rice, baby, pet], members: [HouseholdMember(name: "A")],
                                                  includeExpired: false)
        #expect(s.totalCalories == 3000)
    }

    @Test func backupKeepsMemberPhoneAndFoodPage() throws {
        let ctx = try memoryContext()
        let m = HouseholdMember(name: "Mai"); m.phone = "(206) 555-0123"; m.gender = .female
        let n = HouseholdMember(name: "Kim")
        ctx.insert(n)
        ctx.insert(m)
        let item = SupplyItem(name: "Kibble", kind: .food, quantity: 5, unit: "lb"); item.foodGroup = .pet
        ctx.insert(item)
        try ctx.save()
        let data = try Backup.encoder().encode(try Backup.make(from: ctx))
        let file = try Backup.decoder().decode(BackupFile.self, from: data)

        let other = try memoryContext()
        try Backup.restore(file, into: other)
        let restored = try other.fetch(FetchDescriptor<HouseholdMember>())
        #expect(restored.first { $0.name == "Mai" }?.phone == "(206) 555-0123")
        #expect(restored.first { $0.name == "Mai" }?.gender == .female)
        #expect(restored.first { $0.name == "Kim" }?.gender == .notSelected)
        let kibble = try other.fetch(FetchDescriptor<SupplyItem>()).first { $0.name == "Kibble" }
        #expect(kibble?.foodGroup == .pet)
    }
}
