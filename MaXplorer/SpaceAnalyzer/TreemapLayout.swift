import CoreGraphics

/// Computes treemap frames for a scanned space tree. Kept separate from the
/// view so layout cost can be measured and tuned independently.
nonisolated enum TreemapLayout {
    /// Recursively computes `layoutFrame` for every node in the tree.
    /// `minimumArea` prunes descendants that would be too small to draw.
    static func layout(node: SpaceNode, in rect: CGRect, minimumArea: CGFloat = 0) {
        node.layoutFrame = rect
        guard node.isDirectory, !node.children.isEmpty, node.size > 0,
              rect.width > 2, rect.height > 2 else { return }
        squarify(
            nodes: node.children,
            weights: node.children.map { Double($0.size) },
            total: Double(node.size),
            in: rect.insetBy(dx: 1, dy: 1),
            recurses: true,
            minimumArea: minimumArea
        )
    }

    /// Lays out one folder level as a WinDirStat-style mosaic. Square-root
    /// weighting keeps relative size ordering while leaving small items usable.
    static func layoutDrillDown(nodes: [SpaceNode], in rect: CGRect) {
        squarify(
            nodes: nodes,
            weights: nodes.map { sqrt(Double(max(1, $0.size))) },
            total: nodes.reduce(0.0) { $0 + sqrt(Double(max(1, $1.size))) },
            in: rect.insetBy(dx: 4, dy: 4),
            recurses: false,
            minimumArea: 0
        )
    }

    private static func squarify(
        nodes: [SpaceNode],
        weights: [Double],
        total: Double,
        in available: CGRect,
        recurses: Bool,
        minimumArea: CGFloat
    ) {
        guard !nodes.isEmpty, nodes.count == weights.count,
              total > 0, available.width > 0, available.height > 0 else { return }

        var current = available
        var remainingTotal = total
        var start = 0

        while start < nodes.count && remainingTotal > 0 && current.width > 0 && current.height > 0 {
            var rowTotal = 0.0
            var prevWorst = Double.infinity
            var end = start

            while end < nodes.count {
                let candidateTotal = rowTotal + weights[end]
                let worst = worstRatio(
                    weights: weights,
                    range: start..<(end + 1),
                    rowTotal: candidateTotal,
                    total: remainingTotal,
                    in: current
                )
                if end > start && worst > prevWorst {
                    break
                }
                rowTotal = candidateTotal
                prevWorst = worst
                end += 1
            }

            placeRow(
                nodes: nodes,
                weights: weights,
                range: start..<end,
                rowTotal: rowTotal,
                remaining: remainingTotal,
                in: current
            )

            if recurses {
                for index in start..<end {
                    let node = nodes[index]
                    guard node.isDirectory, !node.children.isEmpty else { continue }
                    let childRect = node.layoutFrame.insetBy(dx: 1, dy: 1)
                    guard minimumArea <= 0
                        || (childRect.width > 0 && childRect.height > 0
                            && childRect.width * childRect.height >= minimumArea) else {
                        continue
                    }
                    squarify(
                        nodes: node.children,
                        weights: node.children.map { Double($0.size) },
                        total: Double(node.size),
                        in: childRect,
                        recurses: true,
                        minimumArea: minimumArea
                    )
                }
            }

            let frac = CGFloat(rowTotal / remainingTotal)
            if current.width >= current.height {
                let width = current.width * frac
                current = CGRect(
                    x: current.minX + width,
                    y: current.minY,
                    width: current.width - width,
                    height: current.height
                )
            } else {
                let height = current.height * frac
                current = CGRect(
                    x: current.minX,
                    y: current.minY + height,
                    width: current.width,
                    height: current.height - height
                )
            }

            remainingTotal -= rowTotal
            start = end
        }
    }

    private static func worstRatio(
        weights: [Double],
        range: Range<Int>,
        rowTotal: Double,
        total: Double,
        in rect: CGRect
    ) -> Double {
        guard rowTotal > 0, total > 0 else { return 0 }
        let isWide = rect.width >= rect.height
        let frac = rowTotal / total
        let stripLong = (isWide ? Double(rect.width) : Double(rect.height)) * frac
        let stripShort = isWide ? Double(rect.height) : Double(rect.width)
        var worst = 0.0

        for index in range {
            let tileFrac = weights[index] / rowTotal
            let a = stripLong
            let b = stripShort * tileFrac
            guard a > 0, b > 0 else { continue }
            worst = max(worst, max(a / b, b / a))
        }

        return worst
    }

    private static func placeRow(
        nodes: [SpaceNode],
        weights: [Double],
        range: Range<Int>,
        rowTotal: Double,
        remaining: Double,
        in rect: CGRect
    ) {
        guard rowTotal > 0, remaining > 0 else {
            for index in range {
                nodes[index].layoutFrame = .zero
            }
            return
        }

        let isWide = rect.width >= rect.height
        let frac = CGFloat(rowTotal / remaining)

        if isWide {
            let stripWidth = rect.width * frac
            var y = rect.minY
            for index in range {
                let height = rect.height * CGFloat(weights[index] / rowTotal)
                nodes[index].layoutFrame = CGRect(x: rect.minX, y: y, width: stripWidth, height: height)
                y += height
            }
        } else {
            let stripHeight = rect.height * frac
            var x = rect.minX
            for index in range {
                let width = rect.width * CGFloat(weights[index] / rowTotal)
                nodes[index].layoutFrame = CGRect(x: x, y: rect.minY, width: width, height: stripHeight)
                x += width
            }
        }
    }
}
