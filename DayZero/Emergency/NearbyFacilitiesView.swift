import CoreLocation
import SwiftData
import SwiftUI

/// Hospitals, fire stations and police from the same OpenStreetMap extract as the map,
/// nearest first. Read-only; any of them can be saved as a contact.
struct NearbyFacilitiesView: View {
    private static let groups: [(String, [PlaceKind])] = [
        ("Hospitals", [.hospital]),
        ("Fire stations", [.fire_station]),
        ("Police", [.police]),
        ("Urgent care & clinics", [.clinic]),
        ("Pharmacies", [.pharmacy]),
        ("Shelters", [.shelter]),
    ]

    @State private var location = LocationProvider.shared
    @State private var results: [String: [Place]] = [:]
    @State private var lastQueried: CLLocation?

    var body: some View {
        List {
            if let here = location.location {
                ForEach(Self.groups, id: \.0) { title, _ in
                    if let places = results[title], !places.isEmpty {
                        Section(title) {
                            ForEach(places) { place in
                                NavigationLink(value: place) {
                                    FacilityRow(place: place, from: here)
                                }
                            }
                        }
                    }
                }
                Section {} footer: {
                    Text("From the OpenStreetMap data saved on this iPhone (\(MapBundle.dataDate ?? "unknown date")). Straight-line distances. Facilities change, so confirm before relying on one.")
                }
            } else {
                ContentUnavailableView {
                    Label(location.isDenied ? "Location is off" : "Finding your location…", systemImage: "location")
                } description: {
                    Text(location.isDenied
                         ? "Turn on location for DayZero in Settings to list the nearest facilities."
                         : "GPS works without a network, but it can take a minute outdoors.")
                }
            }
        }
        .navigationTitle("Nearest Services")
        .navigationDestination(for: Place.self) { FacilityDetailView(place: $0) }
        .onAppear { location.start(); refresh() }
        .onDisappear { location.stop() }
        .onChange(of: location.location) { refresh() }
    }

    private func refresh() {
        guard let here = location.location else { return }
        // Re-query only after moving a meaningful distance.
        if let last = lastQueried, here.distance(from: last) < 200, !results.isEmpty { return }
        lastQueried = here
        var out: [String: [Place]] = [:]
        for (title, kinds) in Self.groups {
            out[title] = PlacesDatabase.shared.nearest(kinds, to: here.coordinate, limit: title == "Hospitals" ? 5 : 3)
        }
        results = out
    }
}

private struct FacilityRow: View {
    let place: Place
    let from: CLLocation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.kind.symbol)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(place.kind.layer?.color ?? .systemGray), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.headline)
                if !place.phone.isEmpty {
                    Text(place.phone).font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
                }
                if !place.address.isEmpty {
                    Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(DistanceFormat.miles(from.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FacilityDetailView: View {
    let place: Place
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @State private var saved = false
    private var location = LocationProvider.shared

    init(place: Place) { self.place = place }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.kind.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(place.name).font(.title2.weight(.bold))
                }
                .listRowBackground(Color.clear)
            }
            if !place.phone.isEmpty {
                Section("Phone") {
                    Text(place.phone)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .textSelection(.enabled)
                    CallButton(label: "Call", phone: place.phone)
                }
            }
            Section("Location") {
                if !place.address.isEmpty { Text(place.address).textSelection(.enabled) }
                LabeledContent("Coordinates") {
                    Text(DistanceFormat.coordinates(place.latitude, place.longitude)).monospacedDigit().textSelection(.enabled)
                }
                if let here = location.location {
                    LabeledContent("Distance", value: DistanceFormat.miles(here.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))))
                    LabeledContent("Bearing", value: Bearing.cardinal(from: here.coordinate, toLatitude: place.latitude, longitude: place.longitude))
                }
                Button {
                    router.showOnMap(title: place.name, latitude: place.latitude, longitude: place.longitude)
                } label: {
                    Label("Show on map", systemImage: "map")
                }
            }
            if !place.website.isEmpty {
                Section("Website") { Text(place.website).font(.callout.monospaced()).textSelection(.enabled) }
            }
            Section {
                Button(saved ? "Saved to your contacts" : "Save to my contacts", systemImage: saved ? "checkmark" : "star") {
                    context.insert(EmergencyContact(
                        name: place.name, category: place.kind.contactCategory, phone: place.phone,
                        address: place.address, latitude: place.latitude, longitude: place.longitude,
                        website: place.website, notes: "Added from the offline map (OpenStreetMap)."))
                    try? context.save()
                    saved = true
                }
                .disabled(saved)
            } footer: {
                Text("Phone numbers in map data aren't verified. Check before relying on them.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }
}
