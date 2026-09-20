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
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.blue))
        }
        .shadow(radius: 4)
        .padding()
        .fullScreenCover(isPresented: $showingCheckIn) {
            CheckInView()
        }
    }
}
