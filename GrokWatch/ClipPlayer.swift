import Combine
import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Loops a transparent GIF. watchOS will not decode animated WebP, and its video view cannot key a background.
@MainActor
final class ClipPlayer: ObservableObject {
    @Published private(set) var frame: UIImage?
    private var source: CGImageSource?
    private var frameCount = 0
    private var frameDuration = 1.0 / 12.0
    private var startedAt = Date()
    private var playing: String?
    private var cachedIndex = -1
    private var timer: Timer?

    func play(_ name: String) {
        guard name != playing else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Media")
            ?? Bundle.main.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }
        playing = name
        self.source = source
        frameCount = count
        frameDuration = Self.frameDelay(source) ?? (1.0 / 12.0)
        startedAt = Date()
        cachedIndex = -1
        tick()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: frameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let source, frameCount > 0 else { return }
        let index = Int(Date().timeIntervalSince(startedAt) / frameDuration) % frameCount
        guard index != cachedIndex else { return }
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return }
        cachedIndex = index
        frame = UIImage(cgImage: image)
    }

    private static func frameDelay(_ source: CGImageSource) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return nil }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)
        guard let delay else { return nil }
        let seconds = delay.doubleValue
        return seconds > 0 ? seconds : nil
    }
}
