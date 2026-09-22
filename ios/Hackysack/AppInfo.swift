//
//  AppInfo.swift
//  Hackysack
//

import Foundation

enum AppInfo {
    /// The user-facing product name. The source of truth is the
    /// `INFOPLIST_KEY_CFBundleDisplayName` build setting, so the home screen,
    /// the permission prompts and in-app copy can never disagree. Rename the
    /// product there, not here.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
}
