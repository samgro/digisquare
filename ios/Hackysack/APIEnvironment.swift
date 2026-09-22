//
//  APIEnvironment.swift
//  Hackysack
//

import Foundation

enum APIEnvironment {
    static let baseURL: URL = {
        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://digisquare-api-production.up.railway.app")!
        #endif
    }()
}
