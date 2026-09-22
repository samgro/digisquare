//
//  AvatarCropView.swift
//  Hackysack
//

import SwiftUI

/// Square cropper modelled on the system photo picker's "Move and Scale"
/// screen, because that is the interaction people already know.
struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onChoose: (UIImage) -> Void

    /// Output edge length. Avatars render at 96pt, so 288px covers @3x with
    /// headroom for anywhere they get shown larger later.
    private static let outputSize: CGFloat = 512

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var isShowingHint = true

    var body: some View {
        GeometryReader { geometry in
            let circleDiameter = min(geometry.size.width, geometry.size.height)
                - 2 * HackysackSpacing.extraLarge

            ZStack {
                Color.black.ignoresSafeArea()

                imageLayer(circleDiameter: circleDiameter)

                // Dim everything outside the circle, so the crop boundary is
                // obvious without a hard-edged frame.
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .mask {
                        Rectangle()
                            .overlay(
                                Circle()
                                    .frame(width: circleDiameter, height: circleDiameter)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: circleDiameter, height: circleDiameter)
                    .allowsHitTesting(false)

                VStack {
                    topBar(circleDiameter: circleDiameter)
                    Spacer()
                    if isShowingHint {
                        Text("Pinch to zoom, drag to reposition")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, HackysackSpacing.extraLarge)
                            .transition(.opacity)
                    }
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { isShowingHint = false }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func imageLayer(circleDiameter: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: circleDiameter, height: circleDiameter)
            .scaleEffect(scale)
            .offset(offset)
            .clipped()
            .gesture(
                SimultaneousGesture(
                    // MagnifyGesture, not the deprecated MagnificationGesture.
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(committedScale * value.magnification, 1), 4)
                        }
                        .onEnded { _ in committedScale = scale },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            offset = clampedOffset(offset, circleDiameter: circleDiameter)
                            committedOffset = offset
                        }
                )
            )
    }

    /// Keeps the image covering the circle, so a drag can never expose an
    /// empty wedge inside the crop.
    private func clampedOffset(_ proposed: CGSize, circleDiameter: CGFloat) -> CGSize {
        let maximumOffset = max(0, (circleDiameter * scale - circleDiameter) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumOffset), maximumOffset),
            height: min(max(proposed.height, -maximumOffset), maximumOffset)
        )
    }

    private func topBar(circleDiameter: CGFloat) -> some View {
        HStack {
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white)
            Spacer()
            // Apple's own wording for this exact screen.
            Text("Move and Scale")
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Button("Choose") {
                onChoose(renderCroppedImage(circleDiameter: circleDiameter))
            }
            .fontWeight(.semibold)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, HackysackSpacing.large)
        .padding(.top, HackysackSpacing.medium)
    }

    private func renderCroppedImage(circleDiameter: CGFloat) -> UIImage {
        let outputSize = CGSize(width: Self.outputSize, height: Self.outputSize)
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: {
            let format = UIGraphicsImageRendererFormat.default()
            // scale 1 means the output really is 512x512 rather than 512pt at
            // the device's scale factor.
            format.scale = 1
            return format
        }())

        // The on-screen circle maps 1:1 onto the output square, so the same
        // transform reproduces exactly what the user framed.
        let ratio = Self.outputSize / circleDiameter

        return renderer.image { context in
            context.cgContext.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            context.cgContext.translateBy(x: offset.width * ratio, y: offset.height * ratio)
            context.cgContext.scaleBy(x: scale, y: scale)

            let aspectRatio = image.size.width / max(image.size.height, 1)
            // scaledToFill: the short edge matches the circle, the long edge
            // overflows and is cropped.
            var drawWidth = Self.outputSize
            var drawHeight = Self.outputSize
            if aspectRatio > 1 {
                drawWidth = Self.outputSize * aspectRatio
            } else {
                drawHeight = Self.outputSize / max(aspectRatio, 0.0001)
            }

            image.draw(in: CGRect(
                x: -drawWidth / 2,
                y: -drawHeight / 2,
                width: drawWidth,
                height: drawHeight
            ))
        }
    }
}
