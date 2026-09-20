import Combine
import CoreLocation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var location: CLLocation?

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermissionsIfNeeded() {
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
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

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
        print("CLVisit: \(visit)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager error: \(error)")
    }
}
