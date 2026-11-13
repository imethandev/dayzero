import UIKit

/// Round map markers drawn from SF Symbols at runtime, so no extra sprite files are needed.
enum MapIcons {
    static func name(for layer: FacilityLayer) -> String { "dz-\(layer.rawValue)" }
    /// Clinics get their own lighter icon so hospitals stand out.
    static func name(for kind: PlaceKind) -> String {
        switch kind {
        case .clinic: "dz-clinic"
        case .water_point: "dz-water-point"
        case .spring: "dz-spring"
        case .well: "dz-well"
        default: kind.layer.map { name(for: $0) } ?? "dz-medical"
        }
    }
    static func name(for place: Place) -> String {
        place.isNotDrinkable ? "dz-water-untreated" : name(for: place.kind)
    }
    static func name(for pin: MapPinKind) -> String { "dz-pin-\(pin.rawValue)" }
    static let contact = "dz-contact"

    static var all: [String: UIImage] {
        var out: [String: UIImage] = [:]
        for layer in FacilityLayer.allCases {
            out[name(for: layer)] = marker(symbol: layer.symbol, color: layer.color, size: 26)
        }
        for kind in MapPinKind.allCases {
            out[name(for: kind)] = marker(symbol: pinSymbol(kind), color: .systemIndigo, size: 32, ring: .systemYellow)
        }
        out["dz-clinic"] = marker(symbol: "stethoscope", color: UIColor.systemRed.withAlphaComponent(0.75), size: 22)
        out["dz-water-point"] = marker(symbol: "waterbottle.fill", color: .systemCyan, size: 26)
        out["dz-spring"] = marker(symbol: "leaf.fill", color: .systemTeal, size: 26)
        out["dz-well"] = marker(symbol: "spigot.fill", color: .systemTeal, size: 26)
        out["dz-water-untreated"] = marker(symbol: "drop.triangle.fill", color: .systemGray, size: 22)
        out[contact] = marker(symbol: "star.fill", color: .systemTeal, size: 30)
        return out
    }

    static func pinSymbol(_ kind: MapPinKind) -> String {
        switch kind {
        case .cache: "shippingbox.fill"
        case .meetingPoint: "person.3.fill"
        case .waterSource: "drop.fill"
        case .shelter: "house.fill"
        case .other: "mappin"
        }
    }

    static func marker(symbol: String, color: UIColor, size: CGFloat, ring: UIColor = .white) -> UIImage {
        let pad: CGFloat = 2
        let full = CGSize(width: size + pad * 2, height: size + pad * 2)
        return UIGraphicsImageRenderer(size: full).image { ctx in
            let rect = CGRect(x: pad, y: pad, width: size, height: size)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            ring.setFill()
            UIBezierPath(ovalIn: rect).fill()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            color.setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
            if let img = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let s = img.size
                img.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }
}
