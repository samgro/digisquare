//
//  TimelineView.swift
//  Digisquare
//

import SwiftUI

struct TimelineView: View {
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                CheckInFAB()
            }
            .navigationTitle("Timeline")
        }
    }
}

#Preview {
    TimelineView()
}
