import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import DayZero

@Suite("Places search")
struct PlacesSearchTests {
    let db = PlacesDatabase.shared
    let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)

    @Test func databaseIsBundled() {
        #expect(db.isAvailable)
    }

    // Spec acceptance: searching "hospital" returns results sorted by distance, with no network.
    @Test func hospitalSearchIsSortedByDistance() throws {
        let results = db.search("hospital", near: seattle)
        try #require(results.count >= 5)
        let here = CLLocation(latitude: seattle.latitude, longitude: seattle.longitude)
        let distances = results.map { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
        #expect(distances == distances.sorted())
        #expect(results.contains { $0.kind == .hospital })
        #expect(distances[0] < 5_000, "a hospital within 5 km of downtown Seattle")
    }

    @Test func prefixSearchFindsTowns() {
        let results = db.search("spoka", near: nil)
        #expect(results.contains { $0.name == "Spokane" && $0.kind == .city })
    }

    @Test func nearestReturnsOnlyRequestedKinds() {
        let fire = db.nearest([.fire_station], to: seattle, limit: 3)
        #expect(fire.count == 3)
        #expect(fire.allSatisfy { $0.kind == .fire_station })
    }

    @Test func punctuationDoesNotBreakFTS() {
        _ = db.search("st. joseph's \"hospital\" (*)", near: seattle)
        #expect(db.search("   ", near: seattle).isEmpty)
    }

    @Test func facilitiesAllHaveALayer() {
        let all = db.allFacilities()
        #expect(all.count > 5_000)
        #expect(all.allSatisfy { $0.kind.layer != nil })
    }
}

@Suite("Bearing")
struct BearingTests {
    let origin = CLLocationCoordinate2D(latitude: 47.0, longitude: -122.0)

    @Test func cardinalDirections() {
        #expect(Bearing.cardinal(from: origin, toLatitude: 48.0, longitude: -122.0).hasSuffix(" N"))
        #expect(Bearing.cardinal(from: origin, toLatitude: 47.0, longitude: -121.0).hasSuffix(" E"))
        #expect(Bearing.cardinal(from: origin, toLatitude: 46.0, longitude: -122.0).hasSuffix(" S"))
        #expect(Bearing.cardinal(from: origin, toLatitude: 47.0, longitude: -123.0).hasSuffix(" W"))
        #expect(Bearing.cardinal(from: origin, toLatitude: 47.7, longitude: -121.0).hasSuffix(" NE"))
    }
}

@Suite("Reminders")
struct ReminderPlanTests {
    let calendar = Calendar(identifier: .gregorian)
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))! }

    func item(expiringInDays days: Int) -> Reminders.ExpiringItem {
        .init(id: UUID(), name: "White rice", quantity: 10, unit: "lb", storageLocation: "Garage",
              expiresOn: calendar.date(byAdding: .day, value: days, to: now)!)
    }

    @Test func schedulesThirtyAndSevenDaysAheadAtNine() {
        let plan = Reminders.plan([item(expiringInDays: 60)], now: now, calendar: calendar)
        #expect(plan.count == 2)
        let comps = plan.map { calendar.dateComponents([.month, .day, .hour], from: $0.fireDate) }
        #expect(comps[0].hour == 9)
        #expect(plan[0].title.contains("30 days"))
        #expect(plan[1].title.contains("7 days"))
        #expect(plan[0].body.contains("Garage"))
    }

    @Test func skipsReminderTimesAlreadyPassed() {
        let plan = Reminders.plan([item(expiringInDays: 10)], now: now, calendar: calendar)
        #expect(plan.count == 1)
        #expect(plan[0].title.contains("7 days"))
        #expect(Reminders.plan([item(expiringInDays: 3)], now: now, calendar: calendar).isEmpty)
    }

    @Test func capsAtSystemLimitKeepingSoonest() {
        let many = (0..<50).map { item(expiringInDays: 40 + $0) }
        let plan = Reminders.plan(many, now: now, calendar: calendar)
        #expect(plan.count == Reminders.maxPending)
        #expect(plan == plan.sorted { $0.fireDate < $1.fireDate })
    }
}

