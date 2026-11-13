import CoreLocation
import Foundation
import SQLite3
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
    @Test func packsDecodeAndHaveUniqueKeys() throws {
        let us = try #require(ContactPacks.pack(for: "US"))
        let byKey = Dictionary(uniqueKeysWithValues: us.contacts.map { ($0.key, $0) })
        #expect(byKey["emergency.911"]?.phone == "911")
        #expect(byKey["poison.national"]?.phone == "1-800-222-1222")
        #expect(byKey["us.988"]?.phone == "988")
        #expect(ContactPacks.pack(for: "US-WA") == nil, "no state packs")
        for pack in ContactPacks.packs {
            #expect(Set(pack.contacts.map(\.key)).count == pack.contacts.count, "\(pack.region) keys must be unique")
        }
        let numbers = try #require(ContactPacks.numbers)
        #expect(Set(numbers.countries.map(\.code)).count == numbers.countries.count)
        #expect(numbers.countries.allSatisfy { $0.code.count == 2 && ($0.general ?? $0.police) != nil })
    }

    @MainActor
    @Test func emergencyNumberFollowsCountry() {
        func number(_ c: String?) -> String { ContactPacks.emergencyNumber(for: UserRegion(country: c, source: .manual)) }
        #expect(number("US") == "911")
        #expect(number("GB") == "999")
        #expect(number("AU") == "000")
        #expect(number("DE") == "112")
        #expect(number("JP") == "119")
        #expect(number("ZZ") == "112", "unknown countries fall back to 112")
    }

    @MainActor
    @Test func countryChangeSwapsBuiltInsButKeepsStarredAndEdited() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let us = UserRegion(country: "US", source: .manual)
        ContactPacks.sync(context, region: us)
        var all = try context.fetch(FetchDescriptor<EmergencyContact>())
        #expect(all.contains { $0.seedKey == "us.988" })
        try #require(all.first { $0.seedKey == "us.fema" }).isFavorite = true
        // A contact from the old Washington list the user never touched goes away.
        context.insert(EmergencyContact(name: "Adams County EM", category: .government, phone: "509-488-3704",
                                        isBuiltIn: true, seedKey: "gov.county.adams"))
        try context.save()

        ContactPacks.sync(context, region: UserRegion(country: "GB", source: .manual))
        all = try context.fetch(FetchDescriptor<EmergencyContact>())
        #expect(all.contains { $0.seedKey == "world.GB.general" && $0.phone == "999" })
        #expect(!all.contains { $0.seedKey == "us.988" })
        #expect(all.contains { $0.seedKey == "us.fema" }, "starred contacts stay")
        #expect(!all.contains { $0.seedKey == "gov.county.adams" })
    }

    @MainActor
    @Test func seedingIsIdempotentAndRespectsUserEdits() throws {
        let container = try ModelContainer(
            for: Schema(DayZeroSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let us = UserRegion(country: "US", source: .manual)

        Seeder.seedIfNeeded(context)
        ContactPacks.sync(context, region: us)
        let first = try context.fetch(FetchDescriptor<EmergencyContact>())
        let supplies = try context.fetch(FetchDescriptor<SupplyItem>())
        #expect(!first.isEmpty)
        #expect(supplies.allSatisfy { $0.quantity == 0 && $0.isBuiltIn })

        // Simulate a user edit on one built-in and a stale value on another.
        let poison = try #require(first.first { $0.seedKey == "poison.national" })
        poison.phone = "555-0000"
        poison.userEdited = true
        let line211 = try #require(first.first { $0.seedKey == "us.211" })
        line211.phone = "stale"
        try context.save()

        Seeder.seedIfNeeded(context)
        ContactPacks.sync(context, region: us)
        let second = try context.fetch(FetchDescriptor<EmergencyContact>())
        #expect(second.count == first.count, "re-seeding must not duplicate")
        #expect(try context.fetch(FetchDescriptor<SupplyItem>()).count == supplies.count)
        #expect(poison.phone == "555-0000", "user edits survive seed refresh")
        #expect(line211.phone == "211", "unedited built-ins refresh from the pack")
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

@Suite("Fuel")
@MainActor
struct FuelTests {
    @Test func catalogHasFuelOnThePowerPage() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        for key in FuelSummary.fuels.map(\.key) {
            #expect(file.items.contains { $0.key == key && $0.group == .power }, "\(key) missing")
        }
    }

    @Test func summaryListsOnlyStockedFuel() {
        let gas = SupplyItem(name: "Gasoline", kind: .tool, quantity: 10, unit: "gallon", catalogKey: "tool.fuel_gasoline")
        let diesel = SupplyItem(name: "Diesel", kind: .tool, quantity: 0, unit: "gallon", catalogKey: "tool.fuel_diesel")
        let propane = SupplyItem(name: "Propane", kind: .tool, quantity: 2, unit: "tank", catalogKey: "tool.fuel_propane_20lb")
        #expect(FuelSummary.line([gas, diesel, propane]) == "Fuel: 10 gal gasoline · 2 tanks propane")
        #expect(FuelSummary.line([diesel]) == nil)
    }
}

@Suite("Communication")
@MainActor
struct CommunicationTests {
    @Test func radiosAndSignalingLiveOnTheCommunicationPage() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        for key in ["tool.battery_or_hand_crank_radio", "tool.gmrs_radio", "tool.ham_radio_handheld",
                    "tool.meshtastic_node", "tool.whistle", "tool.signal_mirror"] {
            #expect(file.items.contains { $0.key == key && $0.group == .communication }, "\(key) missing")
        }
    }

    @Test func existingRadioMovesAndKeepsQuantity() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let radio = SupplyItem(name: "Battery or hand-crank radio", kind: .tool, quantity: 1, unit: "each",
                               isBuiltIn: true, sortOrder: 2, catalogKey: "tool.battery_or_hand_crank_radio")
        radio.toolGroup = .power
        ctx.insert(radio)
        try ctx.save()

        Seeder.seedIfNeeded(ctx)

        #expect(radio.toolGroup == .communication)
        #expect(radio.quantity == 1)
    }
}

