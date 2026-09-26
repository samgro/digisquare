//
//  AutofocusSearchField.swift
//  Hackysack
//

import SwiftUI
import UIKit

/// A text field that is focused before the screen it's on appears, so the
/// keyboard rises in the same animation as a push or sheet rather than after
/// it. Neither `.searchable` nor `@FocusState` can do this: both focus only
/// once the screen has finished appearing.
struct AutofocusSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String

    func makeUIView(context: Context) -> AutofocusTextField {
        let textField = AutofocusTextField()
        textField.focusesWhenAddedToWindow = isFocused
        textField.placeholder = prompt
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        // Shown whenever there's text, even if focus briefly moves elsewhere.
        textField.clearButtonMode = .always
        textField.autocorrectionType = .no
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = true
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ textField: AutofocusTextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            textField.text = text
        }
        if isFocused && !textField.isFirstResponder && textField.window != nil {
            textField.becomeFirstResponder()
        } else if !isFocused && textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AutofocusSearchField

        init(parent: AutofocusSearchField) {
            self.parent = parent
        }

        @objc func textChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        /// Results update as you type, so Return has nothing to do and
        /// shouldn't put the keyboard away.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            false
        }
    }
}

/// The glass capsule search field at the top of a pushed search screen, such
/// as Add Friends or Search Checkins. Put it in a top safe area inset.
struct SearchHeaderField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Glyphs.search)
                .foregroundStyle(.secondary)
            AutofocusSearchField(
                text: $text,
                isFocused: $isFocused,
                prompt: prompt
            )
            // Full height so the clear button can have a 44pt tap target,
            // which also stands in for trailing padding.
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 2)
        .frame(height: 48)
        .contentShape(Capsule())
        .onTapGesture {
            isFocused = true
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
    }
}

final class AutofocusTextField: UITextField {
    /// Whether to focus the first time the field is added to a window. This
    /// happens before a screen starts animating in, which is what lets the
    /// keyboard animate up alongside it.
    var focusesWhenAddedToWindow = false

    /// The system clear button is only about 20pt square, too small to hit
    /// reliably, so this gives it the recommended 44pt with the icon centered.
    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        let side: CGFloat = 44
        return CGRect(x: bounds.maxX - side, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusesWhenAddedToWindow else { return }
        focusesWhenAddedToWindow = false
        becomeFirstResponder()
    }
}
