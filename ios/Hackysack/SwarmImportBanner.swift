//
//  SwarmImportBanner.swift
//  Hackysack
//

import SwiftUI

/// The row at the top of the timeline while Swarm history is coming in, the
/// way Instagram shows a post finishing up above the feed: what is happening,
/// how far along it is on a thin bar, and the count underneath. Tapping it
/// opens the import screen. It stays for a moment once the import finishes,
/// so the user sees it land, and stays put if the import stopped.
struct SwarmImportBanner: View {
    let swarmImport: SwarmImport
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text("🐝")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(swarmImport.progressTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        trailingMark
                    }

                    ThinProgressBar(fraction: swarmImport.progressFraction, tint: tint)

                    Text(swarmImport.progressDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, HackysackSpacing.medium)
        .padding(.vertical, HackysackSpacing.small)
        .animation(.easeInOut(duration: 0.6), value: swarmImport.progressFraction)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the import")
    }

    private var tint: Color {
        switch swarmImport.status {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        }
    }

    @ViewBuilder
    private var trailingMark: some View {
        switch swarmImport.status {
        case .running:
            Image(systemName: Glyphs.disclosure)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// A 4 pt determinate bar, or a segment sliding back and forth while the
/// total is unknown. Apple's guidance for bars in a busy view: keep them
/// thin, keep them moving, and hide nothing behind a spinner that could be
/// measured.
struct ThinProgressBar: View {
    /// 0...1, or nil while the total is not known.
    let fraction: Double?
    var tint: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSlidAcross = false

    private static let height: CGFloat = 4
    private static let indeterminateSegment: CGFloat = 0.3

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(width * min(max(fraction, 0), 1), Self.height))
                } else {
                    Capsule()
                        .fill(tint)
                        .frame(width: width * Self.indeterminateSegment)
                        .offset(x: isSlidAcross ? width * (1 - Self.indeterminateSegment) : 0)
                }
            }
        }
        .frame(height: Self.height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isSlidAcross = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unknown")
    }
}

extension SwarmImport {
    /// The one line that says what is happening.
    var progressTitle: String {
        switch status {
        case .running:
            switch phase {
            case .checkins: "Importing your Swarm checkins"
            case .photos: "Copying your Swarm photos"
            }
        case .completed:
            "Swarm import finished"
        case .failed:
            "Swarm import stopped"
        }
    }

    /// The counts under the bar, or what went wrong.
    var progressDetail: String {
        switch status {
        case .running:
            switch phase {
            case .checkins:
                if let checkinsExpected, checkinsExpected > 0 {
                    return "\(checkinsImported.formatted()) of \(checkinsExpected.formatted()) checkins"
                }
                return checkinsImported == 0
                    ? "Getting started…"
                    : "\(checkinsImported.formatted()) checkins so far"
            case .photos:
                return "\(photosCopied.formatted()) of \(photosTotal.formatted()) photos · your checkins are already in your timeline"
            }
        case .completed:
            return checkinsImported == 1
                ? "1 checkin added"
                : "\(checkinsImported.formatted()) checkins added"
        case .failed:
            return error ?? "Try syncing again."
        }
    }
}

#Preview("States") {
    let now = Date()
    VStack(spacing: 0) {
        SwarmImportBanner(swarmImport: SwarmImport(
            id: "1", status: .running, phase: .checkins, checkinsImported: 0, checkinsExpected: nil,
            photosTotal: 0, photosCopied: 0, error: nil, startedAt: now, finishedAt: nil
        ))
        SwarmImportBanner(swarmImport: SwarmImport(
            id: "2", status: .running, phase: .checkins, checkinsImported: 1240, checkinsExpected: 3812,
            photosTotal: 0, photosCopied: 0, error: nil, startedAt: now, finishedAt: nil
        ))
        SwarmImportBanner(swarmImport: SwarmImport(
            id: "3", status: .running, phase: .photos, checkinsImported: 3812, checkinsExpected: 3812,
            photosTotal: 980, photosCopied: 312, error: nil, startedAt: now, finishedAt: nil
        ))
        SwarmImportBanner(swarmImport: SwarmImport(
            id: "4", status: .completed, phase: .photos, checkinsImported: 3812, checkinsExpected: 3812,
            photosTotal: 980, photosCopied: 980, error: nil, startedAt: now, finishedAt: now
        ))
        SwarmImportBanner(swarmImport: SwarmImport(
            id: "5", status: .failed, phase: .checkins, checkinsImported: 500, checkinsExpected: 3812,
            photosTotal: 0, photosCopied: 0, error: "Foursquare had a problem. Try syncing again later.",
            startedAt: now, finishedAt: now
        ))
    }
}
