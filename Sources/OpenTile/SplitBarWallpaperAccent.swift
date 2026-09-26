import AppKit
import ImageIO

/// A restrained edge color chosen from the current desktop image.
struct SplitBarWallpaperAccent: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    static func read(from url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? fromRGBA(pixels) : nil
    }

    static func fromRGBA(_ pixels: [UInt8]) -> Self? {
        guard pixels.count >= 4, pixels.count.isMultiple(of: 4) else { return nil }
        var scores = [Double](repeating: 0, count: 12)
        var redSums = scores, greenSums = scores, blueSums = scores
        var brightnessSum = 0.0
        var count = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let red = min(1, Double(pixels[index]) / 255 / alpha)
            let green = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let brightest = max(red, green, blue)
            let darkest = min(red, green, blue)
            let difference = brightest - darkest
            brightnessSum += brightest
            count += 1
            guard brightest > 0.12, difference > 0.12 else { continue }
            let saturation = difference / brightest
            guard saturation > 0.24 else { continue }
            let hue: Double
            if brightest == red {
                hue = ((green - blue) / difference).truncatingRemainder(dividingBy: 6)
            } else if brightest == green {
                hue = (blue - red) / difference + 2
            } else {
                hue = (red - green) / difference + 4
            }
            let bucket = Int((hue < 0 ? hue + 6 : hue) * 2) % 12
            let weight = saturation * (0.5 + brightest * 0.5)
            scores[bucket] += weight
            redSums[bucket] += red * weight
            greenSums[bucket] += green * weight
            blueSums[bucket] += blue * weight
        }
        guard count > 0 else { return nil }
        if let bucket = scores.indices.max(by: { scores[$0] < scores[$1] }),
           scores[bucket] > Double(count) * 0.015 {
            let source = NSColor(calibratedRed: redSums[bucket] / scores[bucket],
                                 green: greenSums[bucket] / scores[bucket],
                                 blue: blueSums[bucket] / scores[bucket], alpha: 1)
            let accent = NSColor(calibratedHue: source.hueComponent,
                                 saturation: min(0.65, max(0.42, source.saturationComponent)),
                                 brightness: 0.82, alpha: 1)
            return Self(red: Double(accent.redComponent), green: Double(accent.greenComponent),
                        blue: Double(accent.blueComponent))
        }
        let neutral = 0.43 + 0.28 * brightnessSum / Double(count)
        return Self(red: neutral, green: neutral, blue: neutral)
    }
}
