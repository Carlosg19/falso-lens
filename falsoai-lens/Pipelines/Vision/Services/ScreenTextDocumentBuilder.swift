import CoreGraphics
import Foundation

struct ScreenTextDocumentBuilder {
    func build(
        observations: [ScreenTextObservation],
        frameSize: CGSize,
        frameHash: String,
        capturedAt: Date
    ) -> ScreenTextDocument {
        let cleanedObservations = removeNearDuplicates(from: observations)
        let lines = groupLines(from: cleanedObservations)
        let blocks = groupBlocks(from: lines)
        let regions = groupRegions(from: blocks)
        let recognizedText = blocks.isEmpty
            ? lines.map(\.text).joined(separator: "\n")
            : blocks.map(\.text).joined(separator: "\n\n")

        return ScreenTextDocument(
            capturedAt: capturedAt,
            frameSize: frameSize,
            frameHash: frameHash,
            normalizedTextHash: ScreenTextHasher.hashNormalizedText(recognizedText),
            layoutHash: ScreenTextHasher.hashLayout(observations: cleanedObservations),
            observations: cleanedObservations,
            lines: lines,
            blocks: blocks,
            regions: regions
        )
    }

    private func removeNearDuplicates(from observations: [ScreenTextObservation]) -> [ScreenTextObservation] {
        observations
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.confidence > $1.confidence }
            .reduce(into: [ScreenTextObservation]()) { uniqueObservations, observation in
                let normalizedText = ScreenTextHasher.normalizeText(observation.text)
                let hasMatch = uniqueObservations.contains { existing in
                    ScreenTextHasher.normalizeText(existing.text) == normalizedText
                        && existing.boundingBox.intersectionRatio(with: observation.boundingBox) >= 0.72
                }

                if !hasMatch {
                    uniqueObservations.append(observation)
                }
            }
            .sortedByReadingOrder()
    }

    private func groupLines(from observations: [ScreenTextObservation]) -> [ScreenTextLine] {
        let sortedObservations = observations.sortedByReadingOrder()
        var lineBuckets: [[ScreenTextObservation]] = []

        for observation in sortedObservations {
            if let index = lineBuckets.firstIndex(where: { bucket in
                guard let first = bucket.first else { return false }
                let heightTolerance = max(first.boundingBox.height, observation.boundingBox.height) * 0.65
                let centerDelta = abs(first.boundingBox.midY - observation.boundingBox.midY)
                return centerDelta <= max(4, heightTolerance)
            }) {
                lineBuckets[index].append(observation)
            } else {
                lineBuckets.append([observation])
            }
        }

        return lineBuckets
            .map { bucket in
                let sortedBucket = bucket.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                let boundingBox = sortedBucket.map(\.boundingBox).unionBoundingBox()
                return ScreenTextLine(
                    text: sortedBucket.map(\.text).joined(separator: " "),
                    boundingBox: boundingBox,
                    observationIDs: sortedBucket.map(\.id)
                )
            }
            .sortedByReadingOrder()
    }

    private func groupBlocks(from lines: [ScreenTextLine]) -> [ScreenTextBlock] {
        let sortedLines = lines.sortedByReadingOrder()
        var blockBuckets: [[ScreenTextLine]] = []

        for line in sortedLines {
            guard var currentBlock = blockBuckets.popLast() else {
                blockBuckets.append([line])
                continue
            }

            if let previousLine = currentBlock.last,
               shouldGroup(line, after: previousLine) {
                currentBlock.append(line)
                blockBuckets.append(currentBlock)
            } else {
                blockBuckets.append(currentBlock)
                blockBuckets.append([line])
            }
        }

        return blockBuckets.map { bucket in
            let boundingBox = bucket.map(\.boundingBox).unionBoundingBox()
            return ScreenTextBlock(
                text: bucket.map(\.text).joined(separator: "\n"),
                boundingBox: boundingBox,
                lineIDs: bucket.map(\.id)
            )
        }
    }

    private func shouldGroup(_ line: ScreenTextLine, after previousLine: ScreenTextLine) -> Bool {
        let verticalGap = line.boundingBox.minY - previousLine.boundingBox.maxY
        let lineHeight = max(previousLine.boundingBox.height, line.boundingBox.height)
        let leftEdgeDelta = abs(line.boundingBox.minX - previousLine.boundingBox.minX)
        let horizontalOverlap = previousLine.boundingBox.horizontalOverlapRatio(with: line.boundingBox)

        return verticalGap <= max(10, lineHeight * 1.6)
            && (leftEdgeDelta <= max(16, lineHeight * 2) || horizontalOverlap >= 0.25)
    }

    private func groupRegions(from blocks: [ScreenTextBlock]) -> [ScreenTextRegion] {
        guard !blocks.isEmpty else { return [] }

        var regionBuckets: [[ScreenTextBlock]] = []
        for block in blocks {
            guard var currentRegion = regionBuckets.popLast() else {
                regionBuckets.append([block])
                continue
            }

            if let previousBlock = currentRegion.last,
               shouldGroup(block, after: previousBlock) {
                currentRegion.append(block)
                regionBuckets.append(currentRegion)
            } else {
                regionBuckets.append(currentRegion)
                regionBuckets.append([block])
            }
        }

        return regionBuckets.map { bucket in
            ScreenTextRegion(
                boundingBox: bucket.map(\.boundingBox).unionBoundingBox(),
                blockIDs: bucket.map(\.id)
            )
        }
    }

    private func shouldGroup(_ block: ScreenTextBlock, after previousBlock: ScreenTextBlock) -> Bool {
        let verticalGap = block.boundingBox.minY - previousBlock.boundingBox.maxY
        let averageHeight = (block.boundingBox.height + previousBlock.boundingBox.height) / 2
        let horizontalOverlap = previousBlock.boundingBox.horizontalOverlapRatio(with: block.boundingBox)

        return verticalGap <= max(24, averageHeight * 1.2)
            && horizontalOverlap >= 0.15
    }
}

private extension Array where Element == CGRect {
    func unionBoundingBox() -> CGRect {
        guard let first else { return .zero }
        return dropFirst().reduce(first) { $0.union($1) }
    }
}

private extension CGRect {
    func intersectionRatio(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull else { return 0 }

        let smallerArea = min(width * height, other.width * other.height)
        guard smallerArea > 0 else { return 0 }

        return (intersection.width * intersection.height) / smallerArea
    }

    func horizontalOverlapRatio(with other: CGRect) -> CGFloat {
        let overlap = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let smallerWidth = min(width, other.width)
        guard smallerWidth > 0 else { return 0 }

        return overlap / smallerWidth
    }
}

private extension Array where Element == ScreenTextObservation {
    func sortedByReadingOrder() -> [ScreenTextObservation] {
        sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > Swift.max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5 {
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }

            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}

private extension Array where Element == ScreenTextLine {
    func sortedByReadingOrder() -> [ScreenTextLine] {
        sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > Swift.max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5 {
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }

            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}
