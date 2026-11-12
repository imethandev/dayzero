import SwiftData
import SwiftUI

/// Editable copy of a supply item, so Cancel discards changes.
struct SupplyDraft {
    var name = ""
    var kind: SupplyKind = .food
    var unit = ""
    var quantity = 0.0
    var caloriesPerUnit = 0.0
    var gallonsPerUnit = 0.0
    var hasExpiry = false
    var expiresOn = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    var storageLocation = ""
    var notes = ""
    var toolGroup: ToolGroup = .survival
    var foodGroup: FoodGroup = .regular

    init(kind: SupplyKind = .food, toolGroup: ToolGroup = .survival, foodGroup: FoodGroup = .regular) {
        self.kind = kind
        self.toolGroup = toolGroup
        self.foodGroup = foodGroup
    }

    init(_ item: SupplyItem) {
        name = item.name
        kind = item.kind
        unit = item.unit
        quantity = item.quantity
        caloriesPerUnit = item.caloriesPerUnit
        gallonsPerUnit = item.gallonsPerUnit
        hasExpiry = item.expiresOn != nil
        if let e = item.expiresOn { expiresOn = e }
        storageLocation = item.storageLocation
        notes = item.notes
        toolGroup = item.toolGroup
        foodGroup = item.foodGroup
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !unit.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func apply(to item: SupplyItem) {
        item.name = name.trimmingCharacters(in: .whitespaces)
        item.kind = kind
        item.unit = unit.trimmingCharacters(in: .whitespaces)
        item.quantity = max(0, quantity)
        item.caloriesPerUnit = kind == .food && foodGroup.feedsHousehold ? max(0, caloriesPerUnit) : 0
        item.gallonsPerUnit = kind == .water ? max(0, gallonsPerUnit) : 0
        item.expiresOn = hasExpiry ? expiresOn : nil
        item.storageLocation = storageLocation
        item.notes = notes
        item.toolGroupRaw = kind == .tool ? toolGroup.rawValue : nil
        item.foodGroupRaw = kind == .food ? foodGroup.rawValue : nil
        item.updatedAt = .now
    }
}

private struct SupplyFields: View {
    @Binding var draft: SupplyDraft
    let isBuiltIn: Bool

    var body: some View {
        Section("Item") {
            if isBuiltIn {
                LabeledContent("Name", value: draft.name)
                LabeledContent("Unit", value: draft.unit)
            } else {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $draft.kind) {
                    ForEach(SupplyKind.allCases) { Text($0.title).tag($0) }
                }
                if draft.kind == .tool {
                    Picker("Page", selection: $draft.toolGroup) {
                        ForEach(ToolGroup.allCases) { Text($0.title).tag($0) }
                    }
                }
                if draft.kind == .food {
                    Picker("Page", selection: $draft.foodGroup) {
                        ForEach(FoodGroup.allCases) { Text($0.title).tag($0) }
                    }
                }
                TextField("Unit (lb, can, each…)", text: $draft.unit)
            }
            LabeledContent("Quantity") {
                TextField("0", value: $draft.quantity, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            if draft.kind == .food && draft.foodGroup.feedsHousehold {
                LabeledContent("Calories per unit") {
                    if isBuiltIn {
                        Text(Int(draft.caloriesPerUnit).formatted())
                    } else {
                        TextField("0", value: $draft.caloriesPerUnit, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if draft.kind == .water {
                LabeledContent("Gallons per unit") {
                    if isBuiltIn {
                        Text(draft.gallonsPerUnit.formatted())
                    } else {
                        TextField("0", value: $draft.gallonsPerUnit, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }

        Section("Details") {
            Toggle("Has expiry date", isOn: $draft.hasExpiry.animation())
            if draft.hasExpiry {
                DatePicker("Expires", selection: $draft.expiresOn, displayedComponents: .date)
            }
            TextField("Storage location (garage shelf, basement…)", text: $draft.storageLocation)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }
}

struct SupplyDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let item: SupplyItem
    @State private var draft: SupplyDraft
    @State private var confirmRemove = false

    init(item: SupplyItem) {
        self.item = item
        _draft = State(initialValue: SupplyDraft(item))
    }

    var body: some View {
        NavigationStack {
            Form {
                SupplyFields(draft: $draft, isBuiltIn: item.isBuiltIn)
                Section {
                    Button(item.isBuiltIn ? "Hide from list" : "Delete item", role: .destructive) {
                        confirmRemove = true
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.apply(to: item)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
            .confirmationDialog(item.isBuiltIn ? "Hide “\(item.name)”?" : "Delete “\(item.name)”?",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(item.isBuiltIn ? "Hide item" : "Delete item", role: .destructive) {
                    if item.isBuiltIn {
                        item.isHidden = true
                        item.updatedAt = .now
                    } else {
                        context.delete(item)
                    }
                    try? context.save()
                    dismiss()
                }
            } message: {
                Text(item.isBuiltIn
                     ? "You can bring it back with the gear button on this page → Hidden items."
                     : "This removes the item and its quantity for good.")
            }
        }
    }
}

struct AddSupplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SupplyItem.sortOrder, order: .reverse) private var items: [SupplyItem]
    @State private var draft: SupplyDraft

    init(defaultKind: SupplyKind, defaultToolGroup: ToolGroup = .survival, defaultFoodGroup: FoodGroup = .regular) {
        _draft = State(initialValue: SupplyDraft(kind: defaultKind, toolGroup: defaultToolGroup, foodGroup: defaultFoodGroup))
    }

    var body: some View {
        NavigationStack {
            Form {
                SupplyFields(draft: $draft, isBuiltIn: false)
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let item = SupplyItem(name: "", kind: draft.kind, unit: "",
                                              sortOrder: (items.first?.sortOrder ?? 0) + 1)
                        draft.apply(to: item)
                        context.insert(item)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}

struct SuppliesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SupplySettings.redKey) private var redBelow = SupplySettings.defaultRed
    @AppStorage(SupplySettings.amberKey) private var amberBelow = SupplySettings.defaultAmber
    @AppStorage(SupplySettings.includeExpiredKey) private var includeExpired = false
    @Query(filter: #Predicate<SupplyItem> { $0.isHidden }, sort: \SupplyItem.name) private var hidden: [SupplyItem]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Red below \(Int(redBelow)) days", value: $redBelow, in: 1...max(1, amberBelow - 1))
                    Stepper("Amber below \(Int(amberBelow)) days", value: $amberBelow, in: (redBelow + 1)...365)
                } header: {
                    Text("Days remaining colors")
                } footer: {
                    Text("Green at \(Int(amberBelow)) days or more.")
                }

                Section {
                    Toggle("Include expired items", isOn: $includeExpired)
                } footer: {
                    Text("Expired food and water are left out of the days-remaining totals unless this is on.")
                }

                Section("Hidden items") {
                    if hidden.isEmpty {
                        Text("No hidden items").foregroundStyle(.secondary)
                    }
                    ForEach(hidden) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text(item.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show") {
                                item.isHidden = false
                                item.updatedAt = .now
                                try? context.save()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section {
                    Button("Restore default thresholds") {
                        redBelow = SupplySettings.defaultRed
                        amberBelow = SupplySettings.defaultAmber
                    }
                }
            }
            .navigationTitle("Supplies settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
