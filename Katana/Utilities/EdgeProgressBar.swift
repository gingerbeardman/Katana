import SwiftUI

/// Shared top-edge progress used for scan, menu rebuild, import, delete, and other mutations.
///
/// - **Fill** advances from `fraction`.
/// - **Markers** are narrow notches: half-punched stripes in the fill (visible on any fill
///   colour without cutting a hard gap), and solid primary ticks over the empty track.
struct EdgeProgressBar: View {
    /// 0…1 fill amount.
    var fraction: Double
    /// Bar fill color (accent, orange, …).
    var color: Color
    /// Cumulative chunk ends in 0…1 (last may be 1). Internal boundaries become ticks.
    var segmentEnds: [Double] = []

    @Environment(\.colorScheme) private var colorScheme

    /// Equal-weight chunk ends for `count` units: `1/n … 1`.
    static func equalEnds(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if count == 1 { return [1] }
        return (1...count).map { Double($0) / Double(count) }
    }

    /// Byte-weighted ends from per-chunk sizes (multi-delete by payload size).
    static func byteWeightedEnds(sizes: [Int64]) -> [Double] {
        guard !sizes.isEmpty else { return [] }
        let total = max(1, sizes.reduce(Int64(0)) { $0 + max($1, 1) })
        var ends: [Double] = []
        ends.reserveCapacity(sizes.count)
        var cumulative: Int64 = 0
        for size in sizes {
            cumulative += max(size, 1)
            ends.append(min(1, Double(cumulative) / Double(total)))
        }
        if let last = ends.indices.last {
            ends[last] = 1
        }
        return ends
    }

    /// Rebuild stage boundaries (headers → bake → install), weighted by observed wall time.
    static let rebuildStageEnds: [Double] = [0.80, 0.96, 1.0]

    /// Track wash under the fill.
    private var trackColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.11)
    }

    var body: some View {
        let clamped = max(0, min(1, fraction))
        let boundaries = Self.visibleBoundaries(segmentEnds)
        let barHeight: CGFloat = boundaries.isEmpty ? 2 : 4
        // Explicit deps so Canvas redraws when segments arrive mid-import.
        let endsKey = boundaries.map { String(format: "%.4f", $0) }.joined(separator: ",")

        Canvas { context, size in
            let track = Path(CGRect(origin: .zero, size: size))
            context.fill(track, with: .color(trackColor))

            let fillWidth = size.width * clamped
            if fillWidth > 0.5 {
                let fill = Path(CGRect(x: 0, y: 0, width: fillWidth, height: size.height))
                context.fill(fill, with: .color(color))
            }

            // 1.5 pt notches. Over the fill: a half punch-out (50% of the fill's alpha
            // removed) — the notch reads as a softer stripe of the fill colour on any
            // colour, in either appearance, without cutting a hard gap. Over the faint
            // track wash a punch would be invisible, so draw a solid primary tick.
            let tickWidth: CGFloat = 1.5
            for end in boundaries {
                let x = size.width * end
                let tick = Path(
                    CGRect(x: x - tickWidth / 2, y: 0, width: tickWidth, height: size.height)
                )
                if end <= clamped + 0.000_5 {
                    context.blendMode = .destinationOut
                    context.fill(tick, with: .color(Color.black.opacity(0.25)))
                    context.blendMode = .normal
                } else {
                    context.fill(tick, with: .color(Color.primary.opacity(0.25)))
                }
            }
        }
        // Force invalidation when fraction or segment layout changes.
        .id("edge-\(String(format: "%.4f", clamped))-\(endsKey)")
        .frame(height: barHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Boundaries between chunks only, subsampled when a scan has hundreds of folders.
    private static func visibleBoundaries(_ ends: [Double], maxTicks: Int = 40) -> [Double] {
        // Keep near-edge marks (equal chunks put the first at 1/n — can be ~0.02 for 50 files).
        let mids = ends.filter { $0 > 0.004 && $0 < 0.996 }
        guard mids.count > maxTicks else { return mids }
        var picked: [Double] = []
        picked.reserveCapacity(maxTicks)
        for i in 0..<maxTicks {
            let t = Double(i + 1) / Double(maxTicks + 1)
            if let nearest = mids.min(by: { abs($0 - t) < abs($1 - t) }),
               picked.last != nearest
            {
                picked.append(nearest)
            }
        }
        return picked
    }
}

/// Indeterminate 2 pt sweep when a mutation has no reliable fraction.
struct IndeterminateEdgeProgressBar: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            GeometryReader { geo in
                let width = geo.size.width
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.2) / 1.2
                let barWidth = max(48, width * 0.28)
                let x = (width + barWidth) * phase - barWidth
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                    Rectangle()
                        .fill(color.opacity(0.9))
                        .frame(width: barWidth)
                        .offset(x: x)
                }
                .clipped()
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
