import SwiftUI

/// Wraps its children onto as many rows as they need.
///
/// The tagging pad holds one button per person and the count is not known
/// ahead of time, so a fixed grid would either clip names or waste the row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal.width)
        let rows = arrange(subviews: subviews, in: width)
        return CGSize(width: contentWidth(of: rows, within: proposal.width), height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Arranged against the same width `sizeThatFits` used. When the two
        // disagree, the height reported and the height actually filled differ,
        // and SwiftUI re-proposes forever trying to settle it.
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: resolvedWidth(bounds.width)) {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// A width to wrap against.
    ///
    /// SwiftUI legitimately proposes `nil`, `0` and `.infinity` while it works
    /// out what fits, and none of those are a real line length. Anything that
    /// is not a positive finite number means "unconstrained", which wraps
    /// nowhere and puts every child on one row.
    private func resolvedWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else { return .infinity }
        return proposed
    }

    /// What this layout actually needs, never what it was offered.
    ///
    /// The previous version returned `proposal.width` straight back -- so when
    /// SwiftUI proposed `.infinity` to find the ideal size, it got `.infinity`
    /// as an answer. An infinite ideal size propagates into every ancestor's
    /// arithmetic and the layout engine cannot converge.
    private func contentWidth(of rows: [Row], within proposed: CGFloat?) -> CGFloat {
        let needed = rows.map(\.width).max() ?? 0
        guard let proposed, proposed.isFinite else { return needed }
        return min(needed, proposed)
    }

    private func height(of rows: [Row]) -> CGFloat {
        rows.reduce(into: CGFloat(0)) { total, row in
            total += row.height + (total > 0 ? spacing : 0)
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = Row()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
