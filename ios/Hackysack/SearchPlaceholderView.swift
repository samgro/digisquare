//
//  SearchPlaceholderView.swift
//  Hackysack
//

import SwiftUI

/// Where the search bar leads until search is built.
struct SearchPlaceholderView: View {
    let title: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            "Search Isn't Ready Yet",
            systemImage: "magnifyingglass",
            description: Text(description)
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SearchPlaceholderView(title: "Search Checkins", description: "Searching your checkins is coming soon.")
    }
}
