//
//  CheckInFAB.swift
//  Digisquare
//

import SwiftUI

struct CheckInFAB: View {
    @State private var showingCheckIn = false

    var body: some View {
        Button {
            showingCheckIn = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(.blue)
        .accessibilityLabel("Check In")
        .padding()
        .fullScreenCover(isPresented: $showingCheckIn) {
            CheckInView()
        }
    }
}