@Suite("Shelter")
@MainActor
struct ShelterTests {
    @Test func beddingAndCoverLiveOnTheShelterPage() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        for key in ["tool.tent", "tool.tarp", "tool.sleeping_bag", "tool.emergency_blanket",
                    "tool.hand_warmers", "tool.sleeping_pad", "tool.wool_blankets"] {
            #expect(file.items.contains { $0.key == key && $0.group == .shelter }, "\(key) missing")
        }
    }

    @Test func existingSleepingBagMovesAndKeepsQuantity() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let bag = SupplyItem(name: "Sleeping bag", kind: .tool, quantity: 4, unit: "each",
                             isBuiltIn: true, sortOrder: 80, catalogKey: "tool.sleeping_bag")
        bag.toolGroup = .survival
        ctx.insert(bag)
        try ctx.save()

        Seeder.seedIfNeeded(ctx)

        #expect(bag.toolGroup == .shelter)
        #expect(bag.quantity == 4)
    }
}

@Suite("Medicine, navigation, security")
@MainActor
struct NewToolPagesTests {
    @Test func survivalItemsMovedToTheirPages() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        let expected: [String: ToolGroup] = [
            "tool.first_aid_kit": .firstAid, "tool.trauma_kit_with_tourniquet": .firstAid, "tool.n95_masks": .firstAid,
            "tool.med_prescriptions": .medicine, "tool.med_adhesive_bandages": .firstAid,
            "tool.compass": .navigation, "tool.paper_maps_of_the_area": .navigation,
            "tool.fire_extinguisher": .security, "tool.sec_door_bar": .security,
        ]
        for (key, group) in expected {
            #expect(file.items.contains { $0.key == key && $0.group == group }, "\(key) should be on \(group)")
        }
    }

    @Test func existingFirstAidKitMovesAndKeepsQuantity() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let kit = SupplyItem(name: "First aid kit", kind: .tool, quantity: 1, unit: "each",
                             isBuiltIn: true, sortOrder: 60, catalogKey: "tool.first_aid_kit")
        kit.toolGroup = .survival
        ctx.insert(kit)
        try ctx.save()

        Seeder.seedIfNeeded(ctx)

        #expect(kit.toolGroup == .firstAid)
        #expect(kit.quantity == 1)
    }
}

