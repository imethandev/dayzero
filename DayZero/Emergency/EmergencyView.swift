import SwiftData
import SwiftUI

enum ContactSort: String, CaseIterable, Identifiable {
    case category = "Category", distance = "Distance"
    var id: String { rawValue }
}

struct EmergencyView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \EmergencyContact.name) private var allContacts: [EmergencyContact]

    @State private var search = ""
    @State private var sort: ContactSort = .category
    @State private var showHidden = false
    @State private var showAdd = false
    @State private var location = LocationProvider.shared

    private var visible: [EmergencyContact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return allContacts.filter { c in
            (showHidden || !c.isHidden)
                && (q.isEmpty || c.name.localizedCaseInsensitiveContains(q)
                    || c.phone.contains(q) || c.category.title.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let contacts = visible
        let favorites = contacts.filter(\.isFavorite)

        List {
                // 911 is always one tap away, whatever the filter.
                if search.isEmpty {
                    Section {
                        CallButton(label: "Call 911", phone: "911", prominent: true)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if search.isEmpty {
                    Section {
                        NavigationLink {
                            NearbyFacilitiesView()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Nearest hospitals, fire & police").font(.headline)
                                    Text("From the offline map data").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "location.magnifyingglass").foregroundStyle(.red)
                            }
                        }
                    }
                }

                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { ContactLink(contact: $0, distance: distance(for: $0)) }
                    }
                }

                switch sort {
                case .category:
                    ForEach(ContactCategory.allCases) { category in
                        let group = contacts.filter { $0.category == category && !$0.isFavorite }
                        if !group.isEmpty {
                            Section(category.title) {
                                ForEach(group) { ContactLink(contact: $0, distance: distance(for: $0)) }
                            }
                        }
                    }
                case .distance:
                    Section {
                        ForEach(byDistance(contacts.filter { !$0.isFavorite })) {
                            ContactLink(contact: $0, distance: distance(for: $0), showCategory: true)
                        }
                    } header: {
                        Text("Nearest first")
                    } footer: {
                        Text(distanceFooter)
                    }
                }

                if contacts.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Emergency")
            .navigationDestination(for: EmergencyContact.self) { ContactDetailView(contact: $0) }
            .searchable(text: $search, prompt: "Search contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(ContactSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Show hidden", isOn: $showHidden)
                    } label: {
                        Label("Sort and filter", systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Label("Add contact", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { ContactForm(contact: nil) }
            .onChange(of: sort) { _, new in
                if new == .distance { location.start() } else { location.stop() }
            }
            .onDisappear { if sort == .distance { location.stop() } }
            .onAppear { if sort == .distance { location.start() } }
    }

    private func distance(for c: EmergencyContact) -> Double? {
        location.distance(toLatitude: c.latitude, longitude: c.longitude)
    }

    private func byDistance(_ list: [EmergencyContact]) -> [EmergencyContact] {
        list.sorted { a, b in
            switch (distance(for: a), distance(for: b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.name.localizedCompare(b.name) == .orderedAscending
            }
        }
    }

    private var distanceFooter: String {
        if location.isDenied { return "Location is off for DayZero. Turn it on in Settings to sort by distance." }
        if location.location == nil { return "Waiting for a GPS fix… Contacts without a location are listed last." }
        return "Straight-line distance. Contacts without a location are listed last."
    }
}

// MARK: - Rows

private struct ContactLink: View {
    let contact: EmergencyContact
    let distance: Double?
    var showCategory = false

    var body: some View {
        NavigationLink(value: contact) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if contact.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            .accessibilityLabel("Favorite")
                    }
                    Text(contact.name).font(.headline)
                    if contact.isHidden {
                        Text("Hidden").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !contact.phone.isEmpty {
                    Text(contact.phone)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                HStack(spacing: 6) {
                    if showCategory { Text(contact.category.title) }
                    if let distance { Text(DistanceFormat.miles(distance)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .opacity(contact.isHidden ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct CallButton: View {
    let label: String
    let phone: String
    var prominent = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = PhoneLink.url(for: phone) { openURL(url) }
        } label: {
            Label(label, systemImage: "phone.fill")
                .font(prominent ? .title2.weight(.bold) : .headline)
                .frame(maxWidth: .infinity, minHeight: prominent ? 60 : 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .red : .accentColor)
        .disabled(PhoneLink.url(for: phone) == nil)
        .accessibilityHint("Opens the phone dialer")
    }
}

enum PhoneLink {
    /// Builds a tel: URL from a human-formatted number, keeping only digits and a leading +.
    static func url(for phone: String) -> URL? {
        var digits = phone.filter(\.isNumber)
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { digits = "+" + digits }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }
}
