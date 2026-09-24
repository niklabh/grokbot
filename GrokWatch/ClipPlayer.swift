import AVFoundation
import Combine

@MainActor
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()
    private var playing: String?
    private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    func play(_ name: String) {
        guard name != playing else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4")
            ?? Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Media")
        else { return }
        playing = name
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
            }
        }
        player.play()
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}
