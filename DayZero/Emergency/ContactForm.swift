import SwiftData
import SwiftUI

struct ContactForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let contact: EmergencyContact?

    @State private var name = ""
    @State private var category: ContactCategory = .personal
    @State private var phone = ""
    @State private var address = ""
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var website = ""
    @State private var notes = ""
    @State private var isFavorite = false
    @State private var useCurrentLocation = false
    private var location = LocationProvider.shared

    init(contact: EmergencyContact?) {
        self.contact = contact
        if let c = contact {
            _name = State(initialValue: c.name)
            _category = State(initialValue: c.category)
            _phone = State(initialValue: c.phone)
            _address = State(initialValue: c.address)
            _latitude = State(initialValue: c.latitude)
            _longitude = State(initialValue: c.longitude)
            _website = State(initialValue: c.website)
            _notes = State(initialValue: c.notes)
            _isFavorite = State(initialValue: c.isFavorite)
        }
    }

    private var coordinatesValid: Bool {
        switch (latitude, longitude) {
        case (nil, nil): true
        case let (lat?, lon?): (-90...90).contains(lat) && (-180...180).contains(lon)
        default: false
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && coordinatesValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (family doctor, neighbor…)", text: $name)
                        .textContentType(.name)
                    Picker("Category", selection: $category) {
                        ForEach(ContactCategory.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    Toggle("Favorite", isOn: $isFavorite)
                }

                Section {
                    TextField("Address", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                        .lineLimit(1...3)
                    LabeledContent("Latitude") {
                        TextField("Optional", value: $latitude, format: .number.precision(.fractionLength(0...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("Optional", value: $longitude, format: .number.precision(.fractionLength(0...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Use my current location", systemImage: "location") {
                        useCurrentLocation = true
                        location.start()
                        fillFromLocation()
                    }
                    if useCurrentLocation && location.location == nil {
                        Text(location.isDenied ? "Location is off for DayZero in Settings." : "Waiting for GPS…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text(coordinatesValid
                         ? "Coordinates put this contact on the offline map and let the list sort by distance. Address lookup needs a server, so DayZero doesn't do it."
                         : "Enter both latitude and longitude, or neither.")
                }

                Section {
                    TextField("Website", text: $website)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...8)
                }
            }
            .navigationTitle(contact == nil ? "New contact" : "Edit contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(contact == nil ? "Add" : "Save") { save() }.disabled(!isValid)
                }
            }
            .onChange(of: location.location) { if useCurrentLocation { fillFromLocation() } }
            .onDisappear { if useCurrentLocation { location.stop() } }
        }
    }

    private func fillFromLocation() {
        guard let loc = location.location else { return }
        latitude = (loc.coordinate.latitude * 1e6).rounded() / 1e6
        longitude = (loc.coordinate.longitude * 1e6).rounded() / 1e6
        useCurrentLocation = false
        location.stop()
    }

    private func save() {
        let c = contact ?? EmergencyContact(name: "", category: category)
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.category = category
        c.phone = phone.trimmingCharacters(in: .whitespaces)
        c.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        c.latitude = latitude
        c.longitude = longitude
        c.website = website.trimmingCharacters(in: .whitespaces)
        c.notes = notes
        c.isFavorite = isFavorite
        if c.isBuiltIn { c.userEdited = true }
        if contact == nil { context.insert(c) }
        try? context.save()
        dismiss()
    }
}
