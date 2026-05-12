import Foundation

struct ScreenTextStructuredPromptExporter {
    func markdown(from document: ScreenTextStructuredLLMDocument) -> String {
        var output: [String] = []

        output.append("# Screen Text Structure")
        output.append("")
        output.append("- capturedAt: \(document.source.capturedAt.ISO8601Format())")
        output.append("- displayCount: \(document.source.displayCount)")
        output.append("- observationCount: \(document.source.observationCount)")
        output.append("- lineCount: \(document.source.lineCount)")
        output.append("- blockCount: \(document.source.blockCount)")
        output.append("- regionCount: \(document.source.regionCount)")
        output.append("- classifier: \(document.classifierID)@\(document.classifierVersion)")
        output.append("- structureNote: Roles are deterministic layout hints derived from OCR text and geometry.")
        output.append("")

        for display in document.source.displays {
            output.append("## \(display.alias)")
            output.append("")
            output.append("- displayID: \(display.displayID)")
            output.append("- index: \(display.index)")
            output.append("- frameSize: \(Int(display.frameSize.width))x\(Int(display.frameSize.height))")
            output.append("")

            if display.blocks.isEmpty {
                output.append("_No OCR blocks detected._")
                output.append("")
                continue
            }

            for block in display.blocks {
                let annotation = document.annotation(for: block.alias)
                let role = annotation?.role.rawValue ?? ScreenTextStructureRole.unknown.rawValue
                let confidence = annotation.map { String(format: "%.2f", $0.confidence) } ?? "0.00"
                let bounds = formatBounds(block.normalizedBounds)

                output.append("[\(block.alias) role=\(role) confidence=\(confidence) bounds=\(bounds)]")
                output.append(block.text)
                output.append("")
            }
        }

        return output.joined(separator: "\n")
    }

    private func formatBounds(_ bounds: ScreenTextLLMBounds) -> String {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height].map { value in
            String(format: "%.3f", value)
        }
        return "[\(values.joined(separator: ","))]"
    }
}
