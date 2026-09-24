//
//  AppDelegate.swift
//  Hackysack
//

import UIKit

/// Owns the objects that must exist the moment the process starts. Core
/// Location can relaunch the app in the background to deliver a visit, and in
/// that case no SwiftUI scene is created, so the location manager, the store
/// the suggestion lands in, and the processor between them cannot live in a
/// view's `@StateObject`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let locationManager: LocationManager
    let checkinStore: CheckinStore
    let visitProcessor: VisitProcessor

    /// Unit tests run inside the app process; they get in-memory stores and no
    /// visit monitoring so they never touch the simulator's files or network.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    override init() {
        locationManager = LocationManager()
        if Self.isRunningTests {
            checkinStore = .inMemory()
        } else {
            checkinStore = CheckinStore()
        }
        visitProcessor = VisitProcessor(visitHistory: checkinStore.visitHistory, checkinStore: checkinStore)
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !Self.isRunningTests else { return true }
        locationManager.onVisit = { [visitProcessor] visit in
            visitProcessor.process(visit)
        }
        checkinStore.visitHistory.prune()
        return true
    }

    /// A defensive re-arm point: if visit monitoring silently stopped while
    /// the process stayed alive in the background (no authorization change,
    /// no relaunch), coming to the foreground is the next chance to notice
    /// and restart it.
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !Self.isRunningTests else { return }
        locationManager.requestPermissionsIfNeeded()
    }
}
