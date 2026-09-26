//
//  CheckinDetailView.swift
//  Hackysack
//

import SwiftUI

/// What a row hands to the detail page: the checkin and who made it. Rows
/// already know both, so the page can draw at once and refresh behind it.
struct CheckinDetailDestination: Hashable, Identifiable {
    let checkin: Checkin
    let author: UserSummary

    var id: String { checkin.id }
}

/// One checkin in full, with its comments underneath and the composer at
/// the bottom, the same thread the half sheet shows. Your own checkins get
/// an Edit button.
struct CheckinDetailView: View {
    let destination: CheckinDetailDestination

    @Environment(CheckinSocialStore.self) private var socialStore
    @Environment(AuthManager.self) private var authManager

    @State private var model: CommentsModel
    @State private var isEditing = false
    @FocusState private var isComposerFocused: Bool

    init(destination: CheckinDetailDestination) {
        self.destination = destination
        _model = State(initialValue: CommentsModel(checkin: destination.checkin))
    }

    /// The row's copy, or a newer one if something has changed it since.
    private var checkin: Checkin { socialStore.current(destination.checkin) }

    private var isMine: Bool { checkin.userId == authManager.currentProfile?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HackysackSpacing.medium) {
                authorRow

                HStack(alignment: .top, spacing: 12) {
                    PlaceIconView(primaryType: checkin.placePrimaryType)
                    CheckinDetailsRow(checkin: checkin, showsPhotos: false)
                }

                if !checkin.photos.isEmpty {
                    CheckinPhotoGallery(photos: checkin.photos)
                        .clipShape(RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous))
                }

                CheckinActionBar(checkin: checkin) {
                    isComposerFocused = true
                }

                Divider()

                Text("Comments")
                    .font(.headline)

                LazyVStack(alignment: .leading, spacing: 0) {
                    CommentsList(model: model)
                }
            }
            .padding(.horizontal, HackysackSpacing.medium)
            .padding(.top, HackysackSpacing.medium)
            .padding(.bottom, HackysackSpacing.large)
        }
        .navigationTitle("Checkin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMine {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            EditCheckinView(checkin: checkin)
        }
        .safeAreaInset(edge: .bottom) {
            CommentComposer(model: model, isFocused: $isComposerFocused)
        }
        .task {
            model.socialStore = socialStore
            await model.load()
            // The row's counts may be stale; the fresh copy lands in the
            // store, which `checkin` reads from.
            await refreshCheckin()
        }
    }

    private var authorRow: some View {
        HStack(spacing: 12) {
            AvatarView(url: destination.author.avatarURL, initials: destination.author.initials)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.author.displayName)
                    .font(.headline)
                Text(checkin.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshCheckin() async {
        do {
            _ = try await socialStore.refresh(destination.checkin)
        } catch {
            // The row's copy is still on screen and still nearly right.
            DevLog.network("Couldn't refresh checkin: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        CheckinDetailView(destination: CheckinDetailDestination(
            checkin: .preview(likeCount: 3, commentCount: 2),
            author: PublicUser.preview().summary
        ))
    }
    .environment(AuthManager())
    .environment(CheckinSocialStore())
}
