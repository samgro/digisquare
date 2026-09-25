//
//  CommentsView.swift
//  Hackysack
//

import SwiftUI

/// One checkin's comment thread and the composer under it. The rows and the
/// composer are separate views over one model, so the half sheet stacks
/// them in a List while the detail page puts the rows inline in its scroll
/// view and the composer in its bottom inset.
@Observable
@MainActor
final class CommentsModel {
    let checkin: Checkin
    /// Oldest first, the way a thread reads.
    private(set) var comments: [CheckinComment] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var isSending = false
    var draft = ""
    var actionError: String?

    /// Set by the view that owns the model, so count changes reach the feeds.
    @ObservationIgnored var socialStore: CheckinSocialStore?
    @ObservationIgnored private let checkinsAPI = CheckinsAPI()

    init(checkin: Checkin) {
        self.checkin = checkin
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func load() async {
        do {
            // The API's maximum page. A thread longer than this shows its
            // latest 100, which is plenty for a checkin between friends.
            comments = try await checkinsAPI.comments(checkinId: checkin.id, limit: 100).reversed()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        isSending = true
        actionError = nil
        defer { isSending = false }
        do {
            let comment = try await checkinsAPI.addComment(checkinId: checkin.id, body: body)
            comments.append(comment)
            draft = ""
            socialStore?.didAddComment(to: checkin)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func delete(_ comment: CheckinComment) async {
        actionError = nil
        do {
            try await checkinsAPI.deleteComment(checkinId: checkin.id, commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
            socialStore?.didDeleteComment(from: checkin)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// The rows of a thread, plus its loading, error and empty states. A bare
/// sequence of views, so it works inside a List and a VStack alike.
struct CommentsList: View {
    let model: CommentsModel

    @Environment(AuthManager.self) private var authManager

    var body: some View {
        if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, HackysackSpacing.large)
                .listRowSeparator(.hidden)
        } else if let loadError = model.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Comments", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") {
                    Task { await model.load() }
                }
            }
            .listRowSeparator(.hidden)
        } else if model.comments.isEmpty {
            Text("No comments yet. Say something nice.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HackysackSpacing.large)
                .listRowSeparator(.hidden)
        } else {
            ForEach(model.comments) { comment in
                CommentRow(comment: comment, canDelete: canDelete(comment)) {
                    Task { await model.delete(comment) }
                }
            }
        }

        if let actionError = model.actionError {
            FormErrorBanner(message: actionError)
                .listRowSeparator(.hidden)
        }
    }

    /// Yours, or on your checkin, the same rule the server applies.
    private func canDelete(_ comment: CheckinComment) -> Bool {
        guard let currentUserId = authManager.currentProfile?.id else { return false }
        return comment.user.id == currentUserId || model.checkin.userId == currentUserId
    }
}

/// Instagram's shape: the name in bold running straight into the comment.
struct CommentRow: View {
    let comment: CheckinComment
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.user.avatarURL, initials: comment.user.initials, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(comment.user.displayName).fontWeight(.semibold)) \(comment.body)")
                    .font(.subheadline)
                Text(comment.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        // The context menu covers the inline thread, where there is no List
        // to swipe in; the swipe covers the sheet.
        .contextMenu {
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }
}

/// The bar for writing a comment: your avatar, a growing field and a send
/// button that lights up once there is something to send.
struct CommentComposer: View {
    @Bindable var model: CommentsModel
    var isFocused: FocusState<Bool>.Binding

    @Environment(AuthManager.self) private var authManager

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            AvatarView(
                url: authManager.currentProfile?.avatarURL,
                initials: authManager.currentProfile?.initials ?? "?",
                size: 32
            )
            .padding(.bottom, 2)

            TextField("Add a comment…", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused(isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                Task { await model.send() }
            } label: {
                if model.isSending {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
            .padding(.bottom, 2)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The half sheet behind a row's speech bubble.
struct CommentsSheet: View {
    @Environment(CheckinSocialStore.self) private var socialStore
    @State private var model: CommentsModel
    @FocusState private var isComposerFocused: Bool

    init(checkin: Checkin) {
        _model = State(initialValue: CommentsModel(checkin: checkin))
    }

    var body: some View {
        NavigationStack {
            List {
                CommentsList(model: model)
            }
            .listStyle(.plain)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                CommentComposer(model: model, isFocused: $isComposerFocused)
            }
            .task {
                model.socialStore = socialStore
                await model.load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("Sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CommentsSheet(checkin: .preview(commentCount: 2))
                .environment(AuthManager())
                .environment(CheckinSocialStore())
        }
}

#Preview("Row") {
    List {
        CommentRow(comment: .preview(), canDelete: true, onDelete: {})
        CommentRow(comment: .preview(body: "Wish I'd been there. Next time!", minutesAgo: 240), canDelete: false, onDelete: {})
    }
    .listStyle(.plain)
}
