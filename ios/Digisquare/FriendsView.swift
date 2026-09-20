//
//  FriendsView.swift
//  Digisquare
//

import SwiftUI

struct FriendsView: View {
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                CheckInFAB()
            }
            .navigationTitle("Friends")
        }
    }
}

#Preview {
    FriendsView()
}