@Suite("Food tools")
@MainActor
struct FoodToolsTests {
    @Test func cookingGearLivesOnTheFoodToolsPage() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        for key in ["tool.camp_stove", "tool.fuel_canister", "tool.manual_can_opener", "tool.food_cook_set"] {
            #expect(file.items.contains { $0.key == key && $0.group == .food }, "\(key) missing")
        }
    }

    @Test func existingCampStoveMovesAndKeepsQuantity() throws {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let stove = SupplyItem(name: "Camp stove", kind: .tool, quantity: 1, unit: "each",
                               isBuiltIn: true, sortOrder: 70, catalogKey: "tool.camp_stove")
        stove.toolGroup = .survival
        ctx.insert(stove)
        try ctx.save()

        Seeder.seedIfNeeded(ctx)

        #expect(stove.toolGroup == .food)
        #expect(stove.quantity == 1)
    }
}

@Suite("Go-bag")
@MainActor
struct GoBagTests {
    @Test func goBagHasTheEssentials() throws {
        let file: Seeder.CatalogFile = try Seeder.loadJSON("supply_catalog")
        let bag = file.items.filter { $0.group == .goBag }
        #expect(bag.count >= 30)
        for key in ["tool.go_bag_(backpack)", "tool.gobag_water_bottles", "tool.gobag_first_aid",
                    "tool.gobag_medications", "tool.gobag_documents", "tool.gobag_cash"] {
            #expect(bag.contains { $0.key == key }, "\(key) missing")
        }
    }

    @Test func goBagWaterDoesNotCountTowardDaysAtHome() {
        let bagWater = SupplyItem(name: "Bottled water (3 days)", kind: .tool, quantity: 6, unit: "bottle",
                                  catalogKey: "tool.gobag_water_bottles")
        bagWater.toolGroup = .goBag
        let member = HouseholdMember(name: "A")
        let s = DaysRemainingCalculator.summarize(items: [bagWater], members: [member], includeExpired: false)
        #expect(s.totalGallons == 0)
    }
}

@Suite("Tips")
struct TipsTests {
    @Test func everyTipIsComplete() throws {
        let file = try TipsFile.load()
        let tips = file.sections.flatMap(\.tips)
        #expect(tips.count >= 8)
        #expect(Set(tips.map(\.id)).count == tips.count, "tip ids must be unique")
        for t in tips {
            #expect(t.steps.count == 5, "\(t.id) should have 5 steps")
            #expect(!t.safety.isEmpty, "\(t.id) needs safety notes")
            #expect(!t.overview.isEmpty && !t.summary.isEmpty)
        }
        #expect(tips.contains { $0.id == "nuclear_fallout" })
        #expect(tips.contains { $0.id == "sewage_backflow" })
    }
}

