import SwiftData
import SwiftUI
import UserNotifications

@main
struct DayZeroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        NetworkBlocker.install()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared

        do {
            let schema = Schema(DayZeroSchema.models)
            let config = ModelConfiguration("DayZero", schema: schema, allowsSave: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the DayZero store: \(error)")
        }
        Seeder.seedIfNeeded(container.mainContext)
        QuickActionCenter.install()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }
}
