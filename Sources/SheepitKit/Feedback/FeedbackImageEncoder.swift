import CoreGraphics
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Turns an app-supplied image into a JPEG the feedback endpoint accepts (≤1 MiB, ≤16384 px a
/// side), for `SheepitFeedbackScreenshot.init?(image:)`. CoreGraphics + ImageIO only, so the same
/// code runs, and is tested, on every platform.
///
/// The image is redrawn onto white at most `maxLongSide` pixels on its longest side: that drops
/// alpha (JPEG has none; transparent pixels would otherwise turn black) and bounds memory, since
/// the redraw buffer is 4 bytes a pixel. Then JPEG quality steps down, then the size, until the
/// bytes fit or the image is below `minLongSide`.
enum FeedbackImageEncoder {
    static let maxBytes = FeedbackLimits.screenshotMaxBytes
    /// Far under the server's 16384: a phone screenshot is ~2900 px, and 4096² × 4 bytes = 64 MB
    /// is the most this redraw allocates.
    static let maxLongSide = 4096
    static let minLongSide = 320
    static let qualities: [CGFloat] = [0.8, 0.6, 0.4]

    static func jpeg(
        from image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        maxBytes: Int = maxBytes
    ) -> Data? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        var side = min(longest, maxLongSide)
        while true {
            guard let flattened = redraw(image, longSide: side) else { return nil }
            for quality in qualities {
                if let data = encode(flattened, quality: quality, orientation: orientation),
                   data.count <= maxBytes {
                    return data
                }
            }
            guard side > minLongSide else { return nil }
            side = max(minLongSide, side * 3 / 4)
        }
    }

    private static func redraw(_ image: CGImage, longSide: Int) -> CGImage? {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, quality: CGFloat, orientation: CGImagePropertyOrientation) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Not baked into the pixels: the redraw keeps the source's raw orientation, and this
            // EXIF tag is what tells a viewer to rotate it.
            kCGImagePropertyOrientation: orientation.rawValue,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Pixel width and height read from the encoded header, without decoding the image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// The first image in `data`, for an image object that has no `CGImage` of its own.
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

extension SheepitFeedbackScreenshot {
    /// The image re-encoded as a JPEG of at most 1 MiB: quality steps down, then the size (never
    /// above 4096 px on its longest side), and transparency is flattened onto white. Nil when it
    /// cannot be encoded small enough. Synchronous and CPU-heavy for a large image: call it off
    /// the main thread when you can.
    init?(cgImage: CGImage, orientation: CGImagePropertyOrientation) {
        guard let data = FeedbackImageEncoder.jpeg(from: cgImage, orientation: orientation) else { return nil }
        self.init(data: data)
    }
}

#if canImport(UIKit)
extension SheepitFeedbackScreenshot {
    /// `image` re-encoded as a JPEG of at most 1 MiB (see `SheepitFeedbackScreenshot`). The SDK
    /// does not capture the screen: pass an image your app made, for example with
    /// `UIGraphicsImageRenderer`. Nil when it cannot be encoded small enough. Synchronous and
    /// CPU-heavy for a large image: call it off the main thread when you can.
    public init?(image: UIImage) {
        guard let cgImage = image.cgImage
            ?? image.pngData().flatMap(FeedbackImageEncoder.cgImage(from:)) else { return nil }
        self.init(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#elseif os(macOS)
extension SheepitFeedbackScreenshot {
    /// `image` re-encoded as a JPEG of at most 1 MiB (see `SheepitFeedbackScreenshot`). Nil when
    /// it has no bitmap representation or cannot be encoded small enough.
    public init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(cgImage: cgImage, orientation: .up)
    }
}
#endif
