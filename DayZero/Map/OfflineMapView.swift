import CoreLocation
import SwiftData
import SwiftUI
import UIKit

enum MapThemeSetting: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Match system"
        case .light: "Light"
        case .dark: "Dark (saves battery)"
        }
    }
}

struct NewPinRequest: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
}

struct OfflineMapView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context
    @AppStorage("map.theme") private var themeSetting: MapThemeSetting = .auto
    @AppStorage("map.layers") private var layersRaw = FacilityLayer.allCases.map(\.rawValue).joined(separator: ",")

    @Query private var pins: [MapPin]
    @Query(filter: #Predicate<EmergencyContact> { $0.latitude != nil && $0.longitude != nil && !$0.isHidden })
    private var placedContacts: [EmergencyContact]

    @State private var isVisible = false
    @State private var recenterToken = 0
    @State private var toast: String?
    @State private var styleURLs: [MapBundle.Theme: URL] = [:]
    @State private var selection: MapSelection?
    @State private var newPin: NewPinRequest?
    @State private var editingPin: MapPin?
    @State private var search = ""
    @State private var results: [Place] = []
    @FocusState private var searchFocused: Bool
    @State private var showDownload = false
    private var location = LocationProvider.shared
    private var regionStore = MapRegionStore.shared

    private var theme: MapBundle.Theme {
        switch themeSetting {
        case .light: .light
        case .dark: .dark
        case .auto: colorScheme == .dark ? .dark : .light
        }
    }

    private var enabledLayers: Set<FacilityLayer> {
        Set(layersRaw.split(separator: ",").compactMap { FacilityLayer(rawValue: String($0)) })
    }

    private var contactMarkers: [MapMarker] {
        placedContacts.map {
            MapMarker(id: $0.id.uuidString, title: $0.name, latitude: $0.latitude!, longitude: $0.longitude!, icon: MapIcons.contact)
        }
    }

    private var pinMarkers: [MapMarker] {
        pins.map {
            MapMarker(id: $0.id.uuidString, title: $0.title, latitude: $0.latitude, longitude: $0.longitude, icon: MapIcons.name(for: $0.kind))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            mapCard
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $newPin) { req in
            PinForm(pin: nil, latitude: req.latitude, longitude: req.longitude)
        }
        .sheet(item: $editingPin) { pin in
            PinForm(pin: pin, latitude: pin.latitude, longitude: pin.longitude)
        }
        .onChange(of: search) { _, text in runSearch(text) }
        .onChange(of: regionStore.revision) {
            selection = nil
            loadStyles()
        }
        .sheet(isPresented: $showDownload) {
            NavigationStack {
                MapDownloadView(inSheet: true)
                    .navigationTitle("Offline map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showDownload = false } }
                    }
            }
        }
        .onChange(of: router.mapFocus) { _, focus in
            if focus != nil { selection = nil }
        }
        .onAppear {
            if styleURLs.isEmpty { loadStyles() }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "showMapDownload") { showDownload = true }
            #endif
            isVisible = true
            location.start()
        }
        .onDisappear {
            // GPS runs only while the Map tab is visible.
            isVisible = false
            location.stop()
        }
    }

    // MARK: Map card

    private var mapCard: some View {
        ZStack {
            if let url = styleURLs[theme] {
                MapLibreView(
                    styleURL: url,
                    showsUserLocation: isVisible,
                    recenterToken: recenterToken,
                    focus: router.mapFocus,
                    enabledLayers: enabledLayers,
                    contacts: contactMarkers,
                    pins: pinMarkers,
                    onRecenterFailed: recenterFailed,
                    onSelect: { sel in
                        searchFocused = false
                        withAnimation(.snappy) { selection = sel }
                    },
                    onLongPress: { c in
                        newPin = NewPinRequest(latitude: c.latitude, longitude: c.longitude)
                    }
                )
                .id(regionStore.revision)
            } else if !MapBundle.hasTiles {
                MapDownloadView()
                    .scrollContentBackground(.hidden)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) { overMapTop }
        .overlay(alignment: .bottom) { if MapBundle.hasTiles { bottomArea } }
        .overlay(alignment: .center) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
    }

    // MARK: Header: search, then categories

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search places, hospitals, fuel…", text: $search)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            Button { showDownload = true } label: {
                Image(systemName: isOutsideMap ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isOutsideMap ? Color.white : Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(isOutsideMap ? Color.orange : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel(isOutsideMap ? "You're outside the offline map. Download your area" : "Offline map area")
            .accessibilityHint("Download or replace the map of your area")
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryChip(title: "All", symbol: "square.grid.2x2.fill", color: .systemGray,
                                 isOn: enabledLayers.count == FacilityLayer.allCases.count) {
                        setLayers(Set(FacilityLayer.allCases))
                    }
                    ForEach(FacilityLayer.allCases) { layer in
                        CategoryChip(title: layer.shortTitle, symbol: layer.symbol, color: layer.color,
                                     isOn: enabledLayers.contains(layer) && enabledLayers.count < FacilityLayer.allCases.count) {
                            tapCategory(layer)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
        .padding(.top, 4)
    }

    /// Search results or the "Show on map" card, floating at the top of the map card.
    @ViewBuilder private var overMapTop: some View {
        Group {
            if searchFocused || !search.isEmpty {
                searchResults
            } else if let focus = router.mapFocus {
                focusCard(focus)
            }
        }
        .padding(10)
    }

    private var isOutsideMap: Bool {
        guard let c = location.location?.coordinate else { return false }
        return !MapBundle.contains(c)
    }

    @ViewBuilder private var searchResults: some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 0) {
                if results.isEmpty {
                    Text(PlacesDatabase.shared.isAvailable ? "No matches" : "Places database missing")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { place in
                                Button { choose(place) } label: { PlaceRow(place: place) }
                                    .buttonStyle(.plain)
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func focusCard(_ focus: MapFocus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focus.title).font(.headline)
                Text(DistanceFormat.coordinates(focus.latitude, focus.longitude))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                distanceLine(focus.latitude, focus.longitude)
            }
            Spacer()
            Button { router.mapFocus = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Clear")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Bottom: selection card, coordinates, controls

    private var bottomArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let loc = location.location {
                        Button {
                            UIPasteboard.general.string = DistanceFormat.coordinates(loc.coordinate.latitude, loc.coordinate.longitude)
                            flash("Coordinates copied")
                        } label: {
                            Label(DistanceFormat.coordinates(loc.coordinate.latitude, loc.coordinate.longitude),
                                  systemImage: "location.fill")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Copies your coordinates")
                    }
                    Text(MapBundle.attribution)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                VStack(spacing: 10) {
                Button {
                    themeSetting = theme == .dark ? .light : .dark
                } label: {
                    Image(systemName: theme == .dark ? "sun.max.fill" : "moon.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 2, y: 1)
                }
                .contextMenu {
                    Picker("Map style", selection: $themeSetting) {
                        ForEach(MapThemeSetting.allCases) { Text($0.title).tag($0) }
                    }
                }
                .accessibilityLabel(theme == .dark ? "Switch map to light mode" : "Switch map to dark mode")
                .accessibilityHint("Touch and hold for Match system")

                Button { recenterToken += 1 } label: {
                    Image(systemName: "location.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 2, y: 1)
                }
                .accessibilityLabel("Center on my location")
                }
            }

            if let selection {
                SelectionCard(selection: selection, onClose: { withAnimation { self.selection = nil } },
                              onEditPin: { pin in editingPin = pin })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if pins.isEmpty && search.isEmpty {
                Text("Long-press the map to drop a pin")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func distanceLine(_ lat: Double, _ lon: Double) -> some View {
        if let here = location.location, let d = location.distance(toLatitude: lat, longitude: lon) {
            Text("\(DistanceFormat.miles(d)) straight line · \(Bearing.cardinal(from: here.coordinate, toLatitude: lat, longitude: lon))")
                .font(.subheadline)
        }
    }

    // MARK: Actions

    private func setLayers(_ set: Set<FacilityLayer>) {
        layersRaw = FacilityLayer.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    /// From "All", a tap shows just that category; after that, taps add or remove categories.
    /// Removing the last one goes back to All.
    private func tapCategory(_ layer: FacilityLayer) {
        var set = enabledLayers
        if set.count == FacilityLayer.allCases.count {
            set = [layer]
        } else if set.contains(layer) {
            set.remove(layer)
        } else {
            set.insert(layer)
        }
        setLayers(set.isEmpty ? Set(FacilityLayer.allCases) : set)
    }

    private func runSearch(_ text: String) {
        let near = location.location?.coordinate
        let q = text
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PlacesDatabase.shared.search(q, near: near)
            DispatchQueue.main.async { if q == search { results = found } }
        }
    }

    private func choose(_ place: Place) {
        searchFocused = false
        search = ""
        results = []
        router.mapFocus = MapFocus(title: place.name, latitude: place.latitude, longitude: place.longitude)
        if place.kind.layer != nil {
            selection = MapSelection(source: .facility, id: String(place.id), title: place.name,
                                     latitude: place.latitude, longitude: place.longitude)
        }
    }

    private func recenterFailed() {
        if location.isDenied {
            flash("Location is off. Turn it on in Settings.")
        } else if let loc = location.location, !MapBundle.contains(loc.coordinate) {
            flash("You're outside the offline map. Tap ↓ to download this area.")
        } else {
            flash("Waiting for GPS…")
        }
    }

    private func loadStyles() {
        styleURLs = [.light: MapBundle.styleURL(.light), .dark: MapBundle.styleURL(.dark)].compactMapValues { $0 }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { toast = nil } }
    }
}

// MARK: - Category chip

private struct CategoryChip: View {
    let title: String
    let symbol: String
    let color: UIColor
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOn ? .white : Color(color))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOn ? .white : .primary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isOn ? Color(color) : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension FacilityLayer {
    var shortTitle: String {
        switch self {
        case .medical: "Hospitals"
        case .fire: "Fire"
        case .police: "Police"
        case .pharmacies: "Pharmacies"
        case .fuel: "Fuel"
        case .water: "Water"
        case .shelters: "Shelters"
        }
    }
}

// MARK: - Search result row

private struct PlaceRow: View {
    let place: Place
    private var location = LocationProvider.shared

    init(place: Place) { self.place = place }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.kind.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(place.kind.layer?.color ?? .systemGray), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.body).lineLimit(1)
                Text([place.kind.title, place.address].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = location.distance(toLatitude: place.latitude, longitude: place.longitude) {
                Text(DistanceFormat.miles(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Selection card

private struct SelectionCard: View {
    let selection: MapSelection
    let onClose: () -> Void
    let onEditPin: (MapPin) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query private var pins: [MapPin]
    @Query private var contacts: [EmergencyContact]
    @State private var savedToContacts = false
    private var location = LocationProvider.shared

    init(selection: MapSelection, onClose: @escaping () -> Void, onEditPin: @escaping (MapPin) -> Void) {
        self.selection = selection
        self.onClose = onClose
        self.onEditPin = onEditPin
    }

    private var place: Place? {
        selection.source == .facility ? Int64(selection.id).flatMap(PlacesDatabase.shared.place(id:)) : nil
    }
    private var pin: MapPin? { pins.first { $0.id.uuidString == selection.id } }
    private var contact: EmergencyContact? { contacts.first { $0.id.uuidString == selection.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(subtitle.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selection.title.isEmpty ? "Unnamed" : selection.title).font(.headline)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }

            if let here = location.location {
                let d = here.distance(from: CLLocation(latitude: selection.latitude, longitude: selection.longitude))
                HStack(spacing: 16) {
                    Label(DistanceFormat.miles(d), systemImage: "ruler")
                    Label(Bearing.cardinal(from: here.coordinate, toLatitude: selection.latitude, longitude: selection.longitude),
                          systemImage: "location.north.line")
                }
                .font(.title3.weight(.semibold).monospacedDigit())
                Text("Straight-line distance and compass bearing from you")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(location.isDenied ? "Turn on location to see distance and bearing." : "Waiting for GPS…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(DistanceFormat.coordinates(selection.latitude, selection.longitude))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)

            if let detail, !detail.isEmpty {
                Text(detail).font(.callout).lineLimit(3)
            }

            HStack {
                if let phone = phone, let url = PhoneLink.url(for: phone) {
                    Button { openURL(url) } label: { Label(phone, systemImage: "phone.fill") }
                        .buttonStyle(.borderedProminent)
                }
                if let pin {
                    Button { onEditPin(pin) } label: { Label("Edit pin", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                }
                if let place, place.kind.layer != nil {
                    Button { saveToContacts(place) } label: {
                        Label(savedToContacts ? "Saved" : "Save to contacts",
                              systemImage: savedToContacts ? "checkmark" : "star")
                    }
                    .buttonStyle(.bordered)
                    .disabled(savedToContacts)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: selection) { savedToContacts = false }
    }

    private var subtitle: String {
        switch selection.source {
        case .facility: place?.kind.title ?? "Place"
        case .contact: "Emergency contact · \(contact?.category.title ?? "")"
        case .pin: "My pin · \(pin?.kind.title ?? "")"
        }
    }

    private var detail: String? {
        switch selection.source {
        case .facility: place?.address
        case .contact: contact.map { [$0.address, $0.notes].filter { !$0.isEmpty }.joined(separator: "\n") }
        case .pin: pin?.notes
        }
    }

    private var phone: String? {
        let p = selection.source == .facility ? place?.phone : contact?.phone
        return (p?.isEmpty ?? true) ? nil : p
    }

    private func saveToContacts(_ place: Place) {
        context.insert(EmergencyContact(
            name: place.name, category: place.kind.contactCategory, phone: place.phone,
            address: place.address, latitude: place.latitude, longitude: place.longitude,
            website: place.website, notes: "Added from the offline map (OpenStreetMap)."
        ))
        try? context.save()
        savedToContacts = true
    }
}

enum Bearing {
    static func degrees(from a: CLLocationCoordinate2D, toLatitude lat: Double, longitude lon: Double) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = lat * .pi / 180
        let Δλ = (lon - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func cardinal(from a: CLLocationCoordinate2D, toLatitude lat: Double, longitude lon: Double) -> String {
        let d = degrees(from: a, toLatitude: lat, longitude: lon)
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return "\(Int(d.rounded()) % 360)° \(names[Int((d + 22.5) / 45) % 8])"
    }
}
