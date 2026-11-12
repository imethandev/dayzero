import SwiftData
import SwiftUI

/// Household members page, opened from the Home tab.
struct HouseholdView: View {
    var body: some View {
        MembersList()
            .navigationTitle("Household")
    }
}

/// Household notes page, opened from the Home tab.
struct NotesView: View {
    var body: some View {
        NotesList()
            .navigationTitle("Notes")
    }
}

// MARK: - Members

private struct MembersList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \HouseholdMember.name) private var members: [HouseholdMember]
    @State private var editing: HouseholdMember?
    @State private var showAdd = false
    @State private var pendingDelete: HouseholdMember?

    var body: some View {
        List {
            if members.isEmpty {
                ContentUnavailableView {
                    Label("No members yet", systemImage: "person.3")
                } description: {
                    Text("Add everyone your supplies need to cover. Each person defaults to 2,000 calories and 1 gallon of water a day.")
                } actions: {
                    Button("Add a member") { showAdd = true }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(members) { member in
                        MemberRow(member: member) { editing = member }
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingDelete = member }
                            }
                    }
                } footer: {
                    Text("\(members.filter(\.isActive).count) of \(members.count) active. Inactive members are left out of days remaining.")
                }
            }
        }
        .toolbar {
            Button { showAdd = true } label: { Label("Add member", systemImage: "person.badge.plus") }
        }
        .sheet(item: $editing) { MemberForm(member: $0) }
        .sheet(isPresented: $showAdd) { MemberForm(member: nil) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "member")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { member in
            Button("Delete member", role: .destructive) {
                context.delete(member)
                try? context.save()
            }
        } message: { _ in
            Text("Their notes stay in Notes, unlinked. To leave someone out for a while, turn off Active instead.")
        }
    }
}

