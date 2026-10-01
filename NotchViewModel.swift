import Foundation
import Combine

final class NotchViewModel: ObservableObject {
    @Published var trackTitle: String = "No track"
    @Published var artist: String = "Music"
    @Published var isPlaying: Bool = false
    @Published var droppedFiles: [URL] = []

    private var updateTimer: Timer?

    func startMonitoring() {
        updateNowPlaying()
        updatePlaybackState()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateNowPlaying()
            self?.updatePlaybackState()
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
        for url in urls {
            if !droppedFiles.contains(url) {
                droppedFiles.append(url)
            }
        }
    }

    private func updateNowPlaying() {
        let script = """
            tell application "Music"
                if player state is playing or player state is paused then
                    set trackName to name of current track
                    set artistName to artist of current track
                    return trackName & "|" & artistName
                else
                    return "No track|Music"
                end if
            end tell
            """

        if let result = executeAppleScriptWithResult(script) {
            let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                DispatchQueue.main.async {
                    self.trackTitle = parts[0]
                    self.artist = parts[1]
                }
            }
        }
    }

    private func updatePlaybackState() {
        let script = """
            tell application "Music"
                if player state is playing then
                    return "playing"
                else
                    return "stopped"
                end if
            end tell
            """

        if let result = executeAppleScriptWithResult(script) {
            DispatchQueue.main.async {
                self.isPlaying = result.trimmingCharacters(in: .whitespaces) == "playing"
            }
        }
    }

    private func executeAppleScript(_ script: String) {
        DispatchQueue.global().async {
            if let scriptObject = NSAppleScript(source: script) {
                var errorInfo: NSDictionary?
                scriptObject.executeAndReturnError(&errorInfo)
                if errorInfo != nil {
                    print("AppleScript error: \(String(describing: errorInfo))")
                }
            }
        }
    }

    private func executeAppleScriptWithResult(_ script: String) -> String? {
        var result: String?

        if let scriptObject = NSAppleScript(source: script) {
            var errorInfo: NSDictionary?
            let output = scriptObject.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                result = output.stringValue
            }
        }

        return result
    }

    deinit {
        updateTimer?.invalidate()
    }
}
