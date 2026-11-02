import CoreLocation
import Foundation
import WallpaperCore

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var locating = false
    @Published private(set) var errorMessage: String?
    var onLocation: ((SolarLocation) -> Void)?
    var onCompletion: (() -> Void)?
    private let manager = CLLocationManager()
    private var requested = false
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestIfAuthorized() {
        if manager.authorizationStatus == .authorizedAlways {
            request()
        }
    }

    func request() {
        guard !locating else { return }
        requested = true
        locating = true
        errorMessage = nil
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.fail("Couldn’t determine your location. Try again, or enter coordinates below.")
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways: manager.requestLocation()
        default: fail("Location access is off. Allow Wallpaper Schedule in System Settings → Privacy & Security → Location Services, or enter coordinates below.")
        }
    }

    func cancel() {
        manager.stopUpdatingLocation()
        timeout?.cancel()
        timeout = nil
        requested = false
        locating = false
        errorMessage = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: fail("Location access was not allowed. You can enter coordinates instead.")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requested, let location = locations.last,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 3600 else { return }
        let coordinate = SolarLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        guard coordinate.isValid else { fail("macOS returned an invalid location. Try again."); return }
        cancel()
        onLocation?(coordinate)
        onCompletion?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requested else { return }
        fail("Couldn’t determine your location. Try again, or enter coordinates below.")
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
        onCompletion?()
    }
}
