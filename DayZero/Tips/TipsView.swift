import SwiftUI

// MARK: Content

/// Practical tips bundled with the app (Resources/Offline/tips.json), readable with no network.
struct TipsFile: Decodable {
    let version: Int
    let sections: [TipSection]

    static func load(bundle: Bundle = .main) throws -> TipsFile {
        guard let url = bundle.url(forResource: "tips", withExtension: "json")
            ?? bundle.url(forResource: "tips", withExtension: "json", subdirectory: "Offline")
        else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "tips.json"]) }
        return try JSONDecoder().decode(TipsFile.self, from: Data(contentsOf: url))
    }
}

struct TipSection: Decodable, Identifiable {
    let id: String
    let title: String
    let tint: String
    let tips: [Tip]

    var color: Color {
        switch tint {
        case "red": .red
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "teal": .teal
        default: .yellow
        }
    }
}

struct Tip: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let overview: String
    let safety: [String]
    let steps: [TipStep]
}

struct TipStep: Decodable, Hashable {
    let title: String
    let detail: String
}

// MARK: List

/// Tips (opened from Home): practical guides grouped by situation. Each opens a detail page.
struct TipsView: View {
    private static let bundled: TipsFile? = try? TipsFile.load()
    static var tipCount: Int { bundled?.sections.reduce(0) { $0 + $1.tips.count } ?? 0 }

    @State private var file: TipsFile? = TipsView.bundled
    @State private var query = ""

    var body: some View {
            List {
                ForEach(filteredSections) { section in
                    Section(section.title) {
                        ForEach(section.tips) { tip in
                            NavigationLink(value: tip) {
                                TipRow(tip: tip, tint: section.color)
                            }
                        }
                    }
                }
            }
            .overlay {
                if file == nil {
                    ContentUnavailableView("Tips unavailable", systemImage: "lightbulb.slash",
                                           description: Text("The tips file is missing from this build."))
                } else if filteredSections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Tips")
            .searchable(text: $query, prompt: "Search tips")
            .navigationDestination(for: Tip.self) { tip in
                TipDetailView(tip: tip, tint: lookup(tip.id)?.1.color ?? .orange)
            }
    }

    private var filteredSections: [TipSection] {
        guard let file else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return file.sections }
        return file.sections.compactMap { s in
            let tips = s.tips.filter { t in
                [t.title, t.summary, t.overview].contains { $0.localizedCaseInsensitiveContains(q) }
            }
            return tips.isEmpty ? nil : TipSection(id: s.id, title: s.title, tint: s.tint, tips: tips)
        }
    }

    private func lookup(_ id: String) -> (Tip, TipSection)? {
        for s in file?.sections ?? [] {
            if let t = s.tips.first(where: { $0.id == id }) { return (t, s) }
        }
        return nil
    }
}

private struct TipRow: View {
    let tip: Tip
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tip.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title).font(.headline)
                Text(tip.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Detail

struct TipDetailView: View {
    let tip: Tip
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                block("Overview", symbol: "info.circle.fill", color: tint) {
                    Text(tip.overview)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                block("Safety", symbol: "exclamationmark.triangle.fill", color: .orange) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(tip.safety, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.subheadline)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                block("\(tip.steps.count) things to do", symbol: "checklist", color: .green) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(tip.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(tint, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title).font(.headline)
                                    Text(step.detail)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                Text("General guidance for planning. Follow instructions from local officials, and call your local emergency number in an emergency.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(tip.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: tip.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title).font(.title2.weight(.bold))
                Text(tip.summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func block<Content: View>(_ title: String, symbol: String, color: Color,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color == .yellow ? Color.primary : color)
                .labelStyle(.titleAndIcon)
            content()
        }
    }
}
