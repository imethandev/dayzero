import MapLibre
import OSLog
import SwiftUI

/// A marker the SwiftUI side asks the map to draw (emergency contacts and custom pins).
struct MapMarker: Equatable {
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let icon: String
}

/// What the user tapped on the map.
struct MapSelection: Equatable, Identifiable {
    enum Source: String { case facility, contact, pin }
    let source: Source
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
}

/// MapLibre map rendered entirely from Map.bundle. No network.
struct MapLibreView: UIViewRepresentable {
    let styleURL: URL
    /// Shows the blue dot (and runs MapLibre's GPS) only while the tab is visible.
    var showsUserLocation: Bool
    /// Incremented by the re-center button.
    var recenterToken: Int
    var focus: MapFocus?
    var enabledLayers: Set<FacilityLayer>
    var contacts: [MapMarker]
    var pins: [MapMarker]
    var onRecenterFailed: () -> Void = {}
    var onSelect: (MapSelection?) -> Void = { _ in }
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        // Our own "© OpenStreetMap contributors" label replaces the info button,
        // whose sheet links out to websites.
        map.attributionButton.isHidden = true
        map.showsScale = true
        map.compassView.compassVisibility = .visible
        // Below the search bar overlay.
        map.compassViewMargins = CGPoint(x: 12, y: 12)
        map.scaleBarMargins = CGPoint(x: 12, y: 14)
        map.minimumZoomLevel = 5
        map.maximumZoomLevel = 19
        map.allowsTilting = false
        map.tintColor = .systemBlue // blue location dot, as the spec asks

        // Whole state until a GPS fix arrives.
        let (sw, ne) = MapBundle.bounds
        map.setCenter(CLLocationCoordinate2D(latitude: (sw.latitude + ne.latitude) / 2,
                                             longitude: (sw.longitude + ne.longitude) / 2 + 0.6),
                      zoomLevel: 5.6, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for recognizer in map.gestureRecognizers ?? [] {
            if let t = recognizer as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 {
                tap.require(toFail: t)
            }
        }
        map.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.5
        map.addGestureRecognizer(press)

        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if map.styleURL != styleURL { map.styleURL = styleURL }
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }

        if recenterToken != c.lastRecenterToken {
            c.lastRecenterToken = recenterToken
            if !c.recenter(on: map) { onRecenterFailed() }
        }
        if focus?.id != c.lastFocusID {
            c.lastFocusID = focus?.id
            c.show(focus, on: map)
        }
        c.applyLayerFilter()
        c.applyMarkers()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let log = Logger(subsystem: AppInfo.bundleID, category: "map")
        var parent: MapLibreView
        weak var map: MLNMapView?
        var lastRecenterToken = 0
        var lastFocusID: UUID?
        private var hasCenteredOnUser = false
        private var focusAnnotation: MLNPointAnnotation?
        private var appliedLayers: Set<FacilityLayer>?
        private var appliedContacts: [MapMarker]?
        private var appliedPins: [MapMarker]?
        private lazy var facilities: [Place] = PlacesDatabase.shared.allFacilities()

        static let facilityLayerID = "dz-facilities"
        static let minorFacilityLayerID = "dz-facilities-minor"
        /// With every category on, these show from zoom 9 and the rest (clinics, pharmacies, fuel,
        /// water) from zoom 13 to avoid clutter. A single chosen category shows from zoom 9.
        static let majorKinds: Set<PlaceKind> = [.hospital, .fire_station, .police, .shelter]
        static let contactLayerID = "dz-contacts"
        static let pinLayerID = "dz-pins"

        init(_ parent: MapLibreView) { self.parent = parent }

        // Keep the camera over the bundled data, so nobody pans into blank map.
        func mapView(_ mapView: MLNMapView, shouldChangeFrom oldCamera: MLNMapCamera, to newCamera: MLNMapCamera) -> Bool {
            MapBundle.contains(newCamera.centerCoordinate)
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !hasCenteredOnUser, lastFocusID == nil,
                  let c = userLocation?.location?.coordinate, CLLocationCoordinate2DIsValid(c),
                  MapBundle.contains(c) else { return }
            hasCenteredOnUser = true
            mapView.setCenter(c, zoomLevel: 12, animated: true)
        }

        @discardableResult
        func recenter(on map: MLNMapView) -> Bool {
            guard let c = map.userLocation?.location?.coordinate, CLLocationCoordinate2DIsValid(c) else { return false }
            guard MapBundle.contains(c) else { return false }
            map.setCenter(c, zoomLevel: max(map.zoomLevel, 13), direction: 0, animated: true)
            return true
        }

        func show(_ focus: MapFocus?, on map: MLNMapView) {
            if let old = focusAnnotation {
                map.removeAnnotation(old)
                focusAnnotation = nil
            }
            guard let focus else { return }
            let c = CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude)
            let pin = MLNPointAnnotation()
            pin.coordinate = c
            pin.title = focus.title
            map.addAnnotation(pin)
            focusAnnotation = pin
            map.setCenter(c, zoomLevel: max(map.zoomLevel, 14), animated: true)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        // MARK: Style content

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            for (name, image) in MapIcons.all { style.setImage(image, forName: name) }

