//
//  APIEnvironment.swift
//  Hackysack
//

import Foundation

enum APIEnvironment {
    #if targetEnvironment(simulator)
    /// Used until DevServerLocator has looked. Dev servers take the first
    /// free port from 3001 up (3000 is kept for manual testing), so the app
    /// never assumes a port: the locator probes and sets the one that serves
    /// this build's branch.
    static let defaultDevServerPort = 3000
    static var devServerPort = defaultDevServerPort

    static var baseURL: URL {
        URL(string: "http://localhost:\(devServerPort)")!
    }
    #else
    static let baseURL = URL(string: "https://digisquare-api-production.up.railway.app")!
    #endif
}
