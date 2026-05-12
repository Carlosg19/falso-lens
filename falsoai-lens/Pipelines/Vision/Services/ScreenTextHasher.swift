import CoreGraphics
import CryptoKit
import Foundation

enum ScreenTextHasher {
    static func hashFrame(_ image: CGImage) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(image.width)x\(image.height)|\(image.bitsPerPixel)|\(image.bytesPerRow)|\(image.bitmapInfo.rawValue)".utf8))

        if let pixelData = image.dataProvider?.data {
            hasher.update(data: pixelData as Data)
        }

        return hexDigest(from: hasher.finalize())
    }

    static func displayFrameHash(displayID: UInt32, image: CGImage) -> String {
        hashString("display:\(displayID)|frame:\(hashFrame(image))")
    }

    static func hashNormalizedText(_ text: String) -> String {
        hashString(normalizeText(text))
    }

    static func hashLayout(observations: [ScreenTextObservation]) -> String {
        let canonicalLayout = observations
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.5 {
                    return lhs.boundingBox.minY < rhs.boundingBox.minY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .map { observation in
                let box = observation.boundingBox
                return [
                    normalizeText(observation.text),
                    String(Int(box.minX.rounded())),
                    String(Int(box.minY.rounded())),
                    String(Int(box.width.rounded())),
                    String(Int(box.height.rounded()))
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        return hashString(canonicalLayout)
    }

    static func hashAggregateText(_ document: MultiDisplayScreenTextDocument) -> String {
        let canonicalText = document.displays
            .sorted { $0.index < $1.index }
            .map { display in
                [
                    "display:\(display.displayID)",
                    normalizeText(display.document.recognizedText)
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        return hashString(canonicalText)
    }

    static func hashAggregateLayout(_ document: MultiDisplayScreenTextDocument) -> String {
        let canonicalLayout = document.displays
            .sorted { $0.index < $1.index }
            .map { display in
                [
                    "display:\(display.displayID)",
                    display.document.layoutHash
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        return hashString(canonicalLayout)
    }

    static func normalizeText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func hashString(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return hexDigest(from: digest)
    }

    private static func hexDigest<Digest: Sequence>(from digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