            let facilityFeatures: [MLNPointFeature] = facilities.compactMap { place in
                guard let layer = place.kind.layer else { return nil }
                let f = MLNPointFeature()
                f.coordinate = place.coordinate
                f.attributes = ["source": "facility", "id": String(place.id), "name": place.name,
                                "icon": MapIcons.name(for: place.kind), "layer": layer.rawValue,
                                "major": Self.majorKinds.contains(place.kind)]
                return f
            }
            let facilitySource = MLNShapeSource(identifier: "dz-facilities", features: facilityFeatures, options: nil)
            style.addSource(facilitySource)
            let minorLayer = symbolLayer(Self.minorFacilityLayerID, source: facilitySource, overlap: false)
            minorLayer.minimumZoomLevel = 13
            minorLayer.text = NSExpression(format: "mgl_step:from:stops:($zoomLevel, '', %@)",
                                           [15: NSExpression(forKeyPath: "name")])
            style.addLayer(minorLayer)
            let facilityLayer = symbolLayer(Self.facilityLayerID, source: facilitySource, overlap: false)
            facilityLayer.minimumZoomLevel = 9
            facilityLayer.text = NSExpression(format: "mgl_step:from:stops:($zoomLevel, '', %@)",
                                              [13: NSExpression(forKeyPath: "name")])
            style.addLayer(facilityLayer)

            let contactSource = MLNShapeSource(identifier: "dz-contacts", features: [], options: nil)
            style.addSource(contactSource)
            style.addLayer(symbolLayer(Self.contactLayerID, source: contactSource, overlap: true, labelAlways: true))

            let pinSource = MLNShapeSource(identifier: "dz-pins", features: [], options: nil)
            style.addSource(pinSource)
            style.addLayer(symbolLayer(Self.pinLayerID, source: pinSource, overlap: true, labelAlways: true))

            appliedLayers = nil
            appliedContacts = nil
            appliedPins = nil
            applyLayerFilter()
            applyMarkers()
            log.info("Style loaded: \(style.name ?? "?", privacy: .public), \(facilityFeatures.count) facilities")
        }

        private func symbolLayer(_ id: String, source: MLNSource, overlap: Bool, labelAlways: Bool = false) -> MLNSymbolStyleLayer {
            let layer = MLNSymbolStyleLayer(identifier: id, source: source)
            layer.iconImageName = NSExpression(forKeyPath: "icon")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: overlap)
            layer.iconIgnoresPlacement = NSExpression(forConstantValue: overlap)
            if labelAlways { layer.text = NSExpression(forKeyPath: "name") }
            layer.textFontNames = NSExpression(forConstantValue: ["NotoSans-Bold"])
            layer.textFontSize = NSExpression(forConstantValue: 12)
            layer.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.6)))
            layer.textAnchor = NSExpression(forConstantValue: "top")
            layer.textOptional = NSExpression(forConstantValue: true)
            layer.textColor = NSExpression(forConstantValue: UIColor.label)
            layer.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
            layer.textHaloWidth = NSExpression(forConstantValue: 1.5)
            return layer
        }

        func applyLayerFilter() {
            guard let style = map?.style,
                  let major = style.layer(withIdentifier: Self.facilityLayerID) as? MLNSymbolStyleLayer,
                  let minor = style.layer(withIdentifier: Self.minorFacilityLayerID) as? MLNSymbolStyleLayer,
                  appliedLayers != parent.enabledLayers else { return }
            appliedLayers = parent.enabledLayers
            let layers = parent.enabledLayers.map(\.rawValue)
            if parent.enabledLayers.count == FacilityLayer.allCases.count {
                // Everything on: hospitals, fire, police and shelters from zoom 9, the busier kinds from zoom 13.
                major.isVisible = true
                minor.isVisible = true
                major.predicate = NSPredicate(format: "major == YES")
                minor.predicate = NSPredicate(format: "major == NO")
            } else {
                // A chosen category (Fuel, Pharmacies…) shows from zoom 9 too, so it never looks empty.
                major.isVisible = !layers.isEmpty
                minor.isVisible = false
                major.predicate = NSPredicate(format: "layer IN %@", layers)
            }
        }

        func applyMarkers() {
            guard let style = map?.style else { return }
            if appliedContacts != parent.contacts, let src = style.source(withIdentifier: "dz-contacts") as? MLNShapeSource {
                appliedContacts = parent.contacts
                src.shape = MLNShapeCollectionFeature(shapes: features(parent.contacts, source: "contact"))
            }
            if appliedPins != parent.pins, let src = style.source(withIdentifier: "dz-pins") as? MLNShapeSource {
                appliedPins = parent.pins
                src.shape = MLNShapeCollectionFeature(shapes: features(parent.pins, source: "pin"))
            }
        }

        private func features(_ markers: [MapMarker], source: String) -> [MLNPointFeature] {
            markers.map { m in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: m.latitude, longitude: m.longitude)
                f.attributes = ["source": source, "id": m.id, "name": m.title, "icon": m.icon]
                return f
            }
        }

        // MARK: Gestures

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let hits = map.visibleFeatures(in: rect, styleLayerIdentifiers: [Self.pinLayerID, Self.contactLayerID, Self.facilityLayerID, Self.minorFacilityLayerID])
            let best = hits.min { a, b in
                let pa = map.convert(a.coordinate, toPointTo: map), pb = map.convert(b.coordinate, toPointTo: map)
                return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
            }
            guard let best,
                  let sourceRaw = best.attribute(forKey: "source") as? String,
                  let source = MapSelection.Source(rawValue: sourceRaw),
                  let id = best.attribute(forKey: "id") as? String else {
                parent.onSelect(nil)
                return
            }
            parent.onSelect(MapSelection(source: source, id: id,
                                         title: best.attribute(forKey: "name") as? String ?? "",
                                         latitude: best.coordinate.latitude, longitude: best.coordinate.longitude))
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let map, gesture.state == .began else { return }
            let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            guard MapBundle.contains(c) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(c)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            log.error("Map failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }
}
