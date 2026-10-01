import Foundation
import Combine
import AppKit

final class NotchViewModel: ObservableObject {
    @Published var trackTitle: String = "No track"
    @Published var artist: String = "Music"
    @Published var album: String = "Not playing"
    @Published var isPlaying: Bool = false
    @Published var coverArt: NSImage?
    @Published var droppedFiles: [URL] = []

    private var updateTimer: Timer?

    func startMonitoring() {
        refreshNowPlaying()
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }
    }

    func previousTrack() {
        executeAppleScript("""
            tell application "Music"
                previous track
            end tell
            """)
    }

    func nextTrack() {
        executeAppleScript("""
            tell application "Music"
                next track
            end tell
            """)
    }

    func togglePlayPause() {
        executeAppleScript("""
            tell application "Music"
                playpause
            end tell
            """)
    }

    func addDroppedFiles(_ urls: [URL]) {
        for url in urls where !droppedFiles.contains(url) {
            droppedFiles.append(url)
        }
    }

    private func refreshNowPlaying() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let script = """
                tell application "Music"
                    if player state is playing or player state is paused then
                        set trackName to name of current track
                        set artistName to artist of current track
                        set albumName to album of current track
                        set artData to data of artwork 1 of current track

                        if artData is missing value then
                            return trackName & "|" & artistName & "|" & albumName & "|NO_ART"
                        end if

                        set tempFolder to POSIX path of (path to temporary items)
                        set tempName to "notchmusic-cover-" & (do shell script "uuidgen") & ".tiff"
                        set tempPath to tempFolder & tempName
                        set outFile to open for access tempPath with write permission
                        write artData to outFile
                        close access outFile

                        return trackName & "|" & artistName & "|" & albumName & "|" & tempPath
                    else
                        return "No track|Music|Not playing|NO_ART"
                    end if
                end tell
                """

            guard let result = self.executeAppleScriptWithResult(script) else {
                self.applyFallbackState()
                return
            }

            let parts = result.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else {
                self.applyFallbackState()
                return
            }

            let title = parts[0]
            let artist = parts[1]
            let album = parts[2]
            let artPath = parts[3]

            let image: NSImage?
            if artPath == "NO_ART" {
                image = nil
            } else {
                image = NSImage(contentsOfFile: artPath)
            }

            DispatchQueue.main.async {
                self.trackTitle = title
                self.artist = artist
                self.album = album
                self.isPlaying = title != "No track"
                self.coverArt = image
            }
        }
    }

    private func applyFallbackState() {
        DispatchQueue.main.async {
            self.trackTitle = "No track"
            self.artist = "Music"
            self.album = "Not playing"
            self.isPlaying = false
            self.coverArt = nil
        }
    }

    private func executeAppleScript(_ script: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = self.executeAppleScriptWithResult(script)
        }
    }

    private func executeAppleScriptWithResult(_ script: String) -> String? {
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let output = scriptObject.executeAndReturnError(&error)
        if let error {
            print("AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }

    deinit {
        updateTimer?.invalidate()
    }
}
