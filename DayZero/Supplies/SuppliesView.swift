import SwiftData
import SwiftUI

enum StockFilter: String, CaseIterable, Identifiable {
    case all = "All", stocked = "Stocked", missing = "Missing"
    var id: String { rawValue }
}

/// Inventory page. Home opens it twice: Supplies (food and water, with days remaining)
/// and Tools (the tool checklist).
struct SuppliesView: View {
    /// Which kinds this page lists. Several kinds get a segmented picker.
    let kinds: [SupplyKind]
    /// For tool pages: which group of tools.
    let toolGroup: ToolGroup?
    /// For food pages: Food, Baby Food or Pet Food.
    let foodGroup: FoodGroup?
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @Query(sort: \SupplyItem.sortOrder) private var allItems: [SupplyItem]
    @Query private var members: [HouseholdMember]

    @AppStorage(SupplySettings.redKey) private var redBelow = SupplySettings.defaultRed
    @AppStorage(SupplySettings.amberKey) private var amberBelow = SupplySettings.defaultAmber
    @AppStorage(SupplySettings.includeExpiredKey) private var includeExpired = false

    @State private var segment: SupplyKind

    init(kinds: [SupplyKind], toolGroup: ToolGroup? = nil, foodGroup: FoodGroup? = nil) {
        self.kinds = kinds
        self.toolGroup = toolGroup
        self.foodGroup = foodGroup
        _segment = State(initialValue: kinds.first ?? .food)
    }

    private var isToolsPage: Bool { kinds == [.tool] }
    /// Baby and pet food pages are checklists like the tool pages; regular food shows days remaining.
    private var isChecklistPage: Bool { isToolsPage || foodGroup == .baby || foodGroup == .pet }
    private var title: String {
        toolGroup?.title ?? foodGroup?.title ?? (kinds.count == 1 ? kinds[0].title : "Supplies")
    }
    @State private var filter: StockFilter = .all
    @State private var search = ""
    @State private var keypadItem: SupplyItem?
    @State private var detailItem: SupplyItem?
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var pendingRemoval: SupplyItem?

    private var summary: SupplySummary {
        DaysRemainingCalculator.summarize(items: allItems, members: members, includeExpired: includeExpired)
    }

