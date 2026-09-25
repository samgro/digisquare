//
//  EditCheckinView.swift
//  Hackysack
//

import SwiftUI

/// Edits what can change after checking in: the message and who sees it.
/// The place is shown but fixed, since a checkin is a record of having been
/// somewhere. Modeled on EditProfileView: Cancel asks before discarding, Save
/// only lights up for a real change.
struct EditCheckinView: View {
    let checkin: Checkin

    @Environment(CheckinSocialStore.self) private var socialStore
    @Environment(\.dismiss) private var dismiss

    @State private var message: String
    @State private var visibility: CheckinVisibility
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false

    /// Matches the server's z.string().max(2000).
    private static let messageCharacterLimit = 2000

    init(checkin: Checkin) {
        self.checkin = checkin
        _message = State(initialValue: checkin.message ?? "")
        _visibility = State(initialValue: checkin.visibility)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        trimmedMessage != (checkin.message ?? "") || visibility != checkin.visibility
    }

    private var isMessageOverLimit: Bool {
        message.count > Self.messageCharacterLimit
    }

    private var canSave: Bool {
        isDirty && !isMessageOverLimit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PlaceIconView(primaryType: checkin.placePrimaryType)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(checkin.placeName)
                                .font(.headline)
                            if let placeAddress = checkin.placeAddress {
                                Text(placeAddress)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("The place can't be changed.")
                }

                Section {
                    TextField("What's happening here?", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Message")
                } footer: {
                    Text("\(message.count)/\(Self.messageCharacterLimit)")
                        .foregroundStyle(isMessageOverLimit ? .red : .secondary)
                }

                Section {
                    Picker("Visibility", selection: $visibility) {
                        Text("Friends").tag(CheckinVisibility.friends)
                        Text("Private").tag(CheckinVisibility.onlyMe)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Visibility")
                } footer: {
                    Text(visibility.isPrivate ? "Only you can see this checkin." : "Your friends can see this checkin.")
                }

                if let errorMessage {
                    Section {
                        FormErrorBanner(message: errorMessage)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .navigationTitle("Edit Checkin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog(
                "Discard your changes?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .disabled(isSaving)
        }
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await socialStore.edit(
                    checkin,
                    update: CheckinUpdate(message: trimmedMessage, visibility: visibility)
                )
                dismiss()
            } catch let error as APIError {
                errorMessage = error.message(forField: "message") ?? error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

#Preview {
    EditCheckinView(checkin: .preview())
        .environment(CheckinSocialStore())
}
