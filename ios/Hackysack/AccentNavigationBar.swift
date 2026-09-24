//
//  AccentNavigationBar.swift
//  Hackysack
//

import SwiftUI

/// The app's navigation bar: solid accent with white text and glass buttons
/// floating on it, and a faint shadow where it meets the content. SwiftUI
/// scopes toolbar styling to the view it is attached to, so every screen
/// inside the Timeline and Friends stacks applies this itself; modals keep
/// the system look.
struct AccentNavigationBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(Color.accentColor, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // The bar draws no shadow of its own. The overlay respects the
            // safe area, so this sits just under the bar's bottom edge.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.14), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 6)
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func accentNavigationBar() -> some View {
        modifier(AccentNavigationBar())
    }
}
