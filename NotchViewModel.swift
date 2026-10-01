import Foundation
import MediaPlayer
import Combine

final class NotchViewModel: ObservableObject {
    @Published var trackTitle: String = "No track"
    @Published var artist: String = "Music"
    @Published var isPlaying: Bool = false
    @Published var droppedFiles: [URL] = []

    private let player = MPMusicPlayerController.systemMusicPlayer

    func startMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNowPlayingChanged),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackChanged),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player
        )

        player.beginGeneratingPlaybackNotifications()
        updateNowPlaying()
        updatePlaybackState()
    }

    func previousTrack() {
        player.skipToPreviousItem()
    }

    func nextTrack() {
        player.skipToNextItem()
    }

    func togglePlayPause() {
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func addDroppedFiles(_ urls: [URL]) {
        for url in urls {
            if !droppedFiles.contains(url) {
                droppedFiles.append(url)
            }
        }
    }

    @objc private func handleNowPlayingChanged() {
        updateNowPlaying()
    }

    @objc private func handlePlaybackChanged() {
        updatePlaybackState()
    }

    private func updateNowPlaying() {
        if let item = player.nowPlayingItem {
            trackTitle = item.title ?? "Unknown title"
            artist = item.artist ?? "Unknown artist"
        } else {
            trackTitle = "No track"
            artist = "Music"
        }
    }

    private func updatePlaybackState() {
        isPlaying = (player.playbackState == .playing)
    }
}