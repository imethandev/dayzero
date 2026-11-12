import Foundation
import SwiftUI

// MARK: - Inputs (protocols so the SwiftData models and plain test values both work)

protocol SupplyStock {
    var kind: SupplyKind { get }
    var foodGroup: FoodGroup { get }
    var quantity: Double { get }
    var caloriesPerUnit: Double { get }
    var gallonsPerUnit: Double { get }
    var expiresOn: Date? { get }
    var isHidden: Bool { get }
    var isBuiltIn: Bool { get }
}

protocol HouseholdNeed {
    var dailyCalories: Double { get }
    var dailyWaterGallons: Double { get }
    var isActive: Bool { get }
}

extension SupplyItem: SupplyStock {}
extension HouseholdMember: HouseholdNeed {}

extension SupplyStock {
    /// An item is expired once its expiry day has passed (it still counts on the expiry day itself).
    func isExpired(on now: Date, calendar: Calendar = .current) -> Bool {
        guard let expiresOn else { return false }
        return calendar.startOfDay(for: expiresOn) < calendar.startOfDay(for: now)
    }
}

// MARK: - Result

struct SupplySummary: Equatable {
    var totalGallons: Double
    var totalCalories: Double
    var dailyGallonsNeeded: Double
    var dailyCaloriesNeeded: Double
    var activeMembers: Int
    var toolsStocked: Int
    var toolsInCatalog: Int

    /// Nil when there are no active members (the UI prompts to add one instead).
    var daysOfWater: Double? {
        guard activeMembers > 0, dailyGallonsNeeded > 0 else { return nil }
        return totalGallons / dailyGallonsNeeded
    }

    var daysOfFood: Double? {
        guard activeMembers > 0, dailyCaloriesNeeded > 0 else { return nil }
        return totalCalories / dailyCaloriesNeeded
    }
}

enum DaysRemainingCalculator {
    static func summarize(
        items: [any SupplyStock],
        members: [any HouseholdNeed],
        includeExpired: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> SupplySummary {
        var gallons = 0.0
        var calories = 0.0
        var toolsStocked = 0
        var toolsInCatalog = 0

        for item in items where !item.isHidden {
            switch item.kind {
            case .tool:
                if item.isBuiltIn {
                    toolsInCatalog += 1
                    if item.quantity > 0 { toolsStocked += 1 }
                }
            case .water, .food:
                guard item.quantity > 0 else { continue }
                if !includeExpired && item.isExpired(on: now, calendar: calendar) { continue }
                if item.kind == .food && !item.foodGroup.feedsHousehold { continue }
                if item.kind == .water {
                    gallons += item.quantity * item.gallonsPerUnit
                } else {
                    calories += item.quantity * item.caloriesPerUnit
                }
            }
        }

        let active = members.filter(\.isActive)
        return SupplySummary(
            totalGallons: gallons,
            totalCalories: calories,
            dailyGallonsNeeded: active.reduce(0) { $0 + $1.dailyWaterGallons },
            dailyCaloriesNeeded: active.reduce(0) { $0 + $1.dailyCalories },
            activeMembers: active.count,
            toolsStocked: toolsStocked,
            toolsInCatalog: toolsInCatalog
        )
    }

    /// Whole days shown to the user. Rounds down (a partial day is not a day of supply);
    /// the epsilon keeps 3.9999999 from floating-point sums reading as 3.
    static func wholeDays(_ days: Double) -> Int {
        max(0, Int((days + 1e-9).rounded(.down)))
    }
}

// MARK: - Color state

enum SupplyLevel: Equatable {
    case red, amber, green

    init(days: Double, redBelow: Double, amberBelow: Double) {
        let whole = Double(DaysRemainingCalculator.wholeDays(days))
        if whole < redBelow { self = .red }
        else if whole < amberBelow { self = .amber }
        else { self = .green }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .amber: .orange
        case .green: .green
        }
    }

    var label: String {
        switch self {
        case .red: "Critical"
        case .amber: "Low"
        case .green: "Good"
        }
    }
}

// MARK: - Settings keys

enum SupplySettings {
    static let redKey = "supplies.redThresholdDays"
    static let amberKey = "supplies.amberThresholdDays"
    static let includeExpiredKey = "supplies.includeExpired"
    static let defaultRed = 3.0
    static let defaultAmber = 14.0
}
