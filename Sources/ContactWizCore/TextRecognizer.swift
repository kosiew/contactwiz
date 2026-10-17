import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One line of text found by OCR, with its normalized bounding box (origin bottom-left).
public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum TextRecognizer {
    public enum Failure: LocalizedError {
        case unreadableImage

        public var errorDescription: String? { "The image could not be read." }
    }

    /// Runs on-device OCR. Blocking; call off the main thread.
    public static func recognize(cgImage: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                text: candidate.string,
                x: box.minX, y: box.minY, width: box.width, height: box.height
            )
        }
        // Top-to-bottom, then left-to-right for lines sharing a row.
        return lines.sorted { a, b in
            let rowTolerance = min(a.height, b.height) / 2
            if abs(a.y - b.y) > rowTolerance { return a.y > b.y }
            return a.x < b.x
        }
    }

    public static func recognize(imageAt url: URL) throws -> [RecognizedLine] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadableImage }
        return try recognize(cgImage: image)
    }
}
