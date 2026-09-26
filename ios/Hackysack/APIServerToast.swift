//
//  APIServerToast.swift
//  Hackysack
//

import SwiftUI

#if targetEnvironment(simulator)

/// A few seconds' notice at launch that this simulator build is not talking
/// to the local dev server, the way it does by default. Without it, a build
/// left on production shows old code's results with nothing to say so.
struct APIServerToast: View {
    let server: APIServer

    var body: some View {
        HStack(spacing: HackysackSpacing.small) {
            Image(systemName: Glyphs.apiServer)
            Text("Using the \(server.title) API")
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(HackysackSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                .fill(Color.accentColor)
        )
        .padding(.horizontal, HackysackSpacing.medium)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the toast for a moment whenever the app comes up on, or is switched
/// to, a server other than the default.
struct APIServerToastModifier: ViewModifier {
    @Environment(AuthManager.self) private var authManager
    @State private var shownServer: APIServer?

    private static let duration: Duration = .seconds(3)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shownServer {
                    APIServerToast(server: shownServer)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: shownServer)
            .task(id: authManager.server) {
                guard authManager.server != .localhost else {
                    shownServer = nil
                    return
                }
                shownServer = authManager.server
                try? await Task.sleep(for: Self.duration)
                guard !Task.isCancelled else { return }
                shownServer = nil
            }
    }
}

extension View {
    /// A brief notice when this simulator build is not on the local server.
    func apiServerToast() -> some View {
        modifier(APIServerToastModifier())
    }
}

#Preview {
    VStack {
        APIServerToast(server: .production)
        Spacer()
    }
    .padding(.top)
}

#else

extension View {
    /// Device builds always use production, so there is nothing to say.
    func apiServerToast() -> some View {
        self
    }
}

#endif
