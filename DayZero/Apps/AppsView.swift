import SwiftData
import SwiftUI
import UIKit

/// Tab 5: a two-column grid of offline tools. Flashlight and SOS toggle right from
/// the grid and show their on state; everything else opens its own screen.
struct AppsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @AppStorage("tools.order") private var orderRaw = ToolID.defaultOrder.map(\.rawValue).joined(separator: ",")
    @AppStorage("tools.hidden") private var hiddenRaw = ""
    @State private var tools = ToolController.shared
    @State private var path: [ToolID] = []
    @State private var customizing = false

    private var order: [ToolID] { ToolID.resolveOrder(orderRaw) }

    private var hidden: Set<ToolID> { Set(hiddenRaw.split(separator: ",").compactMap { ToolID(rawValue: String($0)) }) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(order.filter { !hidden.contains($0) }) { tool in
                        ToolTile(tool: tool, isOn: isOn(tool), onTap: { open(tool) })
                    }
                }
                .padding()
                if !tools.torchAvailable {
                    Text("This device has no flashlight, so Flashlight, SOS and Morse light won't light up.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .navigationTitle("Control")
            .navigationDestination(for: ToolID.self) { ToolScreen(tool: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") { customizing = true }
                }
            }
            .sheet(isPresented: $customizing) {
                CustomizeToolsView(orderRaw: $orderRaw, hiddenRaw: $hiddenRaw)
            }
            .onChange(of: router.openTool) { _, tool in
                guard let tool else { return }
                router.openTool = nil
                path = [tool]
            }
            .onAppear {
                if let tool = router.openTool {
                    router.openTool = nil
                    path = [tool]
                }
            }
        }
    }

    private func isOn(_ tool: ToolID) -> Bool {
        switch tool {
        case .flashlight: tools.torchOn
        case .sos: tools.sosRunning
        case .whistle: tools.whistleOn
        case .morse: tools.signal == .morse
        default: false
        }
    }

    private func open(_ tool: ToolID) {
        switch tool {
        // Flashlight and SOS only open their page; they're switched on there, never from the grid.
        case .messages: if let url = URL(string: "sms:") { openURL(url) }
        case .settings: if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        default: path.append(tool)
        }
    }
}

private struct ToolTile: View {
    let tool: ToolID
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 32, weight: .semibold))
                    .symbolEffect(.pulse, isActive: isOn && tool == .sos)
                Text(tool.title).font(.headline).multilineTextAlignment(.center)
                if isOn {
                    Text(tool == .sos ? "SIGNALLING" : "ON")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.black.opacity(0.15), in: Capsule())
                } else if tool.isShortcut {
                    Text("Opens iPhone app").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 124)
            .padding(.horizontal, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(isOn ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tool.title)\(isOn ? ", on" : "")")
        .accessibilityHint(tool.isShortcut ? "Opens the iPhone app" : "Opens \(tool.title)")
    }

    private var background: some ShapeStyle {
        // Grey like every tile; only a light or signal that is actually running is colored.
        if isOn { return AnyShapeStyle(tool == .sos ? Color.red : Color.yellow) }
        return AnyShapeStyle(Color.secondary.opacity(0.14))
    }
}

private struct CustomizeToolsView: View {
    @Binding var orderRaw: String
    @Binding var hiddenRaw: String
    @Environment(\.dismiss) private var dismiss

    @State private var order: [ToolID] = []
    @State private var hidden: Set<ToolID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { tool in
                        Toggle(isOn: Binding(get: { !hidden.contains(tool) },
                                             set: { if $0 { hidden.remove(tool) } else { hidden.insert(tool) } })) {
                            Label(tool.title, systemImage: tool.symbol)
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to reorder. Turn off tools you don't use.")
                }
                Section {
                    Button("Restore default order") {
                        order = ToolID.defaultOrder
                        hidden = []
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        orderRaw = order.map(\.rawValue).joined(separator: ",")
                        hiddenRaw = hidden.map(\.rawValue).joined(separator: ",")
                        dismiss()
                    }
                }
            }
            .onAppear {
                order = ToolID.resolveOrder(orderRaw)
                hidden = Set(hiddenRaw.split(separator: ",").compactMap { ToolID(rawValue: String($0)) })
            }
        }
    }
}

struct DiagnosticsView: View {
    @Environment(\.modelContext) private var context
    @Query private var supplies: [SupplyItem]
    @Query private var members: [HouseholdMember]
    @Query private var notes: [Note]
    @Query private var contacts: [EmergencyContact]
    @Query private var pins: [MapPin]