@Suite("Backup")
@MainActor
struct BackupTests {
    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(DayZeroSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        Seeder.seedIfNeeded(ctx)
        return ctx
    }

    // Spec acceptance: export, delete the app, reinstall, import → everything returns.
    @Test func exportThenRestoreIntoFreshStoreRoundTrips() throws {
        let source = try makeContext()
        let alice = HouseholdMember(name: "Alice", birthYear: 1990, relationship: "self", dailyCalories: 2200)
        source.insert(alice)
        let away = HouseholdMember(name: "Bob", isActive: false)
        source.insert(away)
        let note = Note(title: "Meeting point", body: "Library steps", member: alice, isPinned: true)
        source.insert(note)
        let jug = try #require(try source.fetch(FetchDescriptor<SupplyItem>()).first { $0.catalogKey == "water.jug_1gal" })
        jug.quantity = 4
        jug.expiresOn = Date(timeIntervalSince1970: 1_900_000_000)
        source.insert(SupplyItem(name: "Dog treats", kind: .food, quantity: 2, unit: "bag", caloriesPerUnit: 0))
        source.insert(EmergencyContact(name: "Dr. Smith", category: .medical, phone: "360-555-0100", latitude: 47.1, longitude: -122.9))
        let poison = try #require(try source.fetch(FetchDescriptor<EmergencyContact>()).first { $0.seedKey == "poison.national" })
        poison.isFavorite = true
        source.insert(MapPin(title: "Cache A", kind: .cache, latitude: 47.5, longitude: -121.9, notes: "Under the cedar"))
        try source.save()

        let data = try Backup.encoder().encode(try Backup.make(from: source))
        let decoded = try Backup.decoder().decode(BackupFile.self, from: data)

        let fresh = try makeContext() // simulates a reinstall: seeded, no user data
        try Backup.restore(decoded, into: fresh)

        let members = try fresh.fetch(FetchDescriptor<HouseholdMember>())
        #expect(Set(members.map(\.name)) == ["Alice", "Bob"])
        #expect(members.first { $0.name == "Bob" }?.isActive == false)
        #expect(members.first { $0.name == "Alice" }?.dailyCalories == 2200)

        let notes = try fresh.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.member?.name == "Alice")
        #expect(notes.first?.isPinned == true)

        let supplies = try fresh.fetch(FetchDescriptor<SupplyItem>())
        #expect(supplies.first { $0.catalogKey == "water.jug_1gal" }?.quantity == 4)
        #expect(supplies.first { $0.catalogKey == "water.jug_1gal" }?.expiresOn == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(supplies.contains { $0.name == "Dog treats" })
        #expect(supplies.filter { $0.catalogKey == "water.jug_1gal" }.count == 1, "no duplicate catalog items after restore")

        let contacts = try fresh.fetch(FetchDescriptor<EmergencyContact>())
        #expect(contacts.contains { $0.name == "Dr. Smith" && $0.latitude == 47.1 })
        #expect(contacts.first { $0.seedKey == "poison.national" }?.isFavorite == true)
        #expect(contacts.filter { $0.seedKey == "poison.national" }.count == 1)

        let pins = try fresh.fetch(FetchDescriptor<MapPin>())
        #expect(pins.count == 1)
        #expect(pins.first?.notes == "Under the cedar")
    }

    @Test func rejectsFilesFromOtherApps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-dayzero.json")
        try #"{"app":"Other","formatVersion":1,"exportedAt":"2026-11-11T00:00:00Z","supplies":[],"members":[],"notes":[],"contacts":[],"pins":[]}"#
            .data(using: .utf8)!.write(to: url)
        #expect(throws: (any Error).self) { try Backup.read(url) }
    }

    @Test func printableSheetIsAPDF() throws {
        let ctx = try makeContext()
        ctx.insert(HouseholdMember(name: "Alice"))
        try ctx.save()
        let url = try PrintableReport.make(from: ctx, includeExpired: false)
        let head = try Data(contentsOf: url).prefix(5)
        #expect(String(data: head, encoding: .ascii) == "%PDF-")
    }
}
