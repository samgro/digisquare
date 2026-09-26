//
//  CheckinPhotoViews.swift
//  Hackysack
//

import SwiftUI

/// One checkin photo, filling whatever frame it is given. Shows a quiet
/// placeholder while loading, and an icon if the image is gone, which can
/// happen for old Swarm photos that were never copied.
struct CheckinPhotoImage: View {
    let photo: CheckinPhoto
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: photo.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failure:
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            case .empty:
                Color(.secondarySystemBackground)
            @unknown default:
                Color(.secondarySystemBackground)
            }
        }
    }
}

/// Small square thumbnails under a checkin in a list.
struct CheckinPhotoStrip: View {
    let photos: [CheckinPhoto]

    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        HStack(spacing: 6) {
            ForEach(photos) { photo in
                CheckinPhotoImage(photo: photo)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photos.count == 1 ? "1 photo" : "\(photos.count) photos")
    }
}

/// Full-width photos on a checkin's detail screen, swiped between when there
/// is more than one.
struct CheckinPhotoGallery: View {
    let photos: [CheckinPhoto]

    var body: some View {
        TabView {
            ForEach(photos) { photo in
                CheckinPhotoImage(photo: photo, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
        .aspectRatio(galleryAspectRatio, contentMode: .fit)
    }

    /// The first photo's shape, clamped so a tall portrait doesn't push
    /// everything else off screen.
    private var galleryAspectRatio: CGFloat {
        guard let first = photos.first, let width = first.width, let height = first.height, height > 0 else {
            return 1
        }
        return min(max(CGFloat(width) / CGFloat(height), 0.75), 1.5)
    }
}
