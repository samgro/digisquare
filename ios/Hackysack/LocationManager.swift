import CoreLocation
import Observation

extension CLAuthorizationStatus {
    /// Readable name for logs; the raw value alone is an opaque integer.
    var debugName: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "authorizedAlways"
        case .authorizedWhenInUse: "authorizedWhenInUse"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let locationManager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var location: CLLocation?

    /// Receives every visit Core Location reports. Set once at launch by the
    /// app delegate, before any visit can arrive.
    @ObservationIgnored var onVisit: (@MainActor (CLVisit) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // Read after super.init(): @Observable turns this into a computed
        // setter that touches self, which is not available any earlier.
        authorizationStatus = locationManager.authorizationStatus
        // When a visit relaunches the app in the background, the pending event
        // is only delivered to a manager that is monitoring visits at launch.
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startMonitoringVisits()
        }
    }

    func requestPermissionsIfNeeded() {
        DevLog.location("requestPermissionsIfNeeded (status: \(locationManager.authorizationStatus.debugName))")
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startMonitoringVisits()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func requestWhenInUseAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    func startMonitoringVisits() {
        locationManager.startMonitoringVisits()
    }

    func stopMonitoringVisits() {
        locationManager.stopMonitoringVisits()
    }

    func startUpdatingLocation() {
        DevLog.location("startUpdatingLocation (status: \(locationManager.authorizationStatus.debugName))")
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        DevLog.location("stopUpdatingLocation")
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        DevLog.location("Authorization changed: \(manager.authorizationStatus.debugName), accuracy: \(manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced")")

        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.startMonitoringVisits()
        case .authorizedWhenInUse:
            // Visits won't be delivered reliably in the background yet, so
            // immediately ask to upgrade to Always.
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            manager.stopMonitoringVisits()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        DevLog.location("Visit: \(visit)")
        onVisit?(visit)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let latest = locations.last {
            DevLog.location(
                "Location update: \(latest.coordinate.latitude), \(latest.coordinate.longitude) "
                + "±\(Int(latest.horizontalAccuracy))m, age \(String(format: "%.1f", -latest.timestamp.timeIntervalSinceNow))s"
            )
        }
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DevLog.location("Location error: \(error)")
    }
}
