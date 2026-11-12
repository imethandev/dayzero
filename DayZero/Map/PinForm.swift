import SwiftData
import SwiftUI

/// Create or edit a custom map pin (cache, meeting point, water source, shelter, other).
struct PinForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let pin: MapPin?
    let latitude: Double
    let longitude: Double

    @State private var title = ""
    @State private var kind: MapPinKind = .meetingPoint
    @State private var notes = ""
    @State private var confirmDelete = false

    init(pin: MapPin?, latitude: Double, longitude: Double) {
        self.pin = pin
        self.latitude = latitude
        self.longitude = longitude
        if let pin {
            _title = State(initialValue: pin.title)
            _kind = State(initialValue: pin.kind)
            _notes = State(initialValue: pin.notes)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (e.g. Grandma's house)", text: $title)
                    Picker("Kind", selection: $kind) {
                        ForEach(MapPinKind.allCases) { k in
                            Label(k.title, systemImage: MapIcons.pinSymbol(k)).tag(k)
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    LabeledContent("Coordinates") {
                        Text(DistanceFormat.coordinates(latitude, longitude)).monospacedDigit().textSelection(.enabled)
                    }
                }
                if pin != nil {
                    Section {
                        Button("Delete pin", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(pin == nil ? "New pin" : "Edit pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pin == nil ? "Add" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete “\(pin?.title ?? "pin")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete pin", role: .destructive) {
                    if let pin { context.delete(pin) }
                    try? context.save()
                    dismiss()
                }
            } message: {
                Text("This can't be undone.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let p = pin ?? MapPin(title: "", kind: kind, latitude: latitude, longitude: longitude)
        p.title = title.trimmingCharacters(in: .whitespaces)
        p.kind = kind
        p.notes = notes
        if pin == nil { context.insert(p) }
        try? context.save()
        dismiss()
    }
}
