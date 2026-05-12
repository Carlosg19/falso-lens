import CoreGraphics
import Foundation

struct ScreenTextLLMExporter {
    func export(_ source: MultiDisplayScreenTextDocument) -> ScreenTextLLMDocument {
        let displays = source.displays.enumerated().map { offset, display in
            exportDisplay(display, fallbackIndex: offset)
        }

        return ScreenTextLLMDocument(
            sourceDocumentID: source.id,
            capturedAt: source.capturedAt,
            displayCount: source.displays.count,
            observationCount: source.observationCount,
            lineCount: source.lineCount,
            blockCount: source.blockCount,
            regionCount: source.regionCount,
            displays: displays
        )
    }

    func anchoredMarkdown(from document: ScreenTextLLMDocument) -> String {
        var output: [String] = []
        output.append("# Screen Text")
        output.append("")
        output.append("- capturedAt: \(document.capturedAt.ISO8601Format())")
        output.append("- displayCount: \(document.displayCount)")
        output.append("- observationCount: \(document.observationCount)")
        output.append("- lineCount: \(document.lineCount)")
        output.append("- blockCount: \(document.blockCount)")
        output.append("- regionCount: \(document.regionCount)")
        output.append("")

        for display in document.displays {
            output.append("## \(display.alias)")
            output.append("")
            output.append("- displayID: \(display.displayID)")
            output.append("- index: \(display.index)")
            output.append("- frameSize: \(Int(display.frameSize.width))x\(Int(display.frameSize.height))")
            output.append("- frameHash: \(display.frameHash)")
            output.append("- normalizedTextHash: \(display.normalizedTextHash)")
            output.append("- layoutHash: \(display.layoutHash)")
            output.append("")

            if display.regions.isEmpty {
                output.append("_No OCR text detected._")
                output.append("")
                continue
            }

            for region in display.regions {
                output.append("### \(region.alias)")
                output.append("")
                output.append("- order: \(region.readingOrder)")
                output.append("- bounds: \(formatBounds(region.bounds))")
                output.append("- normalizedBounds: \(formatBounds(region.normalizedBounds))")
                output.append("- blockAliases: \(region.blockAliases.joined(separator: ", "))")
                output.append("")

                let blocks = display.blocks.filter { region.blockAliases.contains($0.alias) }
                for block in blocks {
                    output.append("#### \(block.alias)")
                    output.append("")
                    output.append("- order: \(block.readingOrder)")
                    output.append("- bounds: \(formatBounds(block.bounds))")
                    output.append("- lineAliases: \(block.lineAliases.joined(separator: ", "))")
                    output.append("")
                    output.append(block.text)
                    output.append("")
                }
            }
        }

        return output.joined(separator: "\n")
    }

