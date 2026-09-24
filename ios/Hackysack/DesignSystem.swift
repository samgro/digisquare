//
//  DesignSystem.swift
//  Hackysack
//

import SwiftUI

/// Spacing scale. Four steps is enough for every screen in the app; resist
/// adding a fifth until a third screen actually needs it.
enum HackysackSpacing {
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32
}

enum HackysackRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 16
}

enum HackysackSize {
    /// Matches the intrinsic height of SignInWithAppleButton, so the Apple
    /// button and our own buttons line up on the welcome screen.
    static let controlHeight: CGFloat = 50
    static let avatarLarge: CGFloat = 96
    static let avatarSmall: CGFloat = 40
}

// MARK: - Buttons

/// Shared chrome for both button styles.
///
/// The dimmed-when-disabled state has to be read inside a real View: a
/// ButtonStyle is not part of the view graph, so an @Environment property on
/// the style struct itself is never populated and would always report enabled.
private struct HackysackButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyle.Configuration
    let foreground: Color
    let background: Color

    var body: some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: HackysackSize.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                    .fill(background)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HackysackButtonBody(
            configuration: configuration,
            foreground: .white,
            background: Color.accentColor
        )
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HackysackButtonBody(
            configuration: configuration,
            foreground: Color.accentColor,
            background: Color.accentColor.opacity(0.12)
        )
    }
}

// MARK: - Avatar

/// Circular avatar that falls back to initials, so a user without a photo
/// still gets something identifiable rather than an empty ring.
struct AvatarView: View {
    let url: URL?
    let initials: String
    var size: CGFloat = HackysackSize.avatarSmall

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        initialsCircle
                    case .empty:
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            ProgressView()
                        }
                    @unknown default:
                        initialsCircle
                    }
                }
            } else {
                initialsCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var initialsCircle: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Forms

/// A labelled text field that can show a validation message underneath.
///
/// The error text comes from the API's `details.fieldErrors`.
struct AuthField: View {
    let label: String?
    @Binding var text: String
    var errorMessage: String?
    /// Optional, because .focused() binds the view it is applied to and does
    /// NOT propagate into a container's children — a caller putting it on an
    /// AuthField would silently focus nothing. The binding has to reach the
    /// inner field, so it is passed in.
    var focusBinding: FocusState<Bool>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: HackysackSpacing.small / 2) {
            if let label {
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Group {
                if let focusBinding {
                    field.focused(focusBinding)
                } else {
                    field
                }
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, HackysackSpacing.medium)
            .frame(height: HackysackSize.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                    .strokeBorder(errorMessage == nil ? Color.clear : Color.red, lineWidth: 1)
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var field: some View {
        TextField("", text: $text)
    }
}

/// Top-level form error — the API's `{error}` string, shown as a sentence.
struct FormErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HackysackSpacing.small) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.red)
        .padding(HackysackSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
    }
}

#Preview {
    VStack(spacing: HackysackSpacing.large) {
        AvatarView(url: nil, initials: "SG", size: HackysackSize.avatarLarge)
        AuthField(label: "Name", text: .constant("Sam"))
        AuthField(label: "Bio", text: .constant(""), errorMessage: "At most 160 characters")
        FormErrorBanner(message: "Couldn't save your profile")
        Button("Continue") {}.buttonStyle(PrimaryButtonStyle())
        Button("Log In as Test User") {}.buttonStyle(SecondaryButtonStyle())
    }
    .padding()
}
