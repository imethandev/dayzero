import SwiftData
import SwiftUI

/// Tab 1: a list of every page that isn't the map or the Control grid.
/// Each row: icon on the left, title and details in the middle, metadata on the right.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query private var members: [HouseholdMember]
    @Query private var notes: [Note]
    @Query private var items: [SupplyItem]
    @Query(filter: #Predicate<EmergencyContact> { !$0.isHidden }) private var contacts: [EmergencyContact]
    @AppStorage(SupplySettings.redKey) private var redBelow = SupplySettings.defaultRed
    @AppStorage(SupplySettings.amberKey) private var amberBelow = SupplySettings.defaultAmber
    @AppStorage(SupplySettings.includeExpiredKey) private var includeExpired = false

    private var summary: SupplySummary {
        DaysRemainingCalculator.summarize(items: items, members: members, includeExpired: includeExpired)
    }

    var body: some View {
        @Bindable var router = router
        let s = summary
        NavigationStack(path: $router.homePath) {
            List {
                Section {
                    HomeRow(page: .emergency,
                            detail: "Call 911, contacts, nearest hospitals, fire & police",
                            meta: "\(contacts.count)", metaCaption: "contacts")
                }

                Section("Supplies") {
                    HomeRow(page: .water, detail: waterDetail(s),
                            meta: daysMeta(s.daysOfWater, s), metaCaption: daysCaption(s.daysOfWater, s),
                            metaColor: level(s.daysOfWater, s))
                    HomeRow(page: .food, detail: foodDetail(s),
                            meta: daysMeta(s.daysOfFood, s), metaCaption: daysCaption(s.daysOfFood, s),
                            metaColor: level(s.daysOfFood, s))
                    checklistRow(.babyFood, "Formula, baby food, snacks") { $0.kind == .food && $0.foodGroup == .baby }
                    checklistRow(.petFood, "Dog, cat and other pet food") { $0.kind == .food && $0.foodGroup == .pet }
                }

                Section("Tools") {
                    toolRow(.powerTools, .power, "Lights, batteries, radio, charging")
                    toolRow(.waterTools, .water, "Filters, purification, storage")
                    toolRow(.sanitationTools, .sanitation, "Toilet, hygiene, cleaning, waste")
                    toolRow(.survivalTools, .survival, "First aid, shelter, fire, navigation")
                }

                Section("Household") {
                    HomeRow(page: .household, detail: householdDetail,
                            meta: "\(members.count)", metaCaption: members.count == 1 ? "person" : "people")
                    HomeRow(page: .notes, detail: notesDetail,
                            meta: "\(notes.count)", metaCaption: notes.count == 1 ? "note" : "notes")
                }

                Section {
                    HomeRow(page: .settings, detail: "Backup, print, reminders, about",
                            meta: version, metaCaption: "version")
                }
            }
            .navigationTitle("DayZero")
            .navigationDestination(for: HomePage.self) { page in
                switch page {
                case .emergency: EmergencyView()
                case .water: SuppliesView(kinds: [.water])
                case .food: SuppliesView(kinds: [.food], foodGroup: .regular)
                case .babyFood: SuppliesView(kinds: [.food], foodGroup: .baby)
                case .petFood: SuppliesView(kinds: [.food], foodGroup: .pet)
                case .powerTools: SuppliesView(kinds: [.tool], toolGroup: .power)
                case .waterTools: SuppliesView(kinds: [.tool], toolGroup: .water)
                case .sanitationTools: SuppliesView(kinds: [.tool], toolGroup: .sanitation)
                case .survivalTools: SuppliesView(kinds: [.tool], toolGroup: .survival)
                case .household: HouseholdView()
                case .notes: NotesView()
                case .settings: DiagnosticsView()
                }
            }
        }
    }

    private func toolRow(_ page: HomePage, _ group: ToolGroup, _ detail: String) -> some View {
        checklistRow(page, detail) { $0.kind == .tool && $0.toolGroup == group }
    }

    private func checklistRow(_ page: HomePage, _ detail: String, _ belongs: (SupplyItem) -> Bool) -> some View {
        let ofGroup = items.filter { !$0.isHidden && belongs($0) }
        let stocked = ofGroup.filter { $0.quantity > 0 }.count
        return HomeRow(page: page, detail: detail, meta: "\(stocked)/\(ofGroup.count)", metaCaption: "stocked")
    }

    // MARK: Row text

    private func waterDetail(_ s: SupplySummary) -> String {
        s.activeMembers == 0 ? "Add your household to count days"
            : "\(s.totalGallons.formatted(.number.precision(.fractionLength(0...1)))) gal stored"
    }

    private func foodDetail(_ s: SupplySummary) -> String {
        s.activeMembers == 0 ? "Add your household to count days"
            : "\(Int(s.totalCalories).formatted()) calories stored"
    }

    private func daysMeta(_ days: Double?, _ s: SupplySummary) -> String {
        guard s.activeMembers > 0, let days else { return "—" }
        return "\(DaysRemainingCalculator.wholeDays(days))"
    }

    private func daysCaption(_ days: Double?, _ s: SupplySummary) -> String {
        guard s.activeMembers > 0, let days else { return "days" }
        return DaysRemainingCalculator.wholeDays(days) == 1 ? "day" : "days"
    }

    private func level(_ days: Double?, _ s: SupplySummary) -> Color? {
        guard s.activeMembers > 0, let days else { return nil }
        return SupplyLevel(days: days, redBelow: redBelow, amberBelow: amberBelow).color
    }

    private var householdDetail: String {
        if members.isEmpty { return "Add the people your supplies cover" }
        let active = members.filter(\.isActive).count
        return active == members.count ? "All active" : "\(active) active, \(members.count - active) away"
    }

    private var notesDetail: String {
        let pinned = notes.filter(\.isPinned).count
        return pinned > 0 ? "\(pinned) pinned" : "Plans, meeting points, instructions"
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

extension HomePage {
    var title: String {
        switch self {
        case .emergency: "Emergency"
        case .water: "Water"
        case .food: "Food"
        case .babyFood: "Baby Food"
        case .petFood: "Pet Food"
        case .powerTools: "Power Tools"
        case .waterTools: "Water Tools"
        case .sanitationTools: "Sanitation"
        case .survivalTools: "Survival Tools"
        case .household: "Household"
        case .notes: "Notes"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .emergency: "cross.case.fill"
        case .water: "drop.fill"
        case .food: "fork.knife"
        case .babyFood: "stroller.fill"
        case .petFood: "pawprint.fill"
        case .powerTools: "bolt.fill"
        case .waterTools: "spigot.fill"
        case .sanitationTools: "hands.and.sparkles.fill"
        case .survivalTools: "tent.fill"
        case .household: "person.3.fill"
        case .notes: "note.text"
        case .settings: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .emergency: .red
        case .water: .cyan
        case .food: .green
        case .babyFood: .pink
        case .petFood: .orange
        case .powerTools: .yellow
        case .waterTools: .teal
        case .sanitationTools: .purple
        case .survivalTools: .brown
        case .household: .blue
        case .notes: .indigo
        case .settings: .gray
        }
    }
}

private struct HomeRow: View {
    let page: HomePage
    let detail: String
    let meta: String
    let metaCaption: String
    var metaColor: Color? = nil

    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(page.tint, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(meta)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(metaColor ?? .primary)
                    Text(metaCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(detail). \(meta) \(metaCaption)")
    }
}