    func compactJSON(from document: ScreenTextLLMDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    func chunks(from document: ScreenTextLLMDocument, maxCharacters: Int = 6_000) -> [ScreenTextLLMChunk] {
        precondition(maxCharacters > 0, "maxCharacters must be greater than zero")

        var chunks: [ScreenTextLLMChunk] = []
        var chunkIndex = 1

        for display in document.displays {
            var currentLines: [String] = []
            var currentRegionAliases: [String] = []
            var currentCount = 0

            func flushCurrentChunk() {
                guard !currentLines.isEmpty else { return }

                let text = currentLines.joined(separator: "\n")
                chunks.append(
                    ScreenTextLLMChunk(
                        alias: "\(display.alias).c\(chunkIndex)",
                        displayAlias: display.alias,
                        regionAliases: currentRegionAliases,
                        text: text,
                        characterCount: text.count
                    )
                )
                chunkIndex += 1
                currentLines.removeAll()
                currentRegionAliases.removeAll()
                currentCount = 0
            }

            for region in display.regions {
                let blocks = display.blocks.filter { region.blockAliases.contains($0.alias) }
                let regionText = blocks
                    .map { "[\($0.alias)] \($0.text)" }
                    .joined(separator: "\n")

                guard !regionText.isEmpty else {
                    continue
                }

                let additionalCount = regionText.count + (currentLines.isEmpty ? 0 : 1)
                if currentCount > 0 && currentCount + additionalCount > maxCharacters {
                    flushCurrentChunk()
                }

                if regionText.count > maxCharacters {
                    let splitLines = splitOversizedText(regionText, maxCharacters: maxCharacters)
                    for line in splitLines {
                        if currentCount > 0 {
                            flushCurrentChunk()
                        }
                        currentLines.append(line)
                        currentRegionAliases.append(region.alias)
                        currentCount = line.count
                        flushCurrentChunk()
                    }
                } else {
                    currentLines.append(regionText)
                    if !currentRegionAliases.contains(region.alias) {
                        currentRegionAliases.append(region.alias)
                    }
                    currentCount += additionalCount
                }
            }

            flushCurrentChunk()
        }

        return chunks
    }

    private func exportDisplay(_ source: DisplayScreenTextDocument, fallbackIndex: Int) -> ScreenTextLLMDisplay {
        let displayAlias = "d\(source.index + 1)"
        let frameSize = source.document.frameSize

        let observationAliases = Dictionary(
            uniqueKeysWithValues: source.document.observations.enumerated().map { offset, observation in
                (observation.id, "\(displayAlias).o\(offset + 1)")
            }
        )

        let lineAliases = Dictionary(
            uniqueKeysWithValues: source.document.lines.enumerated().map { offset, line in
                (line.id, "\(displayAlias).l\(offset + 1)")
            }
        )

        let blockAliases = Dictionary(
            uniqueKeysWithValues: source.document.blocks.enumerated().map { offset, block in
                (block.id, "\(displayAlias).b\(offset + 1)")
            }
        )

        let observations = source.document.observations.enumerated().map { offset, observation in
            ScreenTextLLMObservation(
                alias: observationAliases[observation.id] ?? "\(displayAlias).o\(offset + 1)",
                sourceID: observation.id,
                readingOrder: offset + 1,
                text: observation.text,
                bounds: bounds(from: observation.boundingBox),
                normalizedBounds: normalizedBounds(from: observation.boundingBox, frameSize: frameSize),
                confidence: observation.confidence,
                metrics: metrics(text: observation.text, bounds: observation.boundingBox, frameSize: frameSize)
            )
        }

        let lines = source.document.lines.enumerated().map { offset, line in
            ScreenTextLLMLine(
                alias: lineAliases[line.id] ?? "\(displayAlias).l\(offset + 1)",
                sourceID: line.id,
                readingOrder: offset + 1,
                text: line.text,
                bounds: bounds(from: line.boundingBox),
                normalizedBounds: normalizedBounds(from: line.boundingBox, frameSize: frameSize),
                observationAliases: line.observationIDs.compactMap { observationAliases[$0] },
                metrics: metrics(text: line.text, bounds: line.boundingBox, frameSize: frameSize)
            )
        }

        let blocks = source.document.blocks.enumerated().map { offset, block in
            ScreenTextLLMBlock(
                alias: blockAliases[block.id] ?? "\(displayAlias).b\(offset + 1)",
                sourceID: block.id,
                readingOrder: offset + 1,
                text: block.text,
                bounds: bounds(from: block.boundingBox),
                normalizedBounds: normalizedBounds(from: block.boundingBox, frameSize: frameSize),
                lineAliases: block.lineIDs.compactMap { lineAliases[$0] },
                metrics: metrics(text: block.text, bounds: block.boundingBox, frameSize: frameSize)
            )
        }

        let regions = source.document.regions.enumerated().map { offset, region in
            ScreenTextLLMRegion(
                alias: "\(displayAlias).r\(offset + 1)",
                sourceID: region.id,
                readingOrder: offset + 1,
                bounds: bounds(from: region.boundingBox),
                normalizedBounds: normalizedBounds(from: region.boundingBox, frameSize: frameSize),
                blockAliases: region.blockIDs.compactMap { blockAliases[$0] },
                metrics: metrics(text: "", bounds: region.boundingBox, frameSize: frameSize)
            )
        }

        return ScreenTextLLMDisplay(
            alias: displayAlias,
            displayID: source.displayID,
            index: fallbackIndex,
            capturedAt: source.document.capturedAt,
            frameSize: ScreenTextLLMSize(width: Double(frameSize.width), height: Double(frameSize.height)),
            frameHash: source.document.frameHash,
            normalizedTextHash: source.document.normalizedTextHash,
            layoutHash: source.document.layoutHash,
            text: source.document.recognizedText,
            regions: regions,
            blocks: blocks,
            lines: lines,
            observations: observations
        )
    }

    private func bounds(from rect: CGRect) -> ScreenTextLLMBounds {
        ScreenTextLLMBounds(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    private func normalizedBounds(from rect: CGRect, frameSize: CGSize) -> ScreenTextLLMBounds {
        guard frameSize.width > 0, frameSize.height > 0 else {
            return ScreenTextLLMBounds(x: 0, y: 0, width: 0, height: 0)
        }

        return ScreenTextLLMBounds(
            x: Double(rect.origin.x / frameSize.width),
            y: Double(rect.origin.y / frameSize.height),
            width: Double(rect.width / frameSize.width),
            height: Double(rect.height / frameSize.height)
        )
    }

    private func metrics(text: String, bounds: CGRect, frameSize: CGSize) -> ScreenTextLLMMetrics {
        let frameArea = frameSize.width * frameSize.height
        let areaRatio = frameArea > 0 ? Double((bounds.width * bounds.height) / frameArea) : 0

        return ScreenTextLLMMetrics(
            characterCount: text.count,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            areaRatio: areaRatio
        )
    }

    private func formatBounds(_ bounds: ScreenTextLLMBounds) -> String {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height].map { value in
            String(format: "%.4f", value)
        }

        return "[x: \(values[0]), y: \(values[1]), w: \(values[2]), h: \(values[3])]"
    }

    private func splitOversizedText(_ text: String, maxCharacters: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = String(line)
            let separatorCount = current.isEmpty ? 0 : 1

            if !current.isEmpty && current.count + separatorCount + next.count > maxCharacters {
                result.append(current)
                current = ""
            }

            if next.count > maxCharacters {
                let characters = Array(next)
                var start = 0
                while start < characters.count {
                    let end = min(start + maxCharacters, characters.count)
                    result.append(String(characters[start..<end]))
                    start = end
                }
            } else {
                current = current.isEmpty ? next : "\(current)\n\(next)"
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}
