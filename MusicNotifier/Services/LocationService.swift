//
//  LocationService.swift
//  MusicNotifier
//
//  Thin wrapper over CoreLocation for the Concerts "Nearby" filter. We don't
//  need streaming updates — one fix on demand is enough. The last known
//  coordinate is cached in UserDefaults so the Concerts tab doesn't sit
//  waiting for a fresh GPS lock on every open.
//

import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var oneShotContinuation: CheckedContinuation<CLLocation?, Never>?

    @Published var lastKnown: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        loadCachedLocation()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Request "When in Use" authorization. Idempotent — repeated calls are no-ops
    /// once the user has answered the prompt.
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot fix. Returns the freshest available coordinate (cached if we
    /// have one less than 10 minutes old), otherwise asks CoreLocation for
    /// a new one. Bails to nil if the user denied access.
    func currentLocation(maxAge: TimeInterval = 600) async -> CLLocation? {
        if let cached = lastKnown, Date().timeIntervalSince(cached.timestamp) < maxAge {
            return cached
        }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }
        return await withCheckedContinuation { cont in
            oneShotContinuation = cont
            manager.requestLocation()
        }
    }

    private func cacheLocation(_ loc: CLLocation) {
        lastKnown = loc
        let defaults = UserDefaults.standard
        defaults.set(loc.coordinate.latitude, forKey: AppSettings.cachedLatitude)
        defaults.set(loc.coordinate.longitude, forKey: AppSettings.cachedLongitude)
        defaults.set(loc.timestamp.timeIntervalSince1970, forKey: AppSettings.cachedLocationTimestamp)
    }

    private func loadCachedLocation() {
        let defaults = UserDefaults.standard
        let ts = defaults.double(forKey: AppSettings.cachedLocationTimestamp)
        guard ts > 0 else { return }
        let lat = defaults.double(forKey: AppSettings.cachedLatitude)
        let lon = defaults.double(forKey: AppSettings.cachedLongitude)
        lastKnown = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: ts)
        )
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            cacheLocation(loc)
            oneShotContinuation?.resume(returning: loc)
            oneShotContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            oneShotContinuation?.resume(returning: lastKnown)
            oneShotContinuation = nil
        }
    }
}