private struct MemberRow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Bindable var member: HouseholdMember
    let onTap: () -> Void

    var body: some View {
        HStack {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(member.isActive ? 1 : 0.5)

            if let url = PhoneLink.url(for: member.phone) {
                Button { openURL(url) } label: {
                    Image(systemName: "phone.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.green, in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Call \(member.name), \(member.phone)")
            }

            Toggle("Active", isOn: $member.isActive)
                .labelsHidden()
                .onChange(of: member.isActive) { try? context.save() }
                .accessibilityLabel("\(member.name) active")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !member.relationship.isEmpty { parts.append(member.relationship) }
        if member.gender != .notSelected { parts.append(member.gender.title) }
        if let age = member.age { parts.append("age \(age)") }
        if !member.phone.isEmpty { parts.append(member.phone) }
        if !member.isActive { parts.append("away") }
        return parts.isEmpty ? "Tap to add details" : parts.joined(separator: " · ")
    }
}

extension HouseholdMember {
    var age: Int? {
        guard let birthYear else { return nil }
        let year = Calendar.current.component(.year, from: .now)
        return year >= birthYear ? year - birthYear : nil
    }
}

private struct MemberForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let member: HouseholdMember?

    @State private var name = ""
    @State private var relationship = ""
    @State private var phone = ""
    @State private var gender: Gender = .notSelected
    @State private var birthYear: Int?
    @State private var dailyCalories = HouseholdMember.defaultDailyCalories
    @State private var dailyWater = HouseholdMember.defaultDailyWaterGallons
    @State private var isActive = true
    @State private var notes = ""

    init(member: HouseholdMember?) {
        self.member = member
        if let m = member {
            _name = State(initialValue: m.name)
            _relationship = State(initialValue: m.relationship)
            _phone = State(initialValue: m.phone)
            _gender = State(initialValue: m.gender)
            _birthYear = State(initialValue: m.birthYear)
            _dailyCalories = State(initialValue: m.dailyCalories)
            _dailyWater = State(initialValue: m.dailyWaterGallons)
            _isActive = State(initialValue: m.isActive)
            _notes = State(initialValue: m.notes)
        }
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("Relationship (self, spouse, child…)", text: $relationship)
                    Picker("Gender", selection: $gender) {
                        ForEach(Gender.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Phone number", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    LabeledContent("Birth year") {
                        TextField("Optional", value: $birthYear, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Active", isOn: $isActive)
                } footer: {
                    Text("Turn off Active for someone who is away. They are left out of days remaining.")
                }

                Section {
                    LabeledContent("Calories per day") {
                        TextField("2000", value: $dailyCalories, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Water per day (gal)") {
                        TextField("1.0", value: $dailyWater, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Reset to defaults") {
                        dailyCalories = HouseholdMember.defaultDailyCalories
                        dailyWater = HouseholdMember.defaultDailyWaterGallons
                    }
                } header: {
                    Text("Daily needs")
                } footer: {
                    Text("Defaults follow common guidance: 2,000 calories and 1 gallon of water per person per day.")
                }

                Section("Notes") {
                    TextField("Medications, allergies, blood type, special needs", text: $notes, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle(member == nil ? "New member" : "Edit member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(member == nil ? "Add" : "Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let m = member ?? HouseholdMember(name: "")
        m.name = name.trimmingCharacters(in: .whitespaces)
        m.relationship = relationship.trimmingCharacters(in: .whitespaces)
        m.phone = phone.trimmingCharacters(in: .whitespaces)
        m.gender = gender
        m.birthYear = birthYear
        m.dailyCalories = max(0, dailyCalories)
        m.dailyWaterGallons = max(0, dailyWater)
        m.isActive = isActive
        m.notes = notes
        if member == nil { context.insert(m) }
        try? context.save()
        dismiss()
    }
}

// MARK: - Notes

private struct NotesList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var search = ""
    @State private var editing: Note?
    @State private var showAdd = false
    @State private var pendingDelete: Note?

    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? notes : notes.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
                || ($0.member?.name.localizedCaseInsensitiveContains(q) ?? false)
        }
        return hits.filter(\.isPinned) + hits.filter { !$0.isPinned }
    }

    var body: some View {
        List {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "note.text")
                } description: {
                    Text("Keep plans, meeting points, combinations and instructions here. Everything stays on this phone.")
                } actions: {
                    Button("Add a note") { showAdd = true }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(filtered) { note in
                Button { editing = note } label: { NoteRow(note: note) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button(note.isPinned ? "Unpin" : "Pin") {
                            note.isPinned.toggle()
                            try? context.save()
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { pendingDelete = note }
                    }
            }
        }
        .searchable(text: $search, prompt: "Search notes")
        .toolbar {
            Button { showAdd = true } label: { Label("Add note", systemImage: "square.and.pencil") }
        }
        .sheet(item: $editing) { NoteForm(note: $0) }
        .sheet(isPresented: $showAdd) { NoteForm(note: nil) }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "note")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { note in
            Button("Delete note", role: .destructive) {
                context.delete(note)
                try? context.save()
            }
        } message: { _ in
            Text("This can't be undone.")
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption)
                        .accessibilityLabel("Pinned")
                }
                Text(note.title.isEmpty ? "Untitled" : note.title).font(.headline)
            }
            if !note.body.isEmpty {
                Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let m = note.member { Label(m.name, systemImage: "person.fill") }
                Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct NoteForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \HouseholdMember.name) private var members: [HouseholdMember]
    let note: Note?

    @State private var title = ""
    @State private var noteBody = ""
    @State private var memberID: UUID?
    @State private var isPinned = false

    init(note: Note?) {
        self.note = note
        if let n = note {
            _title = State(initialValue: n.title)
            _noteBody = State(initialValue: n.body)
            _memberID = State(initialValue: n.member?.id)
            _isPinned = State(initialValue: n.isPinned)
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty || !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).font(.headline)
                    TextField("Write the plan, meeting point, combination…", text: $noteBody, axis: .vertical)
                        .lineLimit(8...30)
                }
                Section {
                    Picker("Linked member", selection: $memberID) {
                        Text("None").tag(UUID?.none)
                        ForEach(members) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("Pin to top", isOn: $isPinned)
                }
            }
            .navigationTitle(note == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(note == nil ? "Add" : "Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let n = note ?? Note(title: "")
        n.title = title.trimmingCharacters(in: .whitespaces)
        n.body = noteBody
        n.member = members.first { $0.id == memberID }
        n.isPinned = isPinned
        n.updatedAt = .now
        if note == nil { context.insert(n) }
        try? context.save()
        dismiss()
    }
}
