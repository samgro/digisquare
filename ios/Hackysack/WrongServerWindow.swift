//
//  WrongServerWindow.swift
//  Hackysack
//

import SwiftUI

/// A slim notice that the dev server has moved on to a newer commit than
/// this build. Nothing is blocked; a rebuild clears it.
struct BuildMismatchBanner: View {
    let app: BuildIdentity
    let server: BuildIdentity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HackysackSpacing.small) {
            Image(systemName: Glyphs.buildMismatch)
            Text("Dev server is on \(server.commit); this build is \(app.commit). Rebuild to match.")
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .padding(HackysackSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, HackysackSpacing.medium)
    }
}

#if DEBUG && targetEnvironment(simulator)

/// Shows the block above everything, including sheets and full-screen
/// covers, which an overlay inside RootView would sit under.
@MainActor
enum WrongServerWindow {
    private static var window: UIWindow?

    static func sync(with gate: BuildGate) {
        if gate.isBlocking {
            show()
        } else {
            hide()
        }
    }

    private static func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let blocking = UIWindow(windowScene: scene)
        blocking.windowLevel = .alert + 1
        blocking.rootViewController = UIHostingController(rootView: WrongServerView())
        blocking.makeKeyAndVisible()
        window = blocking
    }

    private static func hide() {
        window?.isHidden = true
        window = nil
    }
}

struct WrongServerView: View {
    private var gate: BuildGate { BuildGate.shared }

    var body: some View {
        ContentUnavailableView {
            Label("Wrong Dev Server", systemImage: Glyphs.wrongServer)
        } description: {
            Text(description)
        } actions: {
            Button("Check Again") {
                Task { await gate.check() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var description: String {
        let app = gate.app?.wireValue ?? "an unstamped build"
        let serverLine = gate.server.map { "is running \($0.wireValue)" }
            ?? "did not say which build it is running, so it predates this check"
        return "This build is from \(app).\nThe server at \(APIEnvironment.baseURL.absoluteString) \(serverLine).\n\n"
            + "Start the dev server from this app's checkout, or rebuild the app from the server's branch."
    }
}

#else

@MainActor
enum WrongServerWindow {
    static func sync(with gate: BuildGate) {}
}

#endif