    @AppStorage(SupplySettings.includeExpiredKey) private var includeExpired = false
    @State private var blocked = NetworkBlocker.blocked
    @State private var testResult: String?
    @State private var shareURL: ShareItem?
    @State private var showImporter = false
    @State private var pendingImport: BackupFile?
    @State private var message: String?
    @State private var pendingReminders: Int?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
    }

    var body: some View {
        List {
            Section("About") {
                LabeledContent("App", value: "DayZero")
                LabeledContent("Version", value: version)
                LabeledContent("Build phase", value: "6 — Apps tab (all phases done)")
                LabeledContent("Map data date", value: MapBundle.dataDate ?? "Not bundled")
                LabeledContent("Map coverage", value: "Washington, zoom 0–14")
                if let places = MapBundle.manifest?.places {
                    LabeledContent("Places & facilities", value: places.values.reduce(0, +).formatted())
                }
                Text("Map data © OpenStreetMap contributors. Available under the Open Database License.")
                    .font(.footnote)
            }

            Section {
                Button("Export all data (JSON)", systemImage: "square.and.arrow.up") { exportJSON() }
                Button("Import from backup…", systemImage: "square.and.arrow.down") { showImporter = true }
                Button("Print sheet (PDF)", systemImage: "printer") { exportPDF() }
                if let message { Text(message).font(.footnote) }
            } header: {
                Text("Backup & print")
            } footer: {
                Text("Export saves members, notes, supplies, contacts and pins to one file for AirDrop or a USB drive. Import replaces everything on this phone. The PDF holds contacts, household and inventory on paper.")
            }

            Section {
                LabeledContent("Pending reminders", value: pendingReminders.map(String.init) ?? "…")
                Button("Send a test reminder in 10 seconds", systemImage: "bell") {
                    Task {
                        await Reminders.notifyNow(id: "test", title: "DayZero test reminder",
                                                  body: "Local notifications work, no network needed.", after: 10)
                        pendingReminders = await Reminders.pendingCount()
                    }
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Items with an expiry date remind you 30 and 7 days ahead, at 9 AM. You're also alerted when days of water or food drop into the red.")
            }

            Section("On-device data") {
                LabeledContent("Supply items", value: "\(supplies.count)")
                LabeledContent("  Food / Water / Tools",
                               value: SupplyKind.allCases.map { k in "\(supplies.filter { $0.kind == k }.count)" }.joined(separator: " / "))
                LabeledContent("Household members", value: "\(members.count)")
                LabeledContent("Notes", value: "\(notes.count)")
                LabeledContent("Emergency contacts", value: "\(contacts.count)")
                LabeledContent("Map pins", value: "\(pins.count)")
            }

            Section {
                LabeledContent("Network guard", value: NetworkBlocker.isActive ? "On (debug build)" : "Off")
                LabeledContent("Blocked requests", value: "\(blocked.count)")
                if NetworkBlocker.isActive {
                    Button("Test: try to reach example.com") { runTest() }
                    if let testResult { Text(testResult).font(.footnote) }
                }
                ForEach(blocked.reversed()) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.url).font(.caption.monospaced())
                        Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Offline guard")
            } footer: {
                Text("Debug builds fail and log every outgoing request, so a stray remote URL is caught in testing.")
            }
        }
        .navigationTitle("Settings")
        .task { pendingReminders = await Reminders.pendingCount() }
        .sheet(item: $shareURL) { ActivityView(items: [$0.url]) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do { pendingImport = try Backup.read(url) }
                catch { message = "That file isn't a DayZero backup." }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .confirmationDialog("Replace all data on this phone?",
                            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible, presenting: pendingImport) { file in
            Button("Replace with backup", role: .destructive) {
                do {
                    try Backup.restore(file, into: context)
                    message = "Restored: \(file.summary)."
                } catch {
                    message = "Import failed: \(error.localizedDescription)"
                }
            }
        } message: { file in
            Text("Backup from \(file.exportedAt.formatted(date: .abbreviated, time: .shortened)): \(file.summary). Everything currently on this phone will be replaced.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkBlocker.didBlock)) { _ in
            blocked = NetworkBlocker.blocked
        }
    }

    private func exportJSON() {
        do { shareURL = ShareItem(url: try Backup.export(from: context)) }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }

    private func exportPDF() {
        do { shareURL = ShareItem(url: try PrintableReport.make(from: context, includeExpired: includeExpired)) }
        catch { message = "PDF failed: \(error.localizedDescription)" }
    }

    private func runTest() {
        testResult = "Requesting…"
        URLSession.shared.dataTask(with: URL(string: "https://example.com")!) { _, _, error in
            DispatchQueue.main.async {
                if let error = error as? URLError, error.code == .notConnectedToInternet {
                    testResult = "Blocked ✓ (\(error.localizedDescription))"
                } else if let error {
                    testResult = "Failed differently: \(error.localizedDescription)"
                } else {
                    testResult = "⚠️ Request went through — guard is not working"
                }
            }
        }.resume()
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet (AirDrop, Files, Print…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
