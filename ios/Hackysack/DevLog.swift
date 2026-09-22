//
//  DevLog.swift
//  Hackysack
//

import OSLog

/// Diagnostic logging that only exists in debug builds. Messages go through
/// os.Logger so they show up in the Xcode console (and Console.app, filterable
/// by category), and compile away entirely in release.
enum DevLog {
    #if DEBUG
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Hackysack"
    private static let networkLogger = Logger(subsystem: subsystem, category: "network")
    private static let locationLogger = Logger(subsystem: subsystem, category: "location")
    #endif

    static func network(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        networkLogger.debug("\(text, privacy: .public)")
        #endif
    }

    static func location(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        locationLogger.debug("\(text, privacy: .public)")
        #endif
    }
}