    private func matches(_ item: SupplyItem) -> Bool {
        guard !item.isHidden, kinds.contains(item.kind) else { return false }
        if let toolGroup, item.toolGroup != toolGroup { return false }
        if let foodGroup, item.kind == .food, item.foodGroup != foodGroup { return false }
        switch filter {
        case .all: break
        case .stocked: guard item.quantity > 0 else { return false }
        case .missing: guard item.quantity == 0 else { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || item.name.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let summary = summary
        let shown = allItems.filter(matches)

            List {
                Section {
                    Group {
                        if isChecklistPage {
                            let group = allItems.filter { !$0.isHidden && kinds.contains($0.kind)
                                && (toolGroup == nil || $0.toolGroup == toolGroup)
                                && (foodGroup == nil || $0.foodGroup == foodGroup) }
                            ToolsHeader(stocked: group.filter { $0.quantity > 0 }.count, total: group.count,
                                        label: "items", note: checklistNote,
                                        extra: toolGroup == .power ? FuelSummary.line(allItems) : nil)
                        } else {
                            SummaryHeader(summary: summary, kinds: kinds, redBelow: redBelow, amberBelow: amberBelow) {
                                router.open(.household)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if kinds.count > 1 {
                    Section {
                        Picker("Segment", selection: $segment) {
                            ForEach(kinds) { kind in
                                Text("\(kind.title) \(shown.filter { $0.kind == kind }.count)").tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    let rows = shown.filter { $0.kind == segment }
                    if rows.isEmpty {
                        Text(search.isEmpty ? "Nothing here with this filter." : "No matches for “\(search)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { item in
                        SupplyRow(
                            item: item,
                            isExpired: item.isExpired(on: .now),
                            onStep: { step(item, by: $0) },
                            onTapQuantity: { keypadItem = item },
                            onTapName: { detailItem = item }
                        )
                        .swipeActions(edge: .trailing) {
                            Button(item.isBuiltIn ? "Hide" : "Delete", role: .destructive) {
                                pendingRemoval = item
                            }
                        }
                    }
                } header: {
                    let heading = isChecklistPage ? "Items" : segment.title
                    Text(filter == .all ? heading : "\(heading) · \(filter.rawValue)")
                }
            }
            .navigationTitle(title)
            .searchable(text: $search, prompt: "Search \(title.lowercased())")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(StockFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Filter", systemImage: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    Button { showAdd = true } label: { Label("Add item", systemImage: "plus") }
                }
            }
            .sheet(item: $keypadItem) { QuantityKeypadSheet(item: $0) }
            .sheet(item: $detailItem) { SupplyDetailSheet(item: $0) }
            .sheet(isPresented: $showAdd) { AddSupplySheet(defaultKind: segment, defaultToolGroup: toolGroup ?? .survival,
                                                                  defaultFoodGroup: foodGroup ?? .regular) }
            .sheet(isPresented: $showSettings) { SuppliesSettingsView() }
            .confirmationDialog(
                pendingRemoval.map { $0.isBuiltIn ? "Hide “\($0.name)”?" : "Delete “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { item in
                Button(item.isBuiltIn ? "Hide item" : "Delete item", role: .destructive) { remove(item) }
            } message: { item in
                Text(item.isBuiltIn
                     ? "It leaves the list and the totals. You can bring it back with the gear button on this page → Hidden items."
                     : "This removes the item and its quantity for good.")
            }
    }

    private var checklistNote: String {
        switch foodGroup {
        case .baby: "Baby food counts toward days of food on the Food page. Items at 0 show what's still missing."
        case .pet: "Pet food doesn't change the household's days of food. Plan about 2 weeks for each pet."
        default:
            switch toolGroup {
            case .power: "Stored gasoline goes stale in about 3–6 months (diesel 6–12) unless stabilized. Set an expiry date on fuel to get a reminder."
            case .food: "Cook outside only: stoves, grills and charcoal make carbon monoxide. In an outage, a closed fridge keeps food cold about 4 hours and a full freezer about 48."
            case .goBag: "Pack enough for 72 hours and keep the bag by the door or in the car. Go-bag items don't count toward days at home. Check food, water, medicine and batteries every 6 months."
            case .medicine: "Medicines expire, so set expiry dates to get reminders. Keep at least 2 weeks of prescriptions and a printed list of each person's medicines and allergies."
            case .navigation: "Phones and GPS can fail. Mark two evacuation routes and your meeting places on a paper map, and practice with the compass."
            case .security: "Test smoke detectors monthly. Keep documents and some small bills in a fireproof, waterproof place, since cards and ATMs may not work in an outage."
            case .firstAid: "Check kits twice a year and replace anything used or expired. A first aid or Stop the Bleed class makes this gear far more useful."
            case .shelter: "If the heat goes out, gather everyone in one small room and cover the windows. Never use grills, camp stoves or generators indoors, and run an indoor heater only with a CO detector."
            case .communication: "GMRS needs an FCC license (no exam) and ham radio needs an amateur license. FRS, CB, Meshtastic and listening need none. Write your family's channels on a printed card."
            default: "Tools don't change days of food and water. Items at 0 show what's still missing."
            }
        }
    }

    private func step(_ item: SupplyItem, by delta: Double) {
        item.quantity = max(0, item.quantity + delta)
        item.updatedAt = .now
        try? context.save()
    }

    private func remove(_ item: SupplyItem) {
        if item.isBuiltIn {
            item.isHidden = true
            item.updatedAt = .now
        } else {
            context.delete(item)
        }
        try? context.save()
    }
}

// MARK: - Summary

/// Fuel on hand for the Power and Fuels header, from the catalog's fuel items.
enum FuelSummary {
    static let fuels: [(key: String, label: String)] = [
        ("tool.fuel_gasoline", "gasoline"), ("tool.fuel_diesel", "diesel"),
        ("tool.fuel_propane_20lb", "propane"), ("tool.fuel_kerosene", "kerosene"),
    ]

    /// e.g. "Fuel: 10 gal gasoline · 2 tanks propane", or nil when none is stocked.
    static func line(_ items: [SupplyItem]) -> String? {
        let parts: [String] = fuels.compactMap { fuel in
            guard let item = items.first(where: { $0.catalogKey == fuel.key && !$0.isHidden }), item.quantity > 0 else { return nil }
            let q = item.quantity.formatted(.number.precision(.fractionLength(0...1)))
            let unit = item.unit == "gallon" ? "gal" : (item.quantity == 1 ? item.unit : item.unit + "s")
            return "\(q) \(unit) \(fuel.label)"
        }
        return parts.isEmpty ? nil : "Fuel: " + parts.joined(separator: " · ")
    }
}

private struct ToolsHeader: View {
    let stocked: Int
    let total: Int
    var label = "tools"
    var note = "Tools don't change days of food and water. Items at 0 show what's still missing."
    /// Optional highlighted line, e.g. fuel on hand.
    var extra: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stocked)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text("of \(total) \(label) stocked").font(.headline)
            }
            ProgressView(value: Double(stocked), total: Double(max(total, 1)))
                .tint(stocked == total && total > 0 ? .green : .orange)
            if let extra {
                Label(extra, systemImage: "fuelpump.fill")
                    .font(.subheadline.weight(.semibold))
            }
            Text(note)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryHeader: View {
    let summary: SupplySummary
    /// The page's kinds; only their days cards are shown.
    let kinds: [SupplyKind]
    let redBelow: Double
    let amberBelow: Double
    let addMember: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if summary.activeMembers == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Add your household", systemImage: "person.badge.plus")
                        .font(.headline)
                    Text("Days of food and water are counted for the active members in Home → Household.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Add a member", action: addMember)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            } else {
                HStack(spacing: 10) {
                    if kinds.contains(.water) {
                        DaysCard(title: "Days of water", systemImage: "drop.fill", days: summary.daysOfWater,
                                 detail: "\(fmt(summary.totalGallons)) gal for \(people) · \(fmt(summary.dailyGallonsNeeded)) gal/day",
                                 redBelow: redBelow, amberBelow: amberBelow)
                    }
                    if kinds.contains(.food) {
                        DaysCard(title: "Days of food", systemImage: "fork.knife", days: summary.daysOfFood,
                                 detail: "\(Int(summary.totalCalories).formatted()) cal for \(people) · \(Int(summary.dailyCaloriesNeeded).formatted()) cal/day",
                                 redBelow: redBelow, amberBelow: amberBelow)
                    }
                }
            }
        }
    }

    private var people: String {
        summary.activeMembers == 1 ? "1 person" : "\(summary.activeMembers) people"
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }
}

private struct DaysCard: View {
    let title: String
    let systemImage: String
    let days: Double?
    let detail: String
    let redBelow: Double
    let amberBelow: Double

    var body: some View {
        let whole = days.map(DaysRemainingCalculator.wholeDays) ?? 0
        let level = SupplyLevel(days: days ?? 0, redBelow: redBelow, amberBelow: amberBelow)
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(level.color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(whole)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(whole == 1 ? "day" : "days").font(.headline)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(level.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(level.color.opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(whole) \(whole == 1 ? "day" : "days") remaining, \(level.label). \(detail)")
    }
}

// MARK: - Row

private struct SupplyRow: View {
    let item: SupplyItem
    let isExpired: Bool
    let onStep: (Double) -> Void
    let onTapQuantity: () -> Void
    let onTapName: () -> Void

    var body: some View {
        let stocked = item.quantity > 0
        HStack(spacing: 10) {
            Button(action: onTapName) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(stocked ? item.unit : "Not stocked · \(item.unit)")
                        if isExpired {
                            Text("Expired").foregroundStyle(.red).fontWeight(.semibold)
                        } else if let exp = item.expiresOn {
                            Text("Exp \(exp.formatted(.dateTime.month(.abbreviated).year()))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(stocked ? 1 : 0.5)
            .accessibilityHint("Edit details")

            Button { onStep(-1) } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!stocked)
            .accessibilityLabel("Remove one \(item.name)")

            Button(action: onTapQuantity) {
                Text(item.quantity.formatted(.number.precision(.fractionLength(0...2))))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44)
                    .foregroundStyle(stocked ? Color.primary : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Quantity \(item.quantity.formatted()), tap to type")

            Button { onStep(1) } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add one \(item.name)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Keypad

struct QuantityKeypadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let item: SupplyItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Quantity", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .focused($focused)
                } header: {
                    Text(item.name)
                } footer: {
                    Text("Unit: \(item.unit)")
                }
            }
            .navigationTitle("How many?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(parsed == nil)
                }
            }
            .onAppear {
                text = item.quantity == 0 ? "" : item.quantity.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var parsed: Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        guard let v = Double(t.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")), v >= 0 else { return nil }
        return v
    }

    private func save() {
        guard let v = parsed else { return }
        item.quantity = v
        item.updatedAt = .now
        try? context.save()
        dismiss()
    }
}
