import CoreGraphics

/// Packs window thumbnails into justified rows, the way Mission Control does.
enum Layout {
    /// Returns one image rect per input frame (same order). Thumbnails keep their aspect ratio,
    /// never grow beyond their real size, and roughly keep their on-screen top-to-bottom order.
    static func arrange(_ frames: [CGRect], in bounds: CGRect, spacing: CGFloat, labelSpace: CGFloat) -> [CGRect] {
        guard !frames.isEmpty else { return [] }
        let aspects = frames.map { max(0.2, $0.width / max($0.height, 1)) }
        // Top of screen first (Cocoa y grows upward).
        let order = frames.indices.sorted { frames[$0].midY > frames[$1].midY }

        var best: (score: CGFloat, rects: [CGRect]) = (-1, [])
        for rowCount in 1...frames.count {
            let rows = partition(order, aspects: aspects, rowCount: rowCount)
            let rowHeightLimit = (bounds.height - CGFloat(rows.count - 1) * spacing) / CGFloat(rows.count) - labelSpace
            var height = rowHeightLimit
            for row in rows {
                let aspectSum = row.reduce(0) { $0 + aspects[$1] }
                height = min(height, (bounds.width - CGFloat(row.count - 1) * spacing) / aspectSum)
            }
            guard height > 20 else { continue }

            var rects = [CGRect](repeating: .zero, count: frames.count)
            var score: CGFloat = 0
            var rowHeights: [CGFloat] = []
            for row in rows {
                // Cap each thumbnail at its real size so small windows don't balloon.
                let sizes = row.map { i -> CGSize in
                    let h = min(height, frames[i].height)
                    return CGSize(width: h * aspects[i], height: h)
                }
                rowHeights.append(sizes.map(\.height).max() ?? 0)
                score += sizes.reduce(0) { $0 + $1.width * $1.height }
            }
            let totalHeight = rowHeights.reduce(0, +) + CGFloat(rows.count) * labelSpace + CGFloat(rows.count - 1) * spacing
            var y = bounds.midY + totalHeight / 2
            for (r, row) in rows.enumerated() {
                let rowHeight = rowHeights[r]
                y -= rowHeight
                let sorted = row.sorted { frames[$0].midX < frames[$1].midX }
                let sizes = sorted.map { i -> CGSize in
                    let h = min(height, frames[i].height)
                    return CGSize(width: h * aspects[i], height: h)
                }
                let rowWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(sorted.count - 1) * spacing
                var x = bounds.midX - rowWidth / 2
                for (i, size) in zip(sorted, sizes) {
                    rects[i] = CGRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                    x += size.width + spacing
                }
                y -= labelSpace + spacing
            }
            if score > best.score { best = (score, rects) }
        }
        return best.rects
    }

    /// Splits items (already in order) into `rowCount` rows with roughly equal total aspect width.
    private static func partition(_ order: [Int], aspects: [CGFloat], rowCount: Int) -> [[Int]] {
        let target = order.reduce(0) { $0 + aspects[$1] } / CGFloat(rowCount)
        var rows: [[Int]] = [[]]
        var width: CGFloat = 0
        for (n, i) in order.enumerated() {
            let remainingItems = order.count - n
            let remainingRows = rowCount - rows.count
            let wouldOvershoot = width + aspects[i] / 2 > target
            if !rows[rows.count - 1].isEmpty, remainingRows > 0, wouldOvershoot || remainingItems <= remainingRows {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(i)
            width += aspects[i]
        }
        return rows
    }
}
