//
//  APIEnvironment.swift
//  Hackysack
//

import Foundation

/// Which API the app talks to. Device builds always use production; simulator
/// builds default to the local dev server and can switch from Settings or the
/// welcome screen.
enum APIServer: String, CaseIterable, Identifiable {
    case localhost
    case production

    var id: Self { self }

    var title: String {
        switch self {
        case .localhost: "Localhost"
        case .production: "Production"
        }
    }

    /// Each server keeps its own session, so switching back and forth never
    /// signs out of either, and a token is never sent to a server that
    /// didn't issue it.
    nonisolated var keychainAccount: String {
        switch self {
        case .localhost: "session.localhost"
        case .production: "session"
        }
    }
}

enum APIEnvironment {
    static let productionURL = URL(string: "https://digisquare-api-production.up.railway.app")!

    #if targetEnvironment(simulator)
    private static let serverDefaultsKey = "APIServer"

    /// Changed only through `AuthManager.switchServer(to:)`, which also swaps
    /// the session to the new server's.
    static var server: APIServer = UserDefaults.standard.string(forKey: serverDefaultsKey)
        .flatMap(APIServer.init(rawValue:)) ?? .localhost {
        didSet {
            UserDefaults.standard.set(server.rawValue, forKey: serverDefaultsKey)
        }
    }

    /// Used until DevServerLocator has looked. Dev servers take the first
    /// free port from 3001 up (3000 is kept for manual testing), so the app
    /// never assumes a port: the locator probes and sets the one that serves
    /// this build's branch.
    static let defaultDevServerPort = 3000
    static var devServerPort = defaultDevServerPort

    static var baseURL: URL {
        switch server {
        case .localhost: URL(string: "http://localhost:\(devServerPort)")!
        case .production: productionURL
        }
    }
    #else
    static let server = APIServer.production
    static let baseURL = productionURL
    #endif
}
