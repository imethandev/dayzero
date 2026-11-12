import Foundation
import OSLog
import SwiftData
import SwiftUI
import UserNotifications

/// Local notifications only — no server. Expiry reminders 30 and 7 days ahead,
/// and an alert when days of water or food drop below the red threshold.
enum Reminders {
    static let expiryPrefix = "expiry-"
    static let offsets = [30, 7]
    /// iOS keeps at most 64 pending local notifications per app; leave room for others.
    static let maxPending = 60
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "reminders")

    struct ExpiringItem: Sendable, Hashable {
        let id: UUID
        let name: String
        let quantity: Double
        let unit: String
        let storageLocation: String
        let expiresOn: Date
    }

    struct Planned: Sendable, Equatable {
        let identifier: String
        let fireDate: Date
        let title: String
        let body: String
    }

    /// Pure planning step (unit-tested): which expiry notifications should exist right now.
    static func plan(_ items: [ExpiringItem], now: Date = .now, calendar: Calendar = .current) -> [Planned] {
        var out: [Planned] = []
        for item in items {
            for days in offsets {
                guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: item.expiresOn)),
                      let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      fire > now else { continue }
                let qty = item.quantity.formatted(.number.precision(.fractionLength(0...2)))
                var body = "\(qty) \(item.unit) expires \(item.expiresOn.formatted(date: .abbreviated, time: .omitted))."
                if !item.storageLocation.isEmpty { body += " Stored: \(item.storageLocation)." }
                out.append(Planned(
                    identifier: "\(expiryPrefix)\(item.id.uuidString)-\(days)",
                    fireDate: fire,
                    title: "\(item.name) expires in \(days) days",
                    body: body
                ))
            }
        }
        return Array(out.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending))
    }

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func rescheduleExpiry(_ items: [ExpiringItem]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(expiryPrefix) })
        let planned = plan(items)
        guard !planned.isEmpty, await requestAuthorization() else { return }
        for p in planned {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.fireDate)
            let request = UNNotificationRequest(identifier: p.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(request)
        }
        log.info("Scheduled \(planned.count) expiry reminders")
    }

    static func notifyNow(id: String, title: String, body: String, after seconds: TimeInterval = 1) async {
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }
}

/// Shows reminders as banners even while DayZero is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Lives at the root so reminders stay current whichever tab changed the data.
struct SupplyMonitor: ViewModifier {
    @Query private var items: [SupplyItem]
    @Query private var members: [HouseholdMember]
    @AppStorage(SupplySettings.redKey) private var redBelow = SupplySettings.defaultRed
    @AppStorage(SupplySettings.includeExpiredKey) private var includeExpired = false

    private var expiring: [Reminders.ExpiringItem] {
        items.compactMap { i in
            guard let e = i.expiresOn, i.quantity > 0, !i.isHidden else { return nil }
            return .init(id: i.id, name: i.name, quantity: i.quantity, unit: i.unit, storageLocation: i.storageLocation, expiresOn: e)
        }
    }

    private var summary: SupplySummary {
        DaysRemainingCalculator.summarize(items: items, members: members, includeExpired: includeExpired)
    }

    func body(content: Content) -> some View {
        let s = summary
        let waterLow = s.daysOfWater.map { Double(DaysRemainingCalculator.wholeDays($0)) < redBelow }
        let foodLow = s.daysOfFood.map { Double(DaysRemainingCalculator.wholeDays($0)) < redBelow }
        content
            .task(id: expiring) { await Reminders.rescheduleExpiry(expiring) }
            .onChange(of: waterLow, initial: true) { _, low in
                LowSupplyAlert.update(kind: "water", isLow: low, days: s.daysOfWater, people: s.activeMembers)
            }
            .onChange(of: foodLow, initial: true) { _, low in
                LowSupplyAlert.update(kind: "food", isLow: low, days: s.daysOfFood, people: s.activeMembers)
            }
    }
}

/// Fires once when a figure crosses from at-or-above the red threshold to below it.
/// The first observation only records the state, so opening the app never alerts by itself.
enum LowSupplyAlert {
    static func update(kind: String, isLow: Bool?, days: Double?, people: Int) {
        let key = "lowSupply.\(kind).state"
        let defaults = UserDefaults.standard
        guard let isLow else {
            defaults.removeObject(forKey: key) // no active members: forget the state
            return
        }
        let previous = defaults.object(forKey: key) as? Bool
        defaults.set(isLow, forKey: key)
        guard previous == false, isLow, let days else { return }
        let whole = DaysRemainingCalculator.wholeDays(days)
        Task {
            await Reminders.notifyNow(
                id: "low-\(kind)",
                title: "\(kind == "water" ? "Water" : "Food") is low",
                body: "\(whole) \(whole == 1 ? "day" : "days") of \(kind) left for \(people) \(people == 1 ? "person" : "people")."
            )
        }
    }
}
