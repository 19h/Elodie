// Test support, which has no place in a release build.
#if DEBUG
import CoreVideo
import Foundation
import Vision

/// Compares a decoded picture with its source.
public enum ImageQuality {
    /// Peak signal-to-noise ratio of the luma planes, in decibels.
    public static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        let aBase = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let bBase = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let aStride = CVPixelBufferGetBytesPerRowOfPlane(a, 0)
        let bStride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)

        var squaredError = 0.0
        for y in 0..<height {
            let aRow = aBase + y * aStride
            let bRow = bBase + y * bStride
            for x in 0..<width {
                let delta = Double(aRow[x]) - Double(bRow[x])
                squaredError += delta * delta
            }
        }
        let mean = squaredError / Double(width * height)
        return mean == 0 ? 99 : 10 * log10(255 * 255 / mean)
    }
}

/// Reads text the way the app will, for measuring recall against ground truth.
public enum TextRecognizer {
    public static func words(in buffer: CVPixelBuffer) async throws -> Set<String> {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: buffer, orientation: nil)
        var words = Set<String>()
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            for word in text.split(whereSeparator: { $0.isWhitespace }) {
                words.insert(String(word))
            }
        }
        return words
    }
}
#endif
