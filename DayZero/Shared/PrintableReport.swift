import SwiftData
import UIKit

/// A paper copy of contacts, household members and inventory. Paper works when the phone doesn't.
enum PrintableReport {
    @MainActor
    static func make(from context: ModelContext, includeExpired: Bool, now: Date = .now) throws -> URL {
        let members = try context.fetch(FetchDescriptor<HouseholdMember>(sortBy: [SortDescriptor(\.name)]))
        let contacts = try context.fetch(FetchDescriptor<EmergencyContact>(sortBy: [SortDescriptor(\.name)])).filter { !$0.isHidden }
        let items = try context.fetch(FetchDescriptor<SupplyItem>(sortBy: [SortDescriptor(\.sortOrder)])).filter { !$0.isHidden }
        let summary = DaysRemainingCalculator.summarize(items: items, members: members, includeExpired: includeExpired, now: now)

        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let writer = PDFWriter(page: page)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            writer.ctx = ctx
            writer.newPage()

            writer.text("DayZero household emergency sheet", .title)
            writer.text("Printed \(now.formatted(date: .long, time: .shortened)). Call \(ContactPacks.emergencyNumber()) for emergencies.", .caption)
            writer.space(10)

            // Summary
            writer.text("Supplies at a glance", .heading)
            if summary.activeMembers == 0 {
                writer.text("No active household members.", .body)
            } else {
                let w = summary.daysOfWater.map(DaysRemainingCalculator.wholeDays) ?? 0
                let f = summary.daysOfFood.map(DaysRemainingCalculator.wholeDays) ?? 0
                writer.text("Water: \(w) days (\(summary.totalGallons.formatted(.number.precision(.fractionLength(0...1)))) gal)    Food: \(f) days (\(Int(summary.totalCalories).formatted()) cal)    for \(summary.activeMembers) people", .bodyBold)
            }
            writer.text("\(summary.toolsStocked) of \(summary.toolsInCatalog) catalog tools stocked.", .body)
            writer.space(8)

            // Household
            writer.text("Household", .heading)
            if members.isEmpty { writer.text("None recorded.", .body) }
            for m in members {
                var line = m.name
                if !m.relationship.isEmpty { line += " (\(m.relationship))" }
                if m.gender != .notSelected { line += ", \(m.gender.title.lowercased())" }
                if let age = m.age { line += ", age \(age)" }
                if !m.phone.isEmpty { line += "   \(m.phone)" }
                if !m.isActive { line += " — away" }
                writer.text(line, .bodyBold)
                writer.text("Needs \(Int(m.dailyCalories).formatted()) cal and \(m.dailyWaterGallons.formatted()) gal water per day", .small)
                if !m.notes.isEmpty { writer.text(m.notes, .small) }
                writer.space(3)
            }
            writer.space(8)

            // Contacts
            writer.text("Emergency contacts", .heading)
            let ordered = contacts.filter(\.isFavorite) + ContactCategory.allCases.flatMap { cat in
                contacts.filter { !$0.isFavorite && $0.category == cat }
            }
            for c in ordered {
                let phone = c.phone.isEmpty ? "" : "   \(c.phone)"
                writer.text("\(c.isFavorite ? "★ " : "")\(c.name)\(phone)", .bodyBold)
                var detail = [c.category.title]
                if !c.address.isEmpty { detail.append(c.address) }
                if let lat = c.latitude, let lon = c.longitude { detail.append(DistanceFormat.coordinates(lat, lon)) }
                if !c.website.isEmpty { detail.append(c.website) }
                writer.text(detail.joined(separator: " · "), .small)
                writer.space(2)
            }
            writer.space(8)

            // Inventory
            writer.text("Supply inventory", .heading)
            let sections: [(String, [SupplyItem])] =
                FoodGroup.allCases.map { g in (g.title, items.filter { $0.kind == .food && $0.foodGroup == g }) }
                + [("Water", items.filter { $0.kind == .water })]
                + ToolGroup.allCases.map { g in (g.title, items.filter { $0.kind == .tool && $0.toolGroup == g }) }
            for (title, ofKind) in sections {
                let stocked = ofKind.filter { $0.quantity > 0 }
                writer.text(title, .subheading)
                if stocked.isEmpty { writer.text("Nothing stocked.", .small) }
                for i in stocked {
                    var line = "\(i.quantity.formatted(.number.precision(.fractionLength(0...2)))) × \(i.unit) — \(i.name)"
                    var extra: [String] = []
                    if let e = i.expiresOn {
                        extra.append((i.isExpired(on: now) ? "EXPIRED " : "exp ") + e.formatted(date: .abbreviated, time: .omitted))
                    }
                    if !i.storageLocation.isEmpty { extra.append(i.storageLocation) }
                    if !extra.isEmpty { line += "  (\(extra.joined(separator: ", ")))" }
                    writer.text(line, .body)
                }
                let missing = ofKind.filter { $0.quantity == 0 }.map(\.name)
                if !missing.isEmpty { writer.text("Not stocked: " + missing.joined(separator: ", "), .small) }
                writer.space(6)
            }
        }

        let day = now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayZero-sheet-\(day).pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

private final class PDFWriter {
    enum Style { case title, heading, subheading, body, bodyBold, small, caption }

    let page: CGRect
    let margin: CGFloat = 44
    var ctx: UIGraphicsPDFRendererContext?
    private var y: CGFloat = 0
    private var pageNumber = 0

    init(page: CGRect) { self.page = page }

    func newPage() {
        ctx?.beginPage()
        pageNumber += 1
        y = margin
        let footer = NSAttributedString(string: "DayZero · page \(pageNumber)",
                                        attributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray])
        footer.draw(at: CGPoint(x: margin, y: page.height - margin + 14))
    }

    func space(_ h: CGFloat) { y += h }

    func text(_ s: String, _ style: Style) {
        let font: UIFont = switch style {
        case .title: .systemFont(ofSize: 20, weight: .bold)
        case .heading: .systemFont(ofSize: 14, weight: .bold)
        case .subheading: .systemFont(ofSize: 11, weight: .semibold)
        case .body: .systemFont(ofSize: 10)
        case .bodyBold: .systemFont(ofSize: 10, weight: .semibold)
        case .small: .systemFont(ofSize: 8.5)
        case .caption: .italicSystemFont(ofSize: 9)
        }
        let color: UIColor = style == .small || style == .caption ? .darkGray : .black
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let width = page.width - margin * 2
        let h = ceil(str.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        // Keep headings with at least a little of their content.
        let needed = h + (style == .heading || style == .subheading ? 40 : 0)
        if y + needed > page.height - margin { newPage() }
        if style == .heading { y += 2 }
        str.draw(with: CGRect(x: margin, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        y += h + (style == .heading ? 4 : 1)
    }
}
