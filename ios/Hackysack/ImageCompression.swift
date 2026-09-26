//
//  ImageCompression.swift
//  Hackysack
//

import UIKit

/// Shrinks images before they are uploaded, so uploads stay well under the
/// server's 2 MB cap and quick on a phone connection.
nonisolated enum ImageCompression {
    static let maxUploadBytes = 2_000_000

    /// JPEG data within the upload cap. Quality 0.8 is normally plenty small;
    /// the lower qualities exist for pathological images.
    static func jpegData(from image: UIImage) -> Data? {
        for quality in [0.8, 0.6, 0.4] {
            guard let data = image.jpegData(compressionQuality: quality) else { continue }
            if data.count <= maxUploadBytes {
                return data
            }
        }
        return nil
    }

    /// Scales the image down to fit a `maxDimension` square, never up. Drawn
    /// at scale 1 so the result is exactly that many pixels, not points.
    static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

/// A checkin photo picked, resized and compressed, waiting to be uploaded.
/// It is also written to a temporary file, so the checkin can show it while
/// it is still saving.
nonisolated struct PreparedPhoto: Identifiable, Equatable, Sendable {
    /// Checkin photos match what the server makes of imported Swarm photos.
    static let maxDimension: CGFloat = 1200

    let id: UUID
    let jpegData: Data
    let width: Int
    let height: Int
    let localURL: URL

    /// Nil when the image can't be encoded within the upload cap.
    init?(image: UIImage) {
        let resized = ImageCompression.resized(image, maxDimension: Self.maxDimension)
        guard let jpegData = ImageCompression.jpegData(from: resized) else { return nil }

        let id = UUID()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkin-photo-\(id.uuidString).jpg")
        guard (try? jpegData.write(to: localURL)) != nil else { return nil }

        self.id = id
        self.jpegData = jpegData
        self.width = Int(resized.size.width * resized.scale)
        self.height = Int(resized.size.height * resized.scale)
        self.localURL = localURL
    }
}
