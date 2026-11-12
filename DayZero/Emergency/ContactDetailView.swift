import SwiftData
import SwiftUI
import UIKit

struct ContactDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppRouter.self) private var router
    @Bindable var contact: EmergencyContact

    @State private var editing = false
    @State private var confirmRemove = false
    @State private var copied: String?
    @State private var savedDate: Date?
    @State private var saving = false
    @State private var saveError: String?
    @State private var showSaved = false
    private var location = LocationProvider.shared

    init(contact: EmergencyContact) {
        self.contact = contact
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(contact.category.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(contact.name).font(.title2.weight(.bold))
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            if !contact.phone.isEmpty {
                Section("Phone") {
                    // Always shown as text, so it can be read out or dialed from another phone.
                    Text(contact.phone)
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CallButton(label: "Call", phone: contact.phone, prominent: contact.category == .emergency)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    copyButton("Copy number", value: contact.phone)
                }
            }

            if !contact.address.isEmpty || contact.latitude != nil {
                Section("Location") {
                    if !contact.address.isEmpty {
                        Text(contact.address).textSelection(.enabled)
                        copyButton("Copy address", value: contact.address)
                    }
                    if let lat = contact.latitude, let lon = contact.longitude {
                        LabeledContent("Coordinates") {
                            Text(DistanceFormat.coordinates(lat, lon)).monospacedDigit().textSelection(.enabled)
                        }
                        if let d = location.distance(toLatitude: lat, longitude: lon) {
                            LabeledContent("Distance", value: "\(DistanceFormat.miles(d)) straight line")
                        }
                        Button {
                            router.showOnMap(title: contact.name, latitude: lat, longitude: lon)
                        } label: {
                            Label("Show on map", systemImage: "map")
                        }
                    }
                }
            }

            if !contact.website.isEmpty {
                Section {
                    Text(contact.website)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if savedDate != nil {
                        Button {
                            showSaved = true
                        } label: {
                            Label("View saved copy", systemImage: "doc.richtext")
                        }
                    }
                    if let url = websiteURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                        Button {
                            Task { await savePage(url) }
                        } label: {
                            HStack {
                                Label(savedDate == nil ? "Save for offline" : "Update saved copy",
                                      systemImage: "arrow.down.circle")
                                if saving { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(saving)
                    }
                    copyButton("Copy web address", value: contact.website)
                } header: {
                    Text("Website")
                } footer: {
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    } else if let savedDate {
                        Text("Saved copy from \(savedDate.formatted(date: .abbreviated, time: .shortened)) works with no connection. Opening the live site needs a connection.")
                    } else {
                        Text("Opening the site needs a connection. Save a copy now, while you have one, to read it later offline.")
                    }
                }
            }

            if !contact.notes.isEmpty {
                Section("Notes") {
                    Text(contact.notes).textSelection(.enabled)
                }
            }

            Section {
                Button(contact.isFavorite ? "Remove from favorites" : "Add to favorites",
                       systemImage: contact.isFavorite ? "star.slash" : "star") {
                    contact.isFavorite.toggle()
                    try? context.save()
                }
                if contact.isBuiltIn {
                    if contact.isHidden {
                        Button("Show in list", systemImage: "eye") {
                            contact.isHidden = false
                            try? context.save()
                        }
                    } else {
                        Button("Hide from list", systemImage: "eye.slash", role: .destructive) { confirmRemove = true }
                    }
                } else {
                    Button("Delete contact", systemImage: "trash", role: .destructive) { confirmRemove = true }
                }
            } footer: {
                if contact.isBuiltIn {
                    Text(contact.userEdited
                         ? "Built-in entry, edited by you. App updates won't overwrite your changes."
                         : "Built-in entry. Verify numbers before relying on them.")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { editing = true }
            Button {
                contact.isFavorite.toggle()
                try? context.save()
            } label: {
                Label("Favorite", systemImage: contact.isFavorite ? "star.fill" : "star")
            }
            .tint(.yellow)
        }
        .sheet(isPresented: $editing) { ContactForm(contact: contact) }
        .confirmationDialog(contact.isBuiltIn ? "Hide “\(contact.name)”?" : "Delete “\(contact.name)”?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(contact.isBuiltIn ? "Hide contact" : "Delete contact", role: .destructive) {
                if contact.isBuiltIn {
                    contact.isHidden = true
                    try? context.save()
                } else {
                    SavedPages.delete(for: contact.id)
                    context.delete(contact)
                    try? context.save()
                }
                dismiss()
            }
        } message: {
            Text(contact.isBuiltIn
                 ? "You can bring it back with Sort and filter → Show hidden."
                 : "This can't be undone.")
        }
        .sheet(isPresented: $showSaved) { SavedPageView(id: contact.id, title: contact.name) }
        .onAppear {
            location.start()
            savedDate = SavedPages.savedDate(for: contact.id)
        }
        .onDisappear { location.stop() }
        .overlay(alignment: .bottom) {
            if let copied {
                Text(copied)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The one user-triggered network action in the app.
    private func savePage(_ url: URL) async {
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            try await SavedPages.save(url, for: contact.id)
            savedDate = SavedPages.savedDate(for: contact.id)
        } catch {
            saveError = "Couldn't save the page: \(error.localizedDescription)"
        }
    }

    private var websiteURL: URL? {
        let raw = contact.website.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button(title, systemImage: "doc.on.doc") {
            UIPasteboard.general.string = value
            withAnimation { copied = "Copied" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = nil } }
        }
    }
}