@Suite("Map download")
struct MapDownloadTests {
    let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)

    @Test func tileMathMatchesKnownTile() {
        // Seattle at zoom 14 is tile 2624/5721 (OpenStreetMap slippy-map numbering).
        let t = TileMath.tile(seattle, z: 14)
        #expect(t.x == 2624 && t.y == 5721)
    }

    @Test func tilesStartAtTheCenterAndStayUnderTheLimit() {
        let tiles = TileMath.tiles(center: seattle, radiusKm: 20)
        #expect(tiles.first == TileID(z: 0, x: 0, y: 0))
        let deep = tiles.filter { $0.z == 14 }
        let mid = TileMath.tile(seattle, z: 14)
        #expect(deep.first == TileID(z: 14, x: mid.x, y: mid.y), "zoom 14 starts at the center tile")
        #expect(tiles.count <= MapDownloader.maxTiles)
        #expect(MapDownloader.allowedRadii(at: seattle).allSatisfy {
            TileMath.tiles(center: seattle, radiusKm: $0).count <= MapDownloader.maxTiles
        })
    }

    @Test func placesWriterUsesPipelineRules() throws {
        #expect(PlacesWriter.kind(of: ["amenity": "hospital"]) == .hospital)
        #expect(PlacesWriter.kind(of: ["amenity": "shelter", "shelter_type": "picnic_shelter"]) == nil)
        #expect(PlacesWriter.kind(of: ["place": "town"]) == .town)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let elements: [[String: Any]] = [
            ["type": "node", "id": 1, "lat": 47.6, "lon": -122.3, "tags": ["amenity": "hospital", "name": "Harbor Hospital"]],
            ["type": "way", "id": 2, "center": ["lat": 47.61, "lon": -122.31], "tags": ["amenity": "fuel"]],
            ["type": "node", "id": 3, "lat": 47.62, "lon": -122.32, "tags": ["amenity": "bench"]],
        ]
        #expect(try PlacesWriter.write(elements: elements, to: url) == 2)
        let db = PlacesDatabase(path: url.path)
        #expect(db.search("harbor", near: nil).first?.kind == .hospital)
        #expect(db.nearest([.fuel], to: seattle, limit: 1).first?.name == "Fuel")
    }

    @Test func mbtilesWriterFlipsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).mbtiles")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try MBTilesWriter(url: url)
        try w.put(TileID(z: 2, x: 1, y: 0), Data([1, 2, 3]))
        try w.finish(metadata: ["format": "pbf"])
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT tile_row FROM tiles WHERE zoom_level=2 AND tile_column=1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 3, "TMS row = 2^z - 1 - y")
    }
}

@Suite("Gzip")
struct GzipTests {
    @Test func roundTripsThroughFoundation() throws {
        let original = Data(String(repeating: "DayZero offline map tile ", count: 200).utf8)
        let packed = try #require(Gzip.compress(original))
        #expect(packed.prefix(2) == Data([0x1f, 0x8b]))
        #expect(packed.count < original.count / 5)
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }
}

@Suite("Water sources")
struct WaterSourceTests {
    @Test func springsWellsAndTapsAreWaterSources() throws {
        #expect(PlacesWriter.kind(of: ["natural": "spring"]) == .spring)
        #expect(PlacesWriter.kind(of: ["man_made": "water_well", "pump": "manual"]) == .well)
        #expect(PlacesWriter.kind(of: ["man_made": "water_well", "pump": "powered"]) == nil, "powered wells need electricity")
        #expect(PlacesWriter.kind(of: ["man_made": "water_tap"]) == .drinking_water)
        #expect(PlacesWriter.kind(of: ["amenity": "water_point"]) == .water_point)
        #expect([PlaceKind.spring, .well, .water_point, .drinking_water].allSatisfy { $0.layer == .water })

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("water-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let elements: [[String: Any]] = [
            ["type": "node", "id": 1, "lat": 47.6, "lon": -122.3, "tags": ["natural": "spring"]],
            ["type": "node", "id": 2, "lat": 47.61, "lon": -122.31, "tags": ["natural": "spring", "drinking_water": "no", "name": "Iron Spring"]],
        ]
        #expect(try PlacesWriter.write(elements: elements, to: url) == 2)
        let db = PlacesDatabase(path: url.path)
        let springs = db.nearest([.spring], to: .init(latitude: 47.6, longitude: -122.3), limit: 5)
        #expect(springs.first?.name == "Spring")
        #expect(springs.first?.waterNote?.contains("Filter or boil") == true)
        let iron = try #require(springs.first { $0.name.hasPrefix("Iron Spring") })
        #expect(iron.isNotDrinkable)
        #expect(MapIcons.name(for: iron) == "dz-water-untreated")
    }
}
