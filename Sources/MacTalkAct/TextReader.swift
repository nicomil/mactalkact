import CoreGraphics
import Foundation
import Vision

/// Reads the text of an image on the Mac with Vision (FR-47, AD-19): the image never has to go to
/// a cloud engine to be read. Accurate mode with a fallback to the fast one, at most 10 s.
final class TextReader: @unchecked Sendable {
    static let shared = TextReader()
    /// Tests build their own (a cold reader); the app uses `shared`.
    init() {}

    struct Line: Equatable {
        let text: String
        /// Position in the image, origin top left, in pixels.
        let box: CGRect
        let confidence: Float

        func scaled(by f: CGFloat) -> Line {
            Line(text: text, box: CGRect(x: box.minX * f, y: box.minY * f, width: box.width * f, height: box.height * f), confidence: confidence)
        }
    }

    private let lock = NSLock()
    private var warm = false
    private var warming = false
    /// One recognition at a time: a reading that timed out keeps running, and new ones wait behind
    /// it (bounded by their own limit) instead of piling up.
    private let queue = DispatchQueue(label: "mactalkact.textreader", qos: .userInitiated)

    var isWarm: Bool { lock.withLock { warm } }

    /// Loads the models in the background at launch, without slowing down listening.
    func warmUp() {
        let start = lock.withLock { () -> Bool in
            guard !warm, !warming else { return false }
            warming = true
            return true
        }
        guard start else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            if let image = Self.blank() {
                _ = try? Self.recognize(image, accurate: true)
                _ = try? Self.recognize(image, accurate: false)
            }
            self.lock.withLock { self.warm = true; self.warming = false }
            Log.debug(String(format: "Lettura del testo pronta in %.1f s", Date().timeIntervalSince(started)))
        }
    }

    /// The lines of `image`. Before the warm-up ends only the fast mode is used; if even that fails
    /// in time, `nil` («testo non leggibile ora»).
    func read(_ image: CGImage, limit: TimeInterval = 10) async -> [Line]? {
        let accurate = isWarm
        let started = Date()
        // Vision blocks its thread and does not stop on cancellation: race it against the limit
        // without waiting for it, so a slow reading never holds the agent longer than `limit`.
        let small = Self.downscaled(image, maxSide: Self.maxSide)
        let result: [Line]? = await withCheckedContinuation { continuation in
            let done = Box(false)
            let lock = NSLock()
            func finish(_ value: [Line]?) {
                let first = lock.withLock { () -> Bool in defer { done.value = true }; return !done.value }
                if first { continuation.resume(returning: value) }
            }
            queue.async {
                // Accurate when warm; an empty result is an answer («no text»), not a reason to retry.
                if accurate, let lines = try? Self.recognize(small.image, accurate: true) {
                    finish(lines.map { $0.scaled(by: small.scale) })
                } else {
                    // A Vision error is «no text» too: retrying would not help.
                    finish(((try? Self.recognize(small.image, accurate: false)) ?? []).map { $0.scaled(by: small.scale) })
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { finish(nil) }
        }
        let seconds = Date().timeIntervalSince(started)
        Log.debug(String(format: "Lettura del testo (%@): %d righe in %.2f s", accurate ? "accurata" : "veloce", result?.count ?? 0, seconds))
        return result
    }

    /// At most `maxSide` pixels on the long side; `scale` maps boxes back to the original.
    private static func downscaled(_ image: CGImage, maxSide: CGFloat) -> (image: CGImage, scale: CGFloat) {
        let side = CGFloat(max(image.width, image.height))
        guard side > maxSide else { return (image, 1) }
        let f = maxSide / side
        let w = Int(CGFloat(image.width) * f), h = Int(CGFloat(image.height) * f)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (image, 1) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return (image, 1) }
        return (out, 1 / f)
    }

    /// Vision reads small print well up to about this size; above it the image is reduced.
    static let maxSide: CGFloat = 4096

    /// Lines in reading order: grouped into rows by vertical overlap, then left to right.
    static func ordered(_ lines: [Line]) -> [Line] {
        var rows: [[Line]] = []
        for l in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let i = rows.indices.last, let ref = rows[i].first,
               l.box.midY - ref.box.midY < max(ref.box.height, l.box.height) * 0.6 {
                rows[i].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private static func recognize(_ image: CGImage, accurate: Bool) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.usesLanguageCorrection = accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            // Vision boxes are normalized, origin bottom left.
            let b = obs.boundingBox
            return Line(text: top.string, box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h),
                        confidence: top.confidence)
        }
    }

    private static func blank() -> CGImage? {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.setFillColor(gray: 1, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return ctx?.makeImage()
    }
}
