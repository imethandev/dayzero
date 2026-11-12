import Foundation
import Testing
@testable import DayZero

private struct Stock: SupplyStock {
    var kind: SupplyKind
    var quantity: Double
    var caloriesPerUnit: Double = 0
    var gallonsPerUnit: Double = 0
    var expiresOn: Date? = nil
    var isHidden = false
    var isBuiltIn = true
    var foodGroup: FoodGroup = .regular

    static func water(_ qty: Double, gallonsEach: Double = 1, expires: Date? = nil) -> Stock {
        Stock(kind: .water, quantity: qty, gallonsPerUnit: gallonsEach, expiresOn: expires)
    }
    static func food(_ qty: Double, caloriesEach: Double, expires: Date? = nil) -> Stock {
        Stock(kind: .food, quantity: qty, caloriesPerUnit: caloriesEach, expiresOn: expires)
    }
    static func tool(_ qty: Double, builtIn: Bool = true) -> Stock {
        Stock(kind: .tool, quantity: qty, isBuiltIn: builtIn)
    }
}

private struct Person: HouseholdNeed {
    var dailyCalories = 2_000.0
    var dailyWaterGallons = 1.0
    var isActive = true
}

private let calendar = Calendar(identifier: .gregorian)
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
private let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
private let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!

private func summarize(_ items: [Stock], _ members: [Person], includeExpired: Bool = false) -> SupplySummary {
    DaysRemainingCalculator.summarize(items: items, members: members, includeExpired: includeExpired,
                                      now: now, calendar: calendar)
}

@Suite("Days remaining")
struct DaysRemainingTests {
    // Spec acceptance: 4 active members at 1 gallon each and 40 gallons in stock → 10 days of water.
    @Test func fortyGallonsFourPeopleIsTenDays() {
        let s = summarize([.water(40)], Array(repeating: Person(), count: 4))
        #expect(s.daysOfWater == 10)
        #expect(DaysRemainingCalculator.wholeDays(s.daysOfWater!) == 10)
    }

    // Spec acceptance: plus on "1 gallon jug" four times with 4 active members → 0 to 1 day.
    @Test func fourJugsFourPeopleGoesFromZeroToOne() {
        let people = Array(repeating: Person(), count: 4)
        #expect(summarize([.water(0)], people).daysOfWater == 0)
        let s = summarize([.water(4)], people)
        #expect(DaysRemainingCalculator.wholeDays(s.daysOfWater!) == 1)
    }

    // Spec acceptance: setting a member inactive changes both figures.
    @Test func inactiveMemberIsExcludedFromBothFigures() {
        let items: [Stock] = [.water(12), .food(10, caloriesEach: 1_600)]
        let all = summarize(items, [Person(), Person(), Person()])
        let oneAway = summarize(items, [Person(), Person(), Person(isActive: false)])
        #expect(all.daysOfWater == 4)
        #expect(oneAway.daysOfWater == 6)
        #expect(all.daysOfFood! < oneAway.daysOfFood!)
        #expect(oneAway.activeMembers == 2)
    }

    // Spec acceptance: expired items are left out until the include toggle is on.
    @Test func expiredItemsExcludedUnlessToggled() {
        let items: [Stock] = [.water(10), .water(10, expires: yesterday), .food(5, caloriesEach: 2_000, expires: yesterday)]
        let people = [Person()]
        let excluded = summarize(items, people)
        #expect(excluded.daysOfWater == 10)
        #expect(excluded.daysOfFood == 0)
        let included = summarize(items, people, includeExpired: true)
        #expect(included.daysOfWater == 20)
        #expect(included.daysOfFood == 5)
    }

    @Test func itemExpiringTodayOrLaterStillCounts() {
        let items: [Stock] = [.water(5, expires: now), .water(5, expires: tomorrow)]
        #expect(summarize(items, [Person()]).daysOfWater == 10)
    }

    @Test func noActiveMembersGivesNoFigure() {
        #expect(summarize([.water(40)], []).daysOfWater == nil)
        #expect(summarize([.water(40)], [Person(isActive: false)]).daysOfFood == nil)
    }

    @Test func customDailyNeedsAreUsed() {
        let s = summarize([.water(30), .food(10, caloriesEach: 3_000)],
                          [Person(dailyCalories: 3_000, dailyWaterGallons: 1.5), Person(dailyCalories: 1_500, dailyWaterGallons: 0.5)])
        #expect(s.daysOfWater == 15)
        #expect(s.dailyCaloriesNeeded == 4_500)
        #expect(abs(s.daysOfFood! - 30_000.0 / 4_500.0) < 1e-9)
    }

    @Test func unitSizesMultiply() {
        // Two 5-gallon containers and one case of bottles (3.17 gal).
        let s = summarize([.water(2, gallonsEach: 5), .water(1, gallonsEach: 3.17)], [Person()])
        #expect(abs(s.totalGallons - 13.17) < 1e-9)
    }

    @Test func toolsDoNotAffectDaysButAreCounted() {
        let items: [Stock] = [.water(4), .tool(3), .tool(0), .tool(1, builtIn: false)]
        let s = summarize(items, [Person()])
        #expect(s.daysOfWater == 4)
        #expect(s.toolsStocked == 1)
        #expect(s.toolsInCatalog == 2)
    }

    @Test func hiddenItemsAreIgnored() {
        var hidden = Stock.water(100)
        hidden.isHidden = true
        var hiddenTool = Stock.tool(1)
        hiddenTool.isHidden = true
        let s = summarize([.water(2), hidden, hiddenTool], [Person()])
        #expect(s.daysOfWater == 2)
        #expect(s.toolsInCatalog == 0)
    }

    @Test func wholeDaysRoundsDownAndToleratesFloatError() {
        #expect(DaysRemainingCalculator.wholeDays(0.99) == 0)
        #expect(DaysRemainingCalculator.wholeDays(3.9999999999999) == 4)
        #expect(DaysRemainingCalculator.wholeDays(13.7) == 13)
        #expect(DaysRemainingCalculator.wholeDays(-1) == 0)
    }

    @Test(arguments: [(0.0, SupplyLevel.red), (2.9, .red), (3, .amber), (13.9, .amber), (14, .green), (60, .green)])
    func levelThresholds(days: Double, expected: SupplyLevel) {
        #expect(SupplyLevel(days: days, redBelow: 3, amberBelow: 14) == expected)
    }
}
