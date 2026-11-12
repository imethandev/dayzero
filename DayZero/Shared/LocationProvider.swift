import CoreLocation
import Foundation
import Observation

/// One shared Core Location wrapper. GPS works without any network.
/// Screens call `start()` when they become visible and `stop()` when they
/// leave, so the GPS only runs while something on screen needs it.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private(set) var location: CLLocation?
    private(set) var heading: CLHeading?
    private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var users = 0
    private var headingUsers = 0
    private var preciseUsers = 0

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Ask for When In Use permission if it hasn't been decided yet.
    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        users += 1
        requestPermission()
        if isAuthorized { manager.startUpdatingLocation() }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { manager.stopUpdatingLocation() }
    }

    /// Compass heading. Uses the magnetometer, so it works offline.
    func startHeading() {
        headingUsers += 1
        manager.headingFilter = 1
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        headingUsers = max(0, headingUsers - 1)
        if headingUsers == 0 { manager.stopUpdatingHeading() }
    }

    static var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    /// Best accuracy (for the Coordinates tool); falls back to battery-friendly accuracy when done.
    func startPrecise() {
        preciseUsers += 1
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        start()
    }

    func stopPrecise() {
        preciseUsers = max(0, preciseUsers - 1)
        if preciseUsers == 0 {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
        stop()
    }

    func distance(toLatitude lat: Double?, longitude lon: Double?) -> CLLocationDistance? {
        guard let location, let lat, let lon else { return nil }
        return location.distance(from: CLLocation(latitude: lat, longitude: lon))
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized && users > 0 { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { location = last }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known fix; a failure here (e.g. no GPS indoors) is not fatal.
    }
}

enum DistanceFormat {
    static func miles(_ meters: CLLocationDistance) -> String {
        let miles = Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles).value
        if miles < 0.1 { return "< 0.1 mi" }
        return miles < 10
            ? "\(miles.formatted(.number.precision(.fractionLength(1)))) mi"
            : "\(Int(miles.rounded()).formatted()) mi"
    }

    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        "\(lat.formatted(.number.precision(.fractionLength(5)))), \(lon.formatted(.number.precision(.fractionLength(5))))"
    }
}
