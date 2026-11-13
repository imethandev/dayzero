import CoreLocation
import SwiftUI

/// Download (or replace) the offline map around the user's current location.
/// Shown inside the Map tab when there's no map yet, and as a sheet from the map's download button.
struct MapDownloadView: View {
    /// Inside a sheet: shows the current area and a Delete button.
    var inSheet = false
    var onFinished: () -> Void = {}

    @State private var downloader = MapDownloader()
    @State private var radius: Double = 20
    @State private var confirmDelete = false
    private var store = MapRegionStore.shared
    private var location = LocationProvider.shared

    init(inSheet: Bool = false, onFinished: @escaping () -> Void = {}) {
        self.inSheet = inSheet
        self.onFinished = onFinished
    }

    private var here: CLLocationCoordinate2D? { location.location?.coordinate }

    private var radii: [Double] {
        guard let here else { return MapDownloader.radiusOptions }
        return MapDownloader.allowedRadii(at: here)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 16))
                    Text(store.hasRegion ? "Offline map" : "Download a map of your area")
                        .font(.title2.weight(.bold))
                    Text("DayZero saves the map around you to this iPhone, so streets, hospitals, fire stations, shelters and place search all work with no signal. This is the only time the map uses the internet.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if let region = store.manifest, !downloader.isRunning {
                Section("Saved on this iPhone") {
                    LabeledContent("Area", value: "\(region.radiusKm.formatted(.number.precision(.fractionLength(0...1)))) km around \(DistanceFormat.coordinates(region.centerLatitude, region.centerLongitude))")
                    LabeledContent("Downloaded", value: region.downloadedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(region.bytes), countStyle: .file))
                    LabeledContent("Places and facilities", value: region.placeCount.formatted())
                    if let here, !MapBundle.contains(here) {
                        Label("You're outside this area. Download again to map where you are now.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            switch downloader.phase {
            case .tiles(let done, let total, let bytes):
                Section("Downloading map") {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    LabeledContent("Tiles", value: "\(done.formatted()) of \(total.formatted())")
                    LabeledContent("Downloaded", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    Button("Cancel", role: .destructive) { downloader.cancel() }
                }
            case .places:
                Section("Downloading places") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Hospitals, fire stations, shelters and town names…")
                    }
                    Button("Cancel", role: .destructive) { downloader.cancel() }
                }
            case .finished(let region):
                Section {
                    Label("Map saved: \(region.tileCount.formatted()) tiles, \(region.placeCount.formatted()) places.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if region.stoppedAtLimit == true {
                        Text("Busy areas have detailed maps, so the download stopped at the 50 MB limit. Full street detail covers about \(region.radiusKm.formatted(.number.precision(.fractionLength(0...1)))) km around you, with less detail beyond.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if region.placeCount == 0 {
                        Text("Place search couldn't be downloaded. The map works; try again later for search.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                    Text("Check your internet connection and try again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .idle:
                EmptyView()
            }

            if !downloader.isRunning {
                Section {
                    if here == nil {
                        if location.isDenied {
                            Label("Location is off. Turn it on for DayZero in Settings to download your area.", systemImage: "location.slash")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Finding your location…").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Picker("Area around you", selection: $radius) {
                            ForEach(radii, id: \.self) { r in
                                Text("\(Int(r)) km (\(Int((r * 0.621).rounded())) mi)").tag(r)
                            }
                        }
                        Button {
                            if let here { downloader.start(center: here, radiusKm: radius) }
                        } label: {
                            Label(store.hasRegion ? "Replace with my current area" : "Download my area",
                                  systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                        }
                    }
                } footer: {
                    Text("Full street detail for the area you pick, with less detail beyond it. Wi-Fi recommended: up to 50 MB. Map tiles from OpenFreeMap and places from OpenStreetMap; DayZero sends them only the area's coordinates.")
                }

                if inSheet, store.hasRegion {
                    Section {
                        Button("Delete downloaded map", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .onAppear {
            location.start()
            clampRadius()
            autoStartForTesting()
        }
        .onChange(of: location.location) { autoStartForTesting() }
        .onDisappear { location.stop() }
        .onChange(of: radii) { clampRadius() }
        .onChange(of: downloader.phase) { _, phase in
            if case .finished = phase { onFinished() }
        }
        .confirmationDialog("Delete the downloaded map?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete map", role: .destructive) { store.delete() }
        } message: {
            Text(MapBundle.bundledTiles == nil ? "The Map tab will be empty until you download an area again." : "The map goes back to the one built into this app.")
        }
        .interactiveDismissDisabled(downloader.isRunning)
    }

    /// Debug: `-autoDownloadKm 5` starts a download as soon as a location fix arrives (for testing).
    private func autoStartForTesting() {
        #if DEBUG
        let km = UserDefaults.standard.double(forKey: "autoDownloadKm")
        guard km > 0, let here, case .idle = downloader.phase else { return }
        UserDefaults.standard.removeObject(forKey: "autoDownloadKm")
        downloader.start(center: here, radiusKm: km)
        #endif
    }

    private func clampRadius() {
        if !radii.contains(radius) { radius = radii.filter { $0 <= 20 }.last ?? radii.first ?? 10 }
    }
}
