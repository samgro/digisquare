//
//  APIEnvironment.swift
//  Hackysack
//

import Foundation

enum APIEnvironment {
    #if targetEnvironment(simulator)
    /// Where a dev server starts looking for a free port. Several checkouts
    /// run at once, each one port up from the last, so the simulator app
    /// does not assume this: DevServerLocator probes and sets the port that
    /// serves this build's branch.
    static let defaultDevServerPort = 3000
    static var devServerPort = defaultDevServerPort

    static var baseURL: URL {
        URL(string: "http://localhost:\(devServerPort)")!
    }
    #else
    static let baseURL = URL(string: "https://digisquare-api-production.up.railway.app")!
    #endif
}
