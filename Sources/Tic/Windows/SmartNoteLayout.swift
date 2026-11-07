import CoreGraphics
import Foundation

/// Chooses a nearby, non-overlapping row, column, grid or masonry layout.
enum SmartNoteLayout {
    nonisolated static func arrange(_ frames: [CGRect], in screen: CGRect, avoiding obstacles: [CGRect]) -> [CGRect]? {
        let normalized = normalizedSizes(frames)
        if normalized != frames, let result = arrangeFrames(normalized, in: screen, avoiding: obstacles) { return result }
        return arrangeFrames(frames, in: screen, avoiding: obstacles)
    }

    /// Only similar notes share a size; a compact bar and a full note remain independent.
    private nonisolated static func normalizedSizes(_ frames: [CGRect]) -> [CGRect] {
        var result = frames
        var groups: [[Int]] = []
        for index in frames.indices.sorted(by: { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }) {
            guard frames[index].width > 0, frames[index].height > 0 else { continue }
            if let group = groups.firstIndex(where: { members in
                let sizes = (members + [index]).map { frames[$0].size }
                let widths = sizes.map(\.width), heights = sizes.map(\.height)
                return widths.max()! <= widths.min()! * 1.2 && heights.max()! <= heights.min()! * 1.2
            }) { groups[group].append(index) } else { groups.append([index]) }
        }
        for group in groups where group.count > 1 {
            let width = (group.reduce(CGFloat.zero) { $0 + frames[$1].width } / CGFloat(group.count)).rounded()
            let height = (group.reduce(CGFloat.zero) { $0 + frames[$1].height } / CGFloat(group.count)).rounded()
            for index in group { result[index].size = CGSize(width: width, height: height) }
        }
        return result
    }

    private nonisolated static func arrangeFrames(_ frames: [CGRect], in screen: CGRect, avoiding obstacles: [CGRect]) -> [CGRect]? {
        guard frames.count > 1, !screen.isEmpty,
              frames.allSatisfy({ !$0.isEmpty && $0.width <= screen.width && $0.height <= screen.height }) else { return nil }
        let originalBounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let blocking = obstacles.filter { !$0.isEmpty && $0.intersects(screen) }
        var best: [CGRect]?
        var bestScore = CGFloat.greatestFiniteMagnitude

        // Position order follows the existing reading order. Results remain indexed by input.
        let order = frames.indices.sorted {
            if frames[$0].midY != frames[$1].midY { return frames[$0].midY > frames[$1].midY }
            return frames[$0].minX < frames[$1].minX
        }
        for gap: CGFloat in [12, 4] {
            for columns in 1...min(frames.count, 10) {
                for masonry in [false, true] {
                    var assignments = Array(repeating: [Int](), count: columns)
                    var columnHeights = Array(repeating: CGFloat.zero, count: columns)
                    var columnWidths = Array(repeating: CGFloat.zero, count: columns)
                    for (index, item) in order.enumerated() {
                        let column = masonry ? (columnHeights.indices.min { columnHeights[$0] < columnHeights[$1] } ?? 0) : index % columns
                        assignments[column].append(item)
                        columnHeights[column] += frames[item].height + (assignments[column].count > 1 ? gap : 0)
                        columnWidths[column] = max(columnWidths[column], frames[item].width)
                    }
                    guard assignments.allSatisfy({ !$0.isEmpty }) else { continue }
                    var relative = Array(repeating: CGRect.zero, count: frames.count)
                    let width = columnWidths.reduce(0, +) + gap * CGFloat(columns - 1)
                    let height: CGFloat
                    if masonry {
                        height = columnHeights.max() ?? 0
                        var x: CGFloat = 0
                        for column in 0..<columns {
                            var top = height
                            for item in assignments[column] {
                                let frame = frames[item]
                                relative[item] = CGRect(x: x, y: top - frame.height, width: frame.width, height: frame.height)
                                top -= frame.height + gap
                            }
                            x += columnWidths[column] + gap
                        }
                    } else {
                        let rows = (frames.count + columns - 1) / columns
                        var rowHeights = Array(repeating: CGFloat.zero, count: rows)
                        for (index, item) in order.enumerated() { rowHeights[index / columns] = max(rowHeights[index / columns], frames[item].height) }
                        height = rowHeights.reduce(0, +) + gap * CGFloat(rows - 1)
                        var offsets = Array(repeating: CGFloat.zero, count: columns)
                        for column in 1..<columns { offsets[column] = offsets[column - 1] + columnWidths[column - 1] + gap }
                        var rowTop = height
                        for row in 0..<rows {
                            for column in 0..<columns {
                                let index = row * columns + column
                                guard index < order.count else { continue }
                                let item = order[index], frame = frames[item]
                                relative[item] = CGRect(x: offsets[column], y: rowTop - frame.height, width: frame.width, height: frame.height)
                            }
                            rowTop -= rowHeights[row] + gap
                        }
                    }
                    guard width <= screen.width, height <= screen.height else { continue }
                    let xs = [originalBounds.minX, originalBounds.midX - width / 2, originalBounds.maxX - width,
                              screen.minX, screen.maxX - width, screen.midX - width / 2]
                    let ys = [originalBounds.minY, originalBounds.midY - height / 2, originalBounds.maxY - height,
                              screen.minY, screen.maxY - height, screen.midY - height / 2]
                    for rawX in xs {
                        let x = min(max(rawX, screen.minX), screen.maxX - width)
                        for rawY in ys {
                            let y = min(max(rawY, screen.minY), screen.maxY - height)
                            let placed = relative.map { $0.offsetBy(dx: x, dy: y) }
                            guard !placed.contains(where: { item in blocking.contains(where: { $0.intersects(item) }) }) else { continue }
                            let movement = zip(frames, placed).reduce(CGFloat.zero) { sum, pair in
                                sum + hypot(pair.0.midX - pair.1.midX, pair.0.midY - pair.1.midY)
                            } / CGFloat(frames.count)
                            // Penalize unused space inside the group as well as movement. In particular,
                            // a short collapsed note should not reserve an entire row's height.
                            let usedArea = frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
                            let emptyHeight = max(0, width * height - usedArea) / width
                            var score = movement + emptyHeight * 1.5 + (gap == 4 ? 20 : 0)
                            // Snap only when the selected group was already close to an edge or centre.
                            if abs(originalBounds.minX - screen.minX) < 48 && abs(x - screen.minX) < 1 { score -= 24 }
                            else if abs(originalBounds.maxX - screen.maxX) < 48 && abs(x + width - screen.maxX) < 1 { score -= 24 }
                            else if abs(originalBounds.midX - screen.midX) < 40 && abs(x + width / 2 - screen.midX) < 1 { score -= 14 }
                            if abs(originalBounds.minY - screen.minY) < 48 && abs(y - screen.minY) < 1 { score -= 24 }
                            else if abs(originalBounds.maxY - screen.maxY) < 48 && abs(y + height - screen.maxY) < 1 { score -= 24 }
                            else if abs(originalBounds.midY - screen.midY) < 40 && abs(y + height / 2 - screen.midY) < 1 { score -= 14 }
                            if score < bestScore { bestScore = score; best = placed }
                        }
                    }
                }
            }
        }
        return best
    }
}
