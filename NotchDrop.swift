import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EventKit
import UserNotifications
import QuickLookThumbnailing
import ServiceManagement
import CoreAudio
import Darwin
import Carbon.HIToolbox
import CoreWLAN
import Network

// MARK: - System Liquid Glass

extension View {
    @ViewBuilder
    func notchLiquidGlass(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
        }
    }
}


// MARK: - Notch Metrics

enum NotchMetrics {

    // MARK: Hardware notch
    // Measured from the screen so the closed notch lines up with the real one.
    // Macs without a notch get a small stand-in pill. Refreshed on launch and display changes.

    static var notchSize = CGSize(width: 200, height: 26)
    static var hasHardwareNotch = false

    /// Extra width added to each side of the closed notch while something is going on
    /// (music playing, files waiting). Driven by NotchWindowManager.setLiveActivity.
    static var liveWing: CGFloat = 0
    static let liveWingWidth: CGFloat = 38

    static func configure(for screen: NSScreen?) {

        guard let screen else { return }

        let top = screen.safeAreaInsets.top

        if top > 0 {

            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0

            var width = screen.frame.width - left - right

            // Sanity check: fall back to the common notch width if the areas look wrong.
            if left <= 0 || right <= 0 || width <= 0 || width > 400 {
                width = 185
            }

            // A few extra points so the black overlaps the hardware edge with no seam.
            notchSize = CGSize(width: width + 4, height: top)
            hasHardwareNotch = true

        } else {

            notchSize = CGSize(width: 200, height: 26)
            hasHardwareNotch = false
        }
    }

    // MARK: Closed

    static let collapsedTopRadius: CGFloat = 5
    static let collapsedRadius: CGFloat = 10

    static var collapsedSize: CGSize {
        CGSize(
            width: notchSize.width + 2 * collapsedTopRadius + 2 * liveWing,
            height: notchSize.height
        )
    }

    // MARK: Open

    static let expandedTopRadius: CGFloat = 12
    static let expandedRadius: CGFloat = 20

    static var expandedContentWidth: CGFloat = 380
    static let expandedSidePadding: CGFloat = 14
    static let headerSpacing: CGFloat = 8
    static let bottomPadding: CGFloat = 14

    // Height of the tab content area (Music / Files / Calendar / Alarms all share it).
    static var tabContentHeight: CGFloat = 146

    /// Applies the size preset chosen in Settings.
    static func applySize(_ size: NotchSize) {
        expandedContentWidth = size.contentWidth
        tabContentHeight = size.contentHeight
    }

    /// The header row sits level with the notch so its buttons flank it.
    static var headerHeight: CGFloat { max(notchSize.height, 30) }

    static var expandedSize: CGSize {
        CGSize(
            width: expandedContentWidth + 2 * expandedSidePadding + 2 * expandedTopRadius,
            height: headerHeight + headerSpacing + tabContentHeight + bottomPadding
        )
    }

    // Extra window bounds clearance so the spring and shadow are never clipped by the NSWindow frame.
    static var expandedWindowSize: CGSize {
        CGSize(width: expandedSize.width + 24, height: expandedSize.height + 24)
    }

    static var dragHitboxSize: CGSize {
        CGSize(width: expandedWindowSize.width, height: 680)
    }

    // The drag hitbox is only rendered while this key is held during a file drag.
    // Without it the window never grows, so Finder keeps full control of the drag.
    // Options: .maskControl, .maskShift, .maskAlternate (Finder: copy), .maskCommand
    static var dragActivationKey: CGEventFlags { NotchSettings.shared.dragKey.flag }

    /// The cursor has to rest on the closed notch this long before it opens,
    /// so sweeping across the top of the screen doesn't pop it open.
    static var hoverOpenDelay: TimeInterval { NotchSettings.shared.hoverDelay }

    static let expansionAnimationDuration: TimeInterval = 0.75

    // Opens with a hint of life, closes without bouncing.
    static let openSpring: Animation = .spring(response: 0.52, dampingFraction: 0.7, blendDuration: 0)
    static let closeSpring: Animation = .spring(response: 0.58, dampingFraction: 1.0, blendDuration: 0)
    static let expansionSpring: Animation = openSpring
}

// MARK: - Notch Shape
// The top edge is full width with small concave "ears" that blend into the menu bar,
// like the hardware notch does. Only the bottom corners are rounded.

struct NotchShape: Shape {

    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 10

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {

        var path = Path()

        let t = max(0, min(topRadius, rect.width / 4, rect.height / 4))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Artwork Tint
// Average colour of the cover art, lifted so it stays readable on black.

extension NSImage {

    func notchTint() -> Color? {

        var rect = CGRect(origin: .zero, size: size)

        guard let sourceImage = self.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)

        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in

            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.interpolationQuality = .medium
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }

        guard drawn else { return nil }

        let base = NSColor(
            deviceRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return Color(
            hue: Double(hue),
            saturation: Double(saturation),
            brightness: Double(max(brightness, 0.7))
        )
    }
}

// MARK: - Native Media Key & Now Playing Controller
//
// Now Playing comes from the private MediaRemote framework, which reports whatever
// app owns the system Now Playing slot (Music, Spotify, browsers, VLC, podcasts...).
// Since macOS 15.4 only Apple-signed processes can use it, so the call is made inside
// /usr/bin/osascript (JXA) instead of from this app's own process.
// If that fails, we fall back to talking to Music/Spotify directly via AppleScript.

class MediaController {

    // Name of the app that currently owns Now Playing (written on the main thread).
    static var currentSourceApp = ""
    static var currentSourceBundle: String?

    /// Brings the app that is playing (Music, Spotify, a browser...) to the front.
    static func openSourceApp() {

        var bundle = currentSourceBundle

        if bundle == nil {
            switch currentSourceApp {
            case "Music": bundle = "com.apple.Music"
            case "Spotify": bundle = "com.spotify.client"
            default: break
            }
        }

        guard
            let bundle,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return }

        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    private static var fetchInFlight = false

    // Artwork cache so we don't re-extract art every poll.
    private static var artCacheKey = ""
    private static var artCache: NSImage?

    // MediaRemote command IDs
    private enum MRCommand: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private enum MRResult {
        case playing(title: String, artist: String, isPlaying: Bool, app: String, bundle: String?, position: Double, duration: Double)
        case nothing
        case failed
    }

    // MARK: Helpers

    /// Runs a JXA script through /usr/bin/osascript. Returns trimmed stdout, or nil on failure/timeout.
    private static func runJXA(_ source: String, timeout: TimeInterval = 4) -> String? {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runAppleScript(_ source: String) -> String? {

        guard let script = NSAppleScript(source: source) else { return nil }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        return descriptor.stringValue
    }

    private static func loadImage(from source: String) -> NSImage? {

        if source.hasPrefix("http://") || source.hasPrefix("https://") {

            if let url = URL(string: source),
               let data = try? Data(contentsOf: url) {
                return NSImage(data: data)
            }

        } else if !source.isEmpty,
                  FileManager.default.fileExists(atPath: source) {

            if let data = try? Data(contentsOf: URL(fileURLWithPath: source)) {
                return NSImage(data: data)
            }
        }

        return nil
    }

    private static func appIcon(name: String, bundle: String?) -> NSImage? {

        let apps = NSWorkspace.shared.runningApplications

        if let bundle,
           let app = apps.first(where: { $0.bundleIdentifier == bundle }) {
            return app.icon
        }

        return apps.first(where: { $0.localizedName == name })?.icon
    }

    private static func isAppRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Media Keys

    static func postMediaKey(_ key: Int32) {

        func sendEvent(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))

            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }

        sendEvent(down: true)
        sendEvent(down: false)
    }

    // MARK: Playback Control

    private static func sendMediaRemoteCommand(_ command: MRCommand) -> Bool {

        let script = """
        function run() {
            try {
                ObjC.import('Foundation');
                const MediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
                MediaRemote.load;
                const controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
                const options = $.NSDictionary.alloc.init;
                controller.sendCommandOptionsCompletion(\(command.rawValue), options, null);
                $.NSThread.sleepForTimeInterval(0.3);
                return 'ok';
            } catch (e) {
                return 'fail';
            }
        }
        """

        return runJXA(script) == "ok"
    }

    private static func performMediaAction(
        appleScriptVerb: String,
        mrCommand: MRCommand,
        fallbackKey: Int32
    ) {

        // Captured on the calling (main) thread.
        let source = currentSourceApp

        DispatchQueue.global(qos: .userInitiated).async {

            // 1. Music / Spotify: talk to them directly (most reliable).
            if source == "Music" || source == "Spotify" {

                let script = """
                if application "\(source)" is running then
                    tell application "\(source)" to \(appleScriptVerb)
                    return "ok"
                end if
                return "fallback"
                """

                if runAppleScript(script) == "ok" {
                    return
                }
            }

            // 2. Any other source: MediaRemote command to whatever owns Now Playing.
            if sendMediaRemoteCommand(mrCommand) {
                return
            }

            // 3. Last resort: system media key.
            postMediaKey(fallbackKey)
        }
    }

    static func togglePlayPause() {
        performMediaAction(appleScriptVerb: "playpause", mrCommand: .togglePlayPause, fallbackKey: 16)
    }

    static func nextTrack() {
        performMediaAction(appleScriptVerb: "next track", mrCommand: .nextTrack, fallbackKey: 17)
    }

    static func previousTrack() {
        performMediaAction(appleScriptVerb: "previous track", mrCommand: .previousTrack, fallbackKey: 18)
    }

    // MARK: Seeking

    private static func sendMediaRemoteSeek(to seconds: Double) -> Bool {

        // Command 45 = change playback position (best effort for non-Music/Spotify sources).
        let script = """
        function run() {
            try {
                ObjC.import('Foundation');
                const MediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
                MediaRemote.load;
                const controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
                const options = $.NSDictionary.dictionaryWithObjectForKey(
                    $.NSNumber.numberWithDouble(\(seconds)),
                    $('kMRMediaRemoteOptionPlaybackPosition')
                );
                controller.sendCommandOptionsCompletion(45, options, null);
                $.NSThread.sleepForTimeInterval(0.3);
                return 'ok';
            } catch (e) {
                return 'fail';
            }
        }
        """

        return runJXA(script) == "ok"
    }

    /// Jumps playback to `seconds`. Music and Spotify are controlled directly;
    /// anything else goes through MediaRemote.
    static func seek(to seconds: Double) {

        // Captured on the calling (main) thread.
        let source = currentSourceApp
        let target = max(0, Int(seconds.rounded()))

        DispatchQueue.global(qos: .userInitiated).async {

            if source == "Music" || source == "Spotify" {

                let script = """
                if application "\(source)" is running then
                    tell application "\(source)" to set player position to \(target)
                    return "ok"
                end if
                return "fallback"
                """

                if runAppleScript(script) == "ok" {
                    return
                }
            }

            _ = sendMediaRemoteSeek(to: Double(target))
        }
    }

    // MARK: Now Playing (any source, via MediaRemote)

    private static let nowPlayingJXA = """
    function run() {
        try {
            ObjC.import('Foundation');
            const MediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
            MediaRemote.load;

            const Request = $.NSClassFromString('MRNowPlayingRequest');
            const info = Request.localNowPlayingItem.nowPlayingInfo;

            const read = function (key) {
                try {
                    const value = info.valueForKey(key);
                    return value ? ObjC.unwrap(value) : null;
                } catch (e) {
                    return null;
                }
            };

            let app = null;
            let bundle = null;

            try {
                const client = Request.localNowPlayingPlayerPath.client;
                app = ObjC.unwrap(client.displayName);
                try { bundle = ObjC.unwrap(client.bundleIdentifier); } catch (e) {}
            } catch (e) {}

            const title = read('kMRMediaRemoteNowPlayingInfoTitle');

            if (!title) {
                return 'none';
            }

            // Elapsed time is reported as of this timestamp (epoch seconds).
            let timestamp = null;
            try {
                const stamp = info.valueForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
                timestamp = stamp.timeIntervalSince1970;
            } catch (e) {}

            return JSON.stringify({
                title: title,
                artist: read('kMRMediaRemoteNowPlayingInfoArtist'),
                album: read('kMRMediaRemoteNowPlayingInfoAlbum'),
                rate: read('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
                elapsed: read('kMRMediaRemoteNowPlayingInfoElapsedTime'),
                duration: read('kMRMediaRemoteNowPlayingInfoDuration'),
                timestamp: timestamp,
                app: app,
                bundle: bundle
            });
        } catch (e) {
            return 'error';
        }
    }
    """

    private static func fetchViaMediaRemote() -> MRResult {

        guard let output = runJXA(nowPlayingJXA) else { return .failed }

        if output == "none" { return .nothing }

        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String
        else {
            // "error" (no item / framework unavailable) or unparseable output.
            return .failed
        }

        let app = (json["app"] as? String) ?? ""
        let bundle = json["bundle"] as? String

        let artistField = (json["artist"] as? String) ?? ""
        let albumField = (json["album"] as? String) ?? ""

        // Browser tabs often have no artist; fall back to album, then the app name.
        var subtitle = artistField
        if subtitle.isEmpty { subtitle = albumField }
        if subtitle.isEmpty { subtitle = app }

        let rate = (json["rate"] as? NSNumber)?.doubleValue ?? 0

        let duration = max(0, (json["duration"] as? NSNumber)?.doubleValue ?? 0)
        var position = max(0, (json["elapsed"] as? NSNumber)?.doubleValue ?? 0)

        // Elapsed time is a snapshot taken at `timestamp`; bring it up to now.
        if rate > 0, let stamp = (json["timestamp"] as? NSNumber)?.doubleValue {
            position += max(0, Date().timeIntervalSince1970 - stamp) * rate
        }

        if duration > 0 {
            position = min(position, duration)
        }

        return .playing(
            title: title,
            artist: subtitle,
            isPlaying: rate > 0,
            app: app,
            bundle: bundle,
            position: position,
            duration: duration
        )
    }

    // MARK: Artwork (MediaRemote artwork is empty via osascript, so use app-specific paths)

    private static func artwork(forApp app: String, key: String) -> NSImage? {

        if key == artCacheKey, let artCache {
            return artCache
        }

        var image: NSImage?

        if app == "Music" {

            let path = runAppleScript("""
            tell application "Music"
                try
                    if exists (artwork 1 of current track) then
                        set srcData to raw data of artwork 1 of current track
                        set fileName to "/tmp/notchdrop_cover.png"
                        set fileRef to (open for access POSIX file fileName with write permission)
                        set eof fileRef to 0
                        write srcData to fileRef
                        close access fileRef
                        return fileName
                    end if
                end try
            end tell
            return ""
            """) ?? ""

            image = loadImage(from: path)

        } else if app == "Spotify" {

            let url = runAppleScript("""
            tell application "Spotify"
                try
                    return artwork url of current track
                end try
            end tell
            return ""
            """) ?? ""

            image = loadImage(from: url)
        }

        artCacheKey = key
        artCache = image

        return image
    }

    // MARK: Legacy fallback (Music / Spotify only; used if MediaRemote is unavailable)

    private static func fetchLegacy() -> (title: String, artist: String, isPlaying: Bool, art: NSImage?, app: String, position: Double, duration: Double)? {

        // Skip the (slow) script entirely if neither app is running.
        guard isAppRunning("com.apple.Music") || isAppRunning("com.spotify.client") else {
            return nil
        }

        let scriptSource = """
        tell application "System Events"
            if exists (process "Music") then
                tell application "Music"
                    if player state is playing or player state is paused then
                        set artPath to ""

                        try
                            if exists (artwork 1 of current track) then
                                set srcData to raw data of artwork 1 of current track
                                set fileName to "/tmp/notchdrop_cover.png"
                                set fileRef to (open for access POSIX file fileName with write permission)
                                set eof fileRef to 0
                                write srcData to fileRef
                                close access fileRef
                                set artPath to fileName
                            end if
                        end try

                        return (name of current track) & "|||" & (artist of current track) & "|||" & (player state as string) & "|||" & artPath & "|||Music|||" & (player position as string) & "|||" & ((duration of current track) as string)
                    end if
                end tell

            else if exists (process "Spotify") then
                tell application "Spotify"
                    if player state is playing or player state is paused then
                        set artUrl to ""

                        try
                            set artUrl to artwork url of current track
                        end try

                        return (name of current track) & "|||" & (artist of current track) & "|||" & (player state as string) & "|||" & artUrl & "|||Spotify|||" & (player position as string) & "|||" & (((duration of current track) / 1000) as string)
                    end if
                end tell
            end if
        end tell

        return ""
        """

        guard let string = runAppleScript(scriptSource), !string.isEmpty else { return nil }

        let parts = string.components(separatedBy: "|||")

        guard parts.count >= 3 else { return nil }

        let artSource = parts.count > 3 ? parts[3] : ""
        let app = parts.count > 4 ? parts[4] : ""

        func number(at index: Int) -> Double {
            guard parts.count > index else { return 0 }
            return Double(parts[index].replacingOccurrences(of: ",", with: ".")) ?? 0
        }

        return (
            title: parts[0],
            artist: parts[1],
            isPlaying: parts[2] == "playing",
            art: loadImage(from: artSource),
            app: app,
            position: number(at: 5),
            duration: number(at: 6)
        )
    }

    // MARK: Public Fetch

    static func fetchCurrentTrack(
        completion: @escaping (String, String, Bool, NSImage?, Double, Double) -> Void
    ) {

        // Skip if the previous poll is still running (osascript can be slow).
        guard !fetchInFlight else { return }

        fetchInFlight = true

        DispatchQueue.global(qos: .userInitiated).async {

            var title = "Not Playing"
            var artist = "No Active Media"
            var playing = false
            var source = ""
            var bundle: String?
            var art: NSImage?
            var position = 0.0
            var duration = 0.0

            switch fetchViaMediaRemote() {

            case .playing(let t, let a, let isPlaying, let app, let b, let pos, let dur):
                title = t
                artist = a
                playing = isPlaying
                source = app
                bundle = b
                position = pos
                duration = dur
                art = artwork(forApp: app, key: "\(app)|\(t)|\(a)")

            case .nothing:
                break

            case .failed:
                if let legacy = fetchLegacy() {
                    title = legacy.title
                    artist = legacy.artist
                    playing = legacy.isPlaying
                    source = legacy.app
                    art = legacy.art
                    position = legacy.position
                    duration = legacy.duration
                }
            }

            DispatchQueue.main.async {

                fetchInFlight = false
                currentSourceApp = source
                currentSourceBundle = bundle

                // No cover art (e.g. browser, VLC): show the source app's icon instead.
                let image = art ?? (source.isEmpty ? nil : appIcon(name: source, bundle: bundle))

                completion(title, artist, playing, image, position, duration)
            }
        }
    }
}

// MARK: - Settings Options

enum NotchSize: String, CaseIterable, Identifiable {

    case compact, regular, large

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var contentWidth: CGFloat {
        switch self {
        case .compact: return 350
        case .regular: return 380
        case .large: return 430
        }
    }

    var contentHeight: CGFloat {
        switch self {
        case .compact: return 132
        case .regular: return 146
        case .large: return 168
        }
    }
}

enum NotchAccent: String, CaseIterable, Identifiable {

    case blue, purple, pink, orange, green, teal

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return Color.blue
        case .purple: return Color.purple
        case .pink: return Color.pink
        case .orange: return Color.orange
        case .green: return Color.green
        case .teal: return Color.teal
        }
    }
}

enum DragKey: String, CaseIterable, Identifiable {

    case control, option, shift, command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "Control (⌃)"
        case .option: return "Option (⌥)"
        case .shift: return "Shift (⇧)"
        case .command: return "Command (⌘)"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .shift: return .maskShift
        case .command: return .maskCommand
        }
    }
}

// MARK: - Settings Model
// Everything the user can change. Each property saves itself to UserDefaults when it changes.

final class NotchSettings: ObservableObject {

    static let shared = NotchSettings()

    /// Most tabs the notch header can show.
    static let maxTabs = 8

    static let alarmSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private enum Default {
        static let showMenuBarIcon = true
        static let defaultTab = "last"
        // The default 8 tabs, in display order.
        static let tabOrder: [String] = [
            NotchTab.music.rawValue,
            NotchTab.files.rawValue,
            NotchTab.calendar.rawValue,
            NotchTab.alarms.rawValue,
            NotchTab.clipboard.rawValue,
            NotchTab.notes.rawValue,
            NotchTab.timer.rawValue,
            NotchTab.quickActions.rawValue
        ]
        static let openOnHover = true
        static let hoverDelay = 0.15
        static let haptics = true
        static let dragKey = DragKey.control
        static let rememberFiles = false
        static let size = NotchSize.regular
        static let accent = NotchAccent.blue
        static let tintWithArt = true
        static let liveMusic = true
        static let liveFiles = true
        static let showBars = true
        static let scrollingText = true
        static let showSeekBar = true
        static let snoozeMinutes = 5
        static let alarmSound = "Glass"
        static let ringSeconds = 120
        static let calendarDays = 7
        static let showAllDay = true
    }

    // MARK: Storage helpers

    private static func key(_ name: String) -> String {
        "notchdrop.setting." + name
    }

    private static func bool(_ name: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key(name)) as? Bool ?? fallback
    }

    private static func double(_ name: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key(name)) as? Double ?? fallback
    }

    private static func int(_ name: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key(name)) as? Int ?? fallback
    }

    private static func string(_ name: String, _ fallback: String) -> String {
        UserDefaults.standard.object(forKey: key(name)) as? String ?? fallback
    }

    private func put(_ name: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: Self.key(name))
    }

    // MARK: General

    @Published var showMenuBarIcon: Bool {
        didSet {
            put("showMenuBarIcon", showMenuBarIcon)

            if MenuBarVisibility.shared.isVisible != showMenuBarIcon {
                MenuBarVisibility.shared.isVisible = showMenuBarIcon
            }
        }
    }

    /// "last" or a NotchTab raw value.
    @Published var defaultTab: String {
        didSet { put("defaultTab", defaultTab) }
    }

    @Published var lastTab: String {
        didSet { put("lastTab", lastTab) }
    }

    /// The tabs shown in the notch, in display order (at most `maxTabs`).
    @Published var tabOrder: [String] {
        didSet { put("tabOrder", tabOrder) }
    }

    @Published var launchAtLogin = false
    @Published var loginNote: String?

    // MARK: Behavior

    @Published var openOnHover: Bool {
        didSet { put("openOnHover", openOnHover) }
    }

    @Published var hoverDelay: Double {
        didSet { put("hoverDelay", hoverDelay) }
    }

    @Published var haptics: Bool {
        didSet { put("haptics", haptics) }
    }

    @Published var dragKey: DragKey {
        didSet { put("dragKey", dragKey.rawValue) }
    }

    @Published var rememberFiles: Bool {
        didSet { put("rememberFiles", rememberFiles) }
    }

    // MARK: Appearance

    @Published var size: NotchSize {
        didSet {
            put("size", size.rawValue)
            NotchWindowManager.shared.layoutDidChange()
        }
    }

    @Published var accent: NotchAccent {
        didSet { put("accent", accent.rawValue) }
    }

    @Published var tintWithArt: Bool {
        didSet { put("tintWithArt", tintWithArt) }
    }

    @Published var liveMusic: Bool {
        didSet { put("liveMusic", liveMusic) }
    }

    @Published var liveFiles: Bool {
        didSet { put("liveFiles", liveFiles) }
    }

    @Published var showBars: Bool {
        didSet { put("showBars", showBars) }
    }

    @Published var scrollingText: Bool {
        didSet { put("scrollingText", scrollingText) }
    }

    @Published var showSeekBar: Bool {
        didSet { put("showSeekBar", showSeekBar) }
    }

    // MARK: Alarms & calendar

    @Published var snoozeMinutes: Int {
        didSet { put("snoozeMinutes", snoozeMinutes) }
    }

    @Published var alarmSound: String {
        didSet { put("alarmSound", alarmSound) }
    }

    @Published var ringSeconds: Int {
        didSet { put("ringSeconds", ringSeconds) }
    }

    @Published var calendarDays: Int {
        didSet { put("calendarDays", calendarDays) }
    }

    @Published var showAllDay: Bool {
        didSet { put("showAllDay", showAllDay) }
    }

    // MARK: Utility feature settings

    @Published var clipboardEnabled: Bool { didSet { put("clipboardEnabled", clipboardEnabled) } }
    @Published var clipboardHistoryLimit: Int { didSet { put("clipboardHistoryLimit", clipboardHistoryLimit) } }
    @Published var clipboardPersist: Bool { didSet { put("clipboardPersist", clipboardPersist) } }
    @Published var notesPersist: Bool { didSet { put("notesPersist", notesPersist) } }
    @Published var downloadsEnabled: Bool { didSet { put("downloadsEnabled", downloadsEnabled) } }
    @Published var timerSound: String { didSet { put("timerSound", timerSound) } }
    @Published var timerHaptics: Bool { didSet { put("timerHaptics", timerHaptics) } }
    @Published var showSystemStatus: Bool { didSet { put("showSystemStatus", showSystemStatus) } }
    @Published var showActiveDownloadsLive: Bool { didSet { put("showActiveDownloadsLive", showActiveDownloadsLive) } }
    @Published var hiddenQuickActions: [String] { didSet { put("hiddenQuickActions", hiddenQuickActions) } }

    // MARK: Init

    /// Saved order if there is one; otherwise carry over the old "hidden tabs"
    /// choice (capped at 8); otherwise the default 8.
    private static func loadTabOrder() -> [String] {

        let defaults = UserDefaults.standard

        func clean(_ raw: [String]) -> [String] {
            var seen = Set<String>()
            let valid = raw.filter { NotchTab(rawValue: $0) != nil && seen.insert($0).inserted }
            return Array(valid.prefix(NotchSettings.maxTabs))
        }

        if let saved = defaults.stringArray(forKey: key("tabOrder")) {
            let order = clean(saved)
            if !order.isEmpty { return order }
        }

        if let hidden = defaults.stringArray(forKey: key("hiddenTabs")), !hidden.isEmpty {
            let order = clean(NotchTab.allCases.map { $0.rawValue }.filter { !hidden.contains($0) })
            if !order.isEmpty { return order }
        }

        return Default.tabOrder
    }

    private init() {

        showMenuBarIcon = Self.bool("showMenuBarIcon", Default.showMenuBarIcon)
        defaultTab = Self.string("defaultTab", Default.defaultTab)
        lastTab = Self.string("lastTab", NotchTab.music.rawValue)
        tabOrder = Self.loadTabOrder()

        openOnHover = Self.bool("openOnHover", Default.openOnHover)
        hoverDelay = Self.double("hoverDelay", Default.hoverDelay)
        haptics = Self.bool("haptics", Default.haptics)
        dragKey = DragKey(rawValue: Self.string("dragKey", Default.dragKey.rawValue)) ?? Default.dragKey
        rememberFiles = Self.bool("rememberFiles", Default.rememberFiles)

        size = NotchSize(rawValue: Self.string("size", Default.size.rawValue)) ?? Default.size
        accent = NotchAccent(rawValue: Self.string("accent", Default.accent.rawValue)) ?? Default.accent
        tintWithArt = Self.bool("tintWithArt", Default.tintWithArt)
        liveMusic = Self.bool("liveMusic", Default.liveMusic)
        liveFiles = Self.bool("liveFiles", Default.liveFiles)
        showBars = Self.bool("showBars", Default.showBars)
        scrollingText = Self.bool("scrollingText", Default.scrollingText)
        showSeekBar = Self.bool("showSeekBar", Default.showSeekBar)

        snoozeMinutes = Self.int("snoozeMinutes", Default.snoozeMinutes)
        alarmSound = Self.string("alarmSound", Default.alarmSound)
        ringSeconds = Self.int("ringSeconds", Default.ringSeconds)
        calendarDays = Self.int("calendarDays", Default.calendarDays)
        showAllDay = Self.bool("showAllDay", Default.showAllDay)

        clipboardEnabled = Self.bool("clipboardEnabled", true)
        clipboardHistoryLimit = Self.int("clipboardHistoryLimit", 50)
        clipboardPersist = Self.bool("clipboardPersist", true)
        notesPersist = Self.bool("notesPersist", true)
        downloadsEnabled = Self.bool("downloadsEnabled", true)
        timerSound = Self.string("timerSound", "Glass")
        timerHaptics = Self.bool("timerHaptics", true)
        showSystemStatus = Self.bool("showSystemStatus", true)
        showActiveDownloadsLive = Self.bool("showActiveDownloadsLive", true)
        hiddenQuickActions = UserDefaults.standard.stringArray(forKey: Self.key("hiddenQuickActions")) ?? []
    }

    // MARK: Tabs

    func isTabEnabled(_ tab: NotchTab) -> Bool {
        tabOrder.contains(tab.rawValue)
    }

    /// Shown tabs, in the order the user chose.
    var enabledTabs: [NotchTab] {
        tabOrder.compactMap { NotchTab(rawValue: $0) }
    }

    /// Tabs that are not currently shown.
    var availableTabs: [NotchTab] {
        NotchTab.allCases.filter { !isTabEnabled($0) }
    }

    var canAddTab: Bool {
        tabOrder.count < Self.maxTabs
    }

    /// At least one tab always stays on, and never more than `maxTabs`.
    func setTab(_ tab: NotchTab, enabled: Bool) {

        if enabled {
            guard !isTabEnabled(tab), canAddTab else { return }
            tabOrder.append(tab.rawValue)
            return
        }

        guard enabledTabs.count > 1, isTabEnabled(tab) else { return }

        tabOrder.removeAll { $0 == tab.rawValue }

        if defaultTab == tab.rawValue {
            defaultTab = "last"
        }
    }

    /// Move a shown tab earlier (-1) or later (+1) in the header.
    func moveTab(_ tab: NotchTab, by offset: Int) {

        guard let index = tabOrder.firstIndex(of: tab.rawValue) else { return }

        let target = index + offset

        guard tabOrder.indices.contains(target) else { return }

        tabOrder.swapAt(index, target)
    }

    func resetTabs() {
        tabOrder = Default.tabOrder
    }

    /// The tab the notch shows when the app starts.
    func startTab() -> NotchTab {

        let wanted = defaultTab == "last" ? lastTab : defaultTab

        if let tab = NotchTab(rawValue: wanted), isTabEnabled(tab) {
            return tab
        }

        return enabledTabs.first ?? .music
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {

        DispatchQueue.global(qos: .utility).async { [weak self] in

            let status = SMAppService.mainApp.status

            DispatchQueue.main.async { [weak self] in

                guard let self else { return }

                let enabled = (status == .enabled)

                if self.launchAtLogin != enabled {
                    self.launchAtLogin = enabled
                }

                if status == .requiresApproval {

                    let message = "Approve NotchDrop in System Settings › General › Login Items."

                    if self.loginNote != message {
                        self.loginNote = message
                    }
                }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {

        if loginNote != nil {
            loginNote = nil
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
        }

        refreshLaunchAtLogin()
    }

    // MARK: Reset

    func resetToDefaults() {

        showMenuBarIcon = Default.showMenuBarIcon
        defaultTab = Default.defaultTab
        tabOrder = Default.tabOrder

        openOnHover = Default.openOnHover
        hoverDelay = Default.hoverDelay
        haptics = Default.haptics
        dragKey = Default.dragKey
        rememberFiles = Default.rememberFiles

        size = Default.size
        accent = Default.accent
        tintWithArt = Default.tintWithArt
        liveMusic = Default.liveMusic
        liveFiles = Default.liveFiles
        showBars = Default.showBars
        scrollingText = Default.scrollingText
        showSeekBar = Default.showSeekBar

        snoozeMinutes = Default.snoozeMinutes
        alarmSound = Default.alarmSound
        ringSeconds = Default.ringSeconds
        calendarDays = Default.calendarDays
        showAllDay = Default.showAllDay

        clipboardEnabled = true
        clipboardHistoryLimit = 50
        clipboardPersist = true
        notesPersist = true
        downloadsEnabled = true
        timerSound = "Glass"
        timerHaptics = true
        showSystemStatus = true
        showActiveDownloadsLive = true
        hiddenQuickActions = []
    }
}

// MARK: - Menu Bar Visibility
// Only this one switch is observed by the app scene, so changing any other setting
// (or switching tabs) never makes the menu bar item redraw.

final class MenuBarVisibility: ObservableObject {

    static let shared = MenuBarVisibility()

    @Published var isVisible: Bool

    private init() {
        isVisible = NotchSettings.shared.showMenuBarIcon
    }
}

// MARK: - Settings Window
// A plain NSWindow (not a SwiftUI Settings scene) so it opens reliably from a menu bar app.
// ⌘, (opens) and ⌘W (closes) are handled by a key monitor in the app delegate.

final class SettingsWindowController: NSObject {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {

        if window == nil {

            let hosting = NSHostingView(rootView: SettingsView())

            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 570),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )

            newWindow.title = "NotchDrop Settings"
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.center()

            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        NotchSettings.shared.refreshLaunchAtLogin()
    }

    /// ⌘W closes the settings window when it is the key window.
    func closeIfKey() -> Bool {

        guard let window, window.isKeyWindow else { return false }

        window.close()

        return true
    }
}

// MARK: - Settings View

enum SettingsPane: String, CaseIterable, Identifiable {

    case general, appearance, behavior, timekeeping, features

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .behavior: return "Behavior"
        case .timekeeping: return "Alarms & Calendar"
        case .features: return "Features"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .behavior: return "slider.horizontal.3"
        case .timekeeping: return "clock"
        case .features: return "square.grid.2x2"
        }
    }
}

final class SettingsPaneModel: ObservableObject {

    static let shared = SettingsPaneModel()

    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {

    @ObservedObject private var settings = NotchSettings.shared
    @ObservedObject private var paneModel = SettingsPaneModel.shared

    var body: some View {

        VStack(spacing: 0) {

            paneBar

            Divider()

            paneContent
                .formStyle(.grouped)
        }
        .frame(width: 600, height: 570)
    }

    // MARK: Pane bar

    private var paneBar: some View {

        HStack(spacing: 6) {

            ForEach(SettingsPane.allCases) { pane in

                Button(action: { paneModel.pane = pane }) {

                    VStack(spacing: 3) {

                        Image(systemName: pane.icon)
                            .font(.system(size: 16))

                        Text(pane.title)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(paneModel.pane == pane ? Color.accentColor : Color.secondary)
                    .frame(width: 112, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(paneModel.pane == pane ? 0.08 : 0.0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: paneModel.pane)
    }

    @ViewBuilder
    private var paneContent: some View {

        switch paneModel.pane {
        case .general: generalPane
        case .appearance: appearancePane
        case .behavior: behaviorPane
        case .timekeeping: timekeepingPane
        case .features: featuresPane
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: General

    private var generalPane: some View {

        Form {

            Section {

                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)

                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )

            } header: {
                Text("App")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {

                    note("If you hide the menu bar icon, open Settings with the gear in the notch, or press ⌘, while NotchDrop is the active app.")

                    if let loginNote = settings.loginNote {
                        Text(loginNote)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Section {

                Picker("Open to", selection: $settings.defaultTab) {

                    Text("Last used").tag("last")

                    ForEach(settings.enabledTabs) { tab in
                        Text(tab.title).tag(tab.rawValue)
                    }
                }

            } header: {
                Text("Tabs")
            }

            Section {

                ForEach(Array(settings.enabledTabs.enumerated()), id: \.element.id) { index, tab in

                    HStack(spacing: 10) {

                        Image(systemName: tab.icon)
                            .frame(width: 20)

                        Text(tab.title)

                        Spacer()

                        Button(action: { settings.moveTab(tab, by: -1) }) {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Move earlier")

                        Button(action: { settings.moveTab(tab, by: 1) }) {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == settings.enabledTabs.count - 1)
                        .help("Move later")

                        Button(action: { settings.setTab(tab, enabled: false) }) {
                            Image(systemName: "minus.circle.fill")
                        }
                        .disabled(settings.enabledTabs.count <= 1)
                        .help("Remove from notch")
                    }
                    .buttonStyle(.borderless)
                }

            } header: {
                Text("Shown in notch (\(settings.enabledTabs.count) of \(NotchSettings.maxTabs))")
            } footer: {
                note("The order here is the order of the icons in the notch. At least one tab stays on.")
            }

            Section {

                ForEach(settings.availableTabs) { tab in

                    HStack(spacing: 10) {

                        Image(systemName: tab.icon)
                            .frame(width: 20)

                        Text(tab.title)

                        Spacer()

                        Button(action: { settings.setTab(tab, enabled: true) }) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(!settings.canAddTab)
                        .help("Add to notch")
                    }
                    .buttonStyle(.borderless)
                }

                Button("Restore Default Tabs") {
                    settings.resetTabs()
                }

            } header: {
                Text("Available")
            } footer: {
                if !settings.canAddTab {
                    note("The notch shows up to \(NotchSettings.maxTabs) tabs. Remove one to add another.")
                }
            }

            Section {
                Button("Reset All Settings") {
                    settings.resetToDefaults()
                }
            }
        }
    }

    // MARK: Appearance

    private var appearancePane: some View {

        Form {

            Section {

                Picker("Size", selection: $settings.size) {
                    ForEach(NotchSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent color") {

                    HStack(spacing: 10) {

                        ForEach(NotchAccent.allCases) { option in

                            Button(action: { settings.accent = option }) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                Color.primary.opacity(settings.accent == option ? 0.85 : 0.0),
                                                lineWidth: 2
                                            )
                                            .padding(-3)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(option.title)
                        }
                    }
                }

            } header: {
                Text("Notch")
            }

            Section {

                Toggle("Show music (artwork and bars)", isOn: $settings.liveMusic)

                Toggle("Show file count when files are waiting", isOn: $settings.liveFiles)

                Toggle("Animated bars while playing", isOn: $settings.showBars)
                    .disabled(!settings.liveMusic)

            } header: {
                Text("Closed notch")
            } footer: {
                note("The closed notch keeps the same width whether music is playing or not.")
            }

            Section {

                Toggle("Tint with album art", isOn: $settings.tintWithArt)

                Toggle("Scroll long titles", isOn: $settings.scrollingText)

                Toggle("Show seek bar", isOn: $settings.showSeekBar)

            } header: {
                Text("Music tab")
            }
        }
    }

    // MARK: Behavior

    private var behaviorPane: some View {

        Form {

            Section {

                Toggle("Open when hovering the notch", isOn: $settings.openOnHover)

                LabeledContent("Hover delay") {

                    HStack {

                        Slider(value: $settings.hoverDelay, in: 0...0.6, step: 0.05)
                            .frame(width: 160)

                        Text(String(format: "%.2fs", settings.hoverDelay))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .disabled(!settings.openOnHover)

                Toggle("Haptic feedback when opening", isOn: $settings.haptics)

            } header: {
                Text("Opening")
            } footer: {
                note("With hover off, click the notch to open it.")
            }

            Section {

                Picker("Hold while dragging files", selection: $settings.dragKey) {
                    ForEach(DragKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }

                Toggle("Remember files between launches", isOn: $settings.rememberFiles)

            } header: {
                Text("File shelf")
            } footer: {
                note("Hold the key while dragging files toward the top of the screen to open the drop zone. Without it Finder keeps full control of the drag.")
            }
        }
    }

    // MARK: Features

    private var featuresPane: some View {

        Form {
            Section {
                Toggle("Clipboard history", isOn: $settings.clipboardEnabled)
                Stepper("Maximum clipboard items: \(settings.clipboardHistoryLimit)", value: $settings.clipboardHistoryLimit, in: 10...200, step: 10)
                Toggle("Persist clipboard between launches", isOn: $settings.clipboardPersist)
            } header: { Text("Clipboard") }

            Section {
                Toggle("Persist notes", isOn: $settings.notesPersist)
                Toggle("Monitor Downloads", isOn: $settings.downloadsEnabled)
                Toggle("Show active downloads in closed notch", isOn: $settings.showActiveDownloadsLive)
            } header: { Text("Utilities") }

            Section {
                ForEach(QuickAction.allCases) { action in
                    Toggle(action.title, isOn: Binding(get: { !settings.hiddenQuickActions.contains(action.rawValue) }, set: { enabled in
                        if enabled { settings.hiddenQuickActions.removeAll { $0 == action.rawValue } } else if !settings.hiddenQuickActions.contains(action.rawValue) { settings.hiddenQuickActions.append(action.rawValue) }
                    }))
                }
            } header: { Text("Quick Actions") }

            Section {
                Toggle("Timer haptics", isOn: $settings.timerHaptics)
                Picker("Timer sound", selection: $settings.timerSound) {
                    ForEach(NotchSettings.alarmSounds, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Show System status", isOn: $settings.showSystemStatus)
            } header: { Text("Timer & System") }

            Section {
                Text("New utility tabs follow your existing tab visibility settings. Hide anything you do not use from General → Tabs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Alarms & calendar

    private var timekeepingPane: some View {

        Form {

            Section {

                HStack {

                    Picker("Alarm sound", selection: $settings.alarmSound) {
                        ForEach(NotchSettings.alarmSounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }

                    Button("Preview") {
                        NSSound(named: NSSound.Name(settings.alarmSound))?.play()
                    }
                }

                Picker("Snooze for", selection: $settings.snoozeMinutes) {
                    ForEach([3, 5, 10, 15, 20], id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }

                Picker("Stop ringing after", selection: $settings.ringSeconds) {
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }

            } header: {
                Text("Alarms")
            }

            Section {

                Picker("Look ahead", selection: $settings.calendarDays) {
                    Text("Today").tag(1)
                    Text("3 days").tag(3)
                    Text("1 week").tag(7)
                    Text("2 weeks").tag(14)
                }

                Toggle("Include all-day events", isOn: $settings.showAllDay)

            } header: {
                Text("Calendar")
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct NotchDropApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @StateObject private var menuBar = MenuBarVisibility.shared

    // Writes are ignored when nothing changed, so this can never ping-pong.
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { menuBar.isVisible },
            set: { newValue in
                if NotchSettings.shared.showMenuBarIcon != newValue {
                    NotchSettings.shared.showMenuBarIcon = newValue
                }
            }
        )
    }

    var body: some Scene {
        MenuBarExtra("NotchDrop", systemImage: "tray.and.arrow.down.fill", isInserted: menuBarBinding) {
            MenuBarView()
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {

    var body: some View {
        VStack {
            Text("NotchDrop")
                .font(.headline)

            Divider()

            Button("Toggle Notch Panel") {
                NotchWindowManager.shared.togglePanel()
            }

            Button("Clear Stored Files") {
                NotchWindowManager.shared.clearFiles()
            }

            Button("Settings…") {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchWindowManager.shared.setupWindow()

        // ⌘, opens Settings and ⌘W closes it, whenever NotchDrop is the active app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            guard flags == .command else { return event }

            let key = event.charactersIgnoringModifiers ?? ""

            if key == "," {
                SettingsWindowController.shared.show()
                return nil
            }

            if key == "w" && SettingsWindowController.shared.closeIfKey() {
                return nil
            }

            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let notchDropOpenRequested = Notification.Name("NotchDropOpenRequested")
    static let notchDropSelectTab = Notification.Name("NotchDropSelectTab")
    static let notchDropFileReceived = Notification.Name("NotchDropFileReceived")
    static let notchDropContentReceived = Notification.Name("NotchDropContentReceived")
}

// MARK: - AppKit Drag Destination

final class NotchPanel: NSPanel, NSDraggingDestination {

    weak var windowManager: NotchWindowManager?

    override var canBecomeKey: Bool { windowManager?.allowsKeyboardInput ?? false }

    private func hasSupportedContent(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self, NSString.self], options: nil)
    }

    private func isOverDropZone(_ sender: NSDraggingInfo) -> Bool {
        // NSDraggingInfo's location is in the destination window's coordinate
        // system. Use AppKit's current screen location here instead of relying
        // on an NSWindow conversion method that NSPanel itself does not expose.
        return windowManager?.canAcceptFileDrop(atScreenLocation: NSEvent.mouseLocation) == true
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasSupportedContent(sender), isOverDropZone(sender) else { return [] }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasSupportedContent(sender), isOverDropZone(sender) else { return [] }
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {}
    func draggingEnded(_ sender: NSDraggingInfo) {}

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasSupportedContent(sender) && isOverDropZone(sender)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isOverDropZone(sender) else { return false }
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty { windowManager?.receiveDroppedFiles(fileURLs); return true }
            if let url = urls.first { windowManager?.receiveDroppedContent(.url(url)); return true }
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            windowManager?.receiveDroppedContent(.text(text))
            return true
        }
        return false
    }

    func concludeDragOperation(_ sender: NSDraggingInfo?) {}
}

// MARK: - Precise Hit-Test View

final class NotchInteractionView: NSView {

    weak var windowManager: NotchWindowManager?

    private let hostingView: NSView

    init(hostingView: NSView, windowManager: NotchWindowManager) {

        self.hostingView = hostingView
        self.windowManager = windowManager

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        addSubview(hostingView)
        layoutHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHostingView()
    }

    private func layoutHostingView() {
        let size = NotchMetrics.dragHitboxSize

        hostingView.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {

        guard let windowManager else { return nil }

        if windowManager.isHitboxExpanded {
            return super.hitTest(point)
        }

        let notchWidth = NotchMetrics.collapsedSize.width
        let notchHeight = NotchMetrics.collapsedSize.height

        let originX = (bounds.width - notchWidth) / 2
        let originY = bounds.height - notchHeight

        let shapePoint = CGPoint(
            x: point.x - originX,
            y: notchHeight - (point.y - originY)
        )

        let notchPath = NotchShape(
            topRadius: NotchMetrics.collapsedTopRadius,
            bottomRadius: NotchMetrics.collapsedRadius
        )
            .path(in: CGRect(x: 0, y: 0, width: notchWidth, height: notchHeight))

        guard notchPath.contains(shapePoint) else { return nil }

        return super.hitTest(point)
    }
}

// MARK: - Window Manager

final class NotchWindowManager: ObservableObject {

    static let shared = NotchWindowManager()

    private var window: NotchPanel?

    @Published var isExpanded = false
    @Published var isHitboxExpanded = false
    @Published private(set) var isFileDragging = false
    @Published var clearTrigger = false
    @Published private(set) var visualExpanded = false
    @Published private(set) var isPinned = false

    // Width added beside the closed notch while music plays / files wait.
    @Published private(set) var liveWing: CGFloat = 0
    // Bumped when the display layout changes so SwiftUI re-reads NotchMetrics.
    @Published private(set) var layoutRevision = 0

    private var monitors: [Any] = []
    private var hoverOpenWork: DispatchWorkItem?

    private enum HoverState {
        case armed
        case expanded
        case closing
        case waitingForExit
    }

    private var hoverState: HoverState = .armed
    private var cursorWasInsideCollapsedNotch = false

    // True while the notch is closing because the cursor left it (not after a click or unpin).
    // In that case the cursor being on the closed notch again is a deliberate return.
    private var closedByHover = false
    private var reopenTimer: Timer?
    private var contractionGeneration = 0
    private var contractionWorkItem: DispatchWorkItem?
    private var dragSessionActive = false
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragWatchdog: Timer?

    // FIX: pending flag for the delayed end-of-drag teardown.
    private var dragEndPending = false

    // Polls the modifier key state while a file drag is in progress.
    private var dragPollTimer: Timer?

    // While the notch is hover-open, polls the cursor so it always closes on exit,
    // even if mouse-moved events stop arriving (e.g. after clicking inside it).
    private var hoverExitTimer: Timer?

    // MARK: Setup

    func setupWindow() {

        guard let mainScreen = NSScreen.main else { return }

        NotchMetrics.configure(for: mainScreen)
        NotchMetrics.applySize(NotchSettings.shared.size)

        let size = NotchMetrics.collapsedSize

        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.windowManager = self
        panel.level = .popUpMenu

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        // Always dark, so menus, tooltips and text fields match the black notch.
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.registerForDraggedTypes([.fileURL, .URL, .string])

        let hostingView = NSHostingView(rootView: NotchContainerView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        let interactionView = NotchInteractionView(
            hostingView: hostingView,
            windowManager: self
        )

        interactionView.wantsLayer = true
        interactionView.layer?.backgroundColor = NSColor.clear.cgColor
        interactionView.layer?.isOpaque = false

        panel.contentView = interactionView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.isOpaque = false

        self.window = panel

        let topLeft = NSPoint(
            x: mainScreen.frame.midX - size.width / 2,
            y: mainScreen.frame.maxY
        )

        panel.setFrameTopLeftPoint(topLeft)
        panel.orderFrontRegardless()

        updateCollapsedHoverState()

        startMouseMonitoring()
        startDragMonitoring()

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }

        monitors.append(screenObserver)
    }

    /// Display plugged in / unplugged / resolution changed: measure the notch again.
    private func screenParametersChanged() {

        NotchMetrics.configure(for: NSScreen.main)

        layoutRevision += 1

        refreshWindow()
    }

    /// The size preset changed in Settings: re-measure and resize the window.
    func layoutDidChange() {

        NotchMetrics.applySize(NotchSettings.shared.size)

        layoutRevision += 1

        refreshWindow()
    }

    /// Widens the closed notch (beside the hardware notch) so it keeps one width.
    func setLiveActivity(_ active: Bool) {

        let target: CGFloat = active ? NotchMetrics.liveWingWidth : 0

        guard liveWing != target else { return }

        NotchMetrics.liveWing = target
        liveWing = target

        refreshWindow()
    }

    // MARK: Window Sizing

    private var screenFrame: NSRect? {
        (window?.screen ?? NSScreen.main)?.frame
    }

    private func applyWindowFrame(size: CGSize) {

        guard let window, let screenFrame else { return }

        var frame = window.frame
        frame.size = size

        window.setFrame(frame, display: true)

        let topLeft = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY
        )

        window.setFrameTopLeftPoint(topLeft)
    }

    private func targetWindowSize() -> CGSize {

        if isFileDragging {
            return NotchMetrics.dragHitboxSize
        }

        if visualExpanded {
            return NotchMetrics.expandedWindowSize
        }

        return NotchMetrics.collapsedSize
    }

    // MARK: Window Refresh

    private func refreshWindow() {

        isHitboxExpanded = visualExpanded || isFileDragging

        let target = targetWindowSize()

        guard let window else { return }

        let currentSize = window.frame.size

        if target.width >= currentSize.width || target.height >= currentSize.height {

            contractionGeneration += 1
            contractionWorkItem?.cancel()
            contractionWorkItem = nil

            applyWindowFrame(size: target)
            return
        }

        contractionGeneration += 1
        let generation = contractionGeneration

        contractionWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in

            guard let self else { return }
            guard generation == self.contractionGeneration else { return }

            let currentTarget = self.targetWindowSize()

            guard currentTarget == target else {
                self.contractionWorkItem = nil
                return
            }

            self.applyWindowFrame(size: currentTarget)

            self.isHitboxExpanded = self.visualExpanded || self.isFileDragging

            self.contractionWorkItem = nil

            if currentTarget == NotchMetrics.collapsedSize,
               !self.visualExpanded,
               !self.isFileDragging,
               !self.isExpanded,
               !self.isPinned {

                guard let screenFrame = self.screenFrame else {
                    self.hoverState = .armed
                    self.cursorWasInsideCollapsedNotch = false
                    return
                }

                let mouse = NSEvent.mouseLocation

                let inside = self.mouseIsInsideCollapsedNotch(mouse, screenFrame: screenFrame)

                if self.closedByHover {

                    // The cursor left on its own, so being on the notch now means it came
                    // back on purpose: open again instead of waiting for it to leave first.
                    self.closedByHover = false
                    self.stopReopenWatch()

                    self.cursorWasInsideCollapsedNotch = inside
                    self.hoverState = .armed

                    if inside {
                        self.scheduleHoverOpen()
                    }

                    return
                }

                self.cursorWasInsideCollapsedNotch = inside
                self.hoverState = inside ? .waitingForExit : .armed
            }
        }

        contractionWorkItem = item

        DispatchQueue.main.asyncAfter(
            deadline: .now() + NotchMetrics.expansionAnimationDuration,
            execute: item
        )
    }

    // MARK: Manual Expansion

    func togglePanel() {

        if isExpanded {

            isExpanded = false

            if isPinned {
                setVisualExpansion(true)
            } else {
                closedByHover = false
                stopReopenWatch()
                hoverState = .closing
                cursorWasInsideCollapsedNotch = true
                setVisualExpansion(false)
            }

            return
        }

        contractionGeneration += 1
        contractionWorkItem?.cancel()
        contractionWorkItem = nil

        isExpanded = true
        cursorWasInsideCollapsedNotch = false
        hoverState = .expanded

        setVisualExpansion(true)
    }

    func setVisualExpansion(_ expanded: Bool) {

        if expanded {

            contractionGeneration += 1
            contractionWorkItem?.cancel()
            contractionWorkItem = nil

            closedByHover = false
            stopReopenWatch()

            if !isFileDragging {
                hoverState = .expanded
            }

        } else {

            if !isExpanded && !isPinned && !isFileDragging {
                hoverState = .closing
            }
        }

        visualExpanded = expanded
        allowsKeyboardInput = expanded || isExpanded || isPinned || isFileDragging

        if expanded {
            startHoverExitWatch()
        } else {
            stopHoverExitWatch()
            if let window, window.isKeyWindow {
                window.resignKey()
            }
        }

        refreshWindow()

        if expanded, let window {
            DispatchQueue.main.async {
                guard self.allowsKeyboardInput else { return }
                window.makeKey()
            }
        }
    }

    // MARK: Pin State

    func setPinned(_ pinned: Bool) {

        isPinned = pinned

        if pinned {

            contractionGeneration += 1
            contractionWorkItem?.cancel()
            contractionWorkItem = nil

            hoverState = .expanded
            cursorWasInsideCollapsedNotch = false

            setVisualExpansion(true)

        } else if !isExpanded {

            if visualExpanded {
                hoverState = .expanded
            } else {
                updateCollapsedHoverState()
            }
        }
    }

    // MARK: Click Handling

    /// Click on the notch background.
    /// Clicks never make the notch "sticky" (that is what forced an extra click to
    /// close it). Only the menu-bar "Toggle Notch Panel" makes it sticky.
    func handleNotchTap() {

        // Sticky (opened from the menu bar): a click closes it.
        if isExpanded {
            togglePanel()
            return
        }

        // Hover-open: clicks do nothing; it closes itself when the cursor leaves.
        if visualExpanded {
            return
        }

        // Collapsed: open it, hover-style.
        hoverState = .expanded
        cursorWasInsideCollapsedNotch = true

        setVisualExpansion(true)
    }

    /// Hands control back to hover handling: the notch closes when the cursor leaves.
    func clearManualExpansion() {

        holdsOpen = false

        guard isExpanded else { return }

        isExpanded = false

        if visualExpanded {
            hoverState = .expanded
            cursorWasInsideCollapsedNotch = true
        }
    }

    // MARK: Hold Open (alarm ringing / typing a time)

    private var holdsOpen = false

    /// Pops the notch open (and keeps it open) while an alarm rings or a time is being typed.
    func holdOpen() {

        guard !isExpanded else { return }

        holdsOpen = true
        togglePanel()
    }

    /// Lets the notch go back to normal hover behaviour once that is finished.
    func releaseHold() {

        guard holdsOpen else { return }

        holdsOpen = false
        clearManualExpansion()
    }

    // MARK: Keyboard Input

    /// The panel only accepts keyboard focus while a time is being typed, so it never
    /// steals keystrokes meant for other apps.
    private(set) var allowsKeyboardInput = false

    func beginKeyboardInput() {

        allowsKeyboardInput = true
        holdOpen()
    }

    func endKeyboardInput() {

        allowsKeyboardInput = false
        releaseHold()

        // Give up key status (re-showing the panel does not make it key again).
        if let window, window.isKeyWindow {
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
    }

    // MARK: Debug (run the app from Terminal with NOTCHDROP_DEBUG=1 to see this)

    private let debugEnabled = ProcessInfo.processInfo.environment["NOTCHDROP_DEBUG"] != nil
    private var lastBlockedLog = Date.distantPast

    func debugState(_ tag: String) {

        guard debugEnabled else { return }

        print("[NotchDrop] \(tag): sticky=\(isExpanded) visual=\(visualExpanded) pinned=\(isPinned) dragging=\(isFileDragging) hover=\(hoverState)")
    }

    // MARK: Hover Exit Watch

    private func startHoverExitWatch() {

        guard hoverExitTimer == nil else { return }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkHoverExit()
        }

        // .common so it keeps firing while a mouse button is held.
        RunLoop.main.add(timer, forMode: .common)

        hoverExitTimer = timer
    }

    private func stopHoverExitWatch() {
        hoverExitTimer?.invalidate()
        hoverExitTimer = nil
    }

    /// Closes a hover-open notch as soon as the cursor is outside it.
    /// Deliberately independent of the hover state machine so nothing can leave it stuck open.
    private func checkHoverExit() {

        // Self-heal a stuck drag state: no mouse button held means the drag is over.
        if isFileDragging && NSEvent.pressedMouseButtons & 1 == 0 {
            finishDragSession()
        }

        guard visualExpanded, let screenFrame else { return }

        let outside = !mouseIsInsideExpandedPanel(NSEvent.mouseLocation, screenFrame: screenFrame)

        guard outside else { return }

        // Pinned / sticky / dragging are the only reasons to stay open.
        if isExpanded || isPinned || isFileDragging {

            if debugEnabled, Date().timeIntervalSince(lastBlockedLog) > 1 {
                lastBlockedLog = Date()
                debugState("cursor outside but staying open")
            }

            return
        }

        closedByHover = true

        setVisualExpansion(false)

        startReopenWatch()
    }

    // MARK: Hover Expansion

    private func beginHoverExpansion() {

        guard
            hoverState == .armed,
            !isExpanded,
            !isPinned,
            !isFileDragging,
            !visualExpanded
        else { return }

        hoverState = .expanded
        cursorWasInsideCollapsedNotch = true

        contractionGeneration += 1
        contractionWorkItem?.cancel()
        contractionWorkItem = nil

        setVisualExpansion(true)

        // A light tick on trackpads, like the real thing opening.
        if NotchSettings.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Opens only if the cursor is still on the closed notch after a short rest.
    private func scheduleHoverOpen() {

        hoverOpenWork?.cancel()

        guard NotchSettings.shared.openOnHover else { return }

        let work = DispatchWorkItem { [weak self] in

            guard let self, let screenFrame = self.screenFrame else { return }

            guard self.mouseIsInsideCollapsedNotch(NSEvent.mouseLocation, screenFrame: screenFrame) else {
                return
            }

            self.beginHoverExpansion()
        }

        hoverOpenWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + NotchMetrics.hoverOpenDelay,
            execute: work
        )
    }

    private func endHoverExpansion() {

        guard
            !isExpanded,
            !isPinned,
            !isFileDragging,
            visualExpanded,
            hoverState == .expanded
        else { return }

        hoverState = .closing

        closedByHover = true

        setVisualExpansion(false)

        startReopenWatch()
    }

    // MARK: Reopen While Closing
    // While the notch is shrinking its window still covers the area, so the global
    // mouse-moved monitor can miss the cursor coming back. Poll briefly instead.

    private func startReopenWatch() {

        reopenTimer?.invalidate()

        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.checkReopen()
        }

        RunLoop.main.add(timer, forMode: .common)

        reopenTimer = timer
    }

    private func stopReopenWatch() {
        reopenTimer?.invalidate()
        reopenTimer = nil
    }

    private func checkReopen() {

        guard closedByHover, !visualExpanded, !isFileDragging, !isPinned, !isExpanded else {
            stopReopenWatch()
            return
        }

        guard let screenFrame else { return }

        let inside = mouseIsInsideCollapsedNotch(NSEvent.mouseLocation, screenFrame: screenFrame)

        if inside {

            // Only on the way in; scheduling again every tick would keep pushing the delay back.
            guard !cursorWasInsideCollapsedNotch else { return }

            cursorWasInsideCollapsedNotch = true
            hoverState = .armed

            scheduleHoverOpen()

        } else {

            cursorWasInsideCollapsedNotch = false
        }
    }

    // MARK: Mouse Geometry

    private func mouseIsInsideCollapsedNotch(_ mouse: NSPoint, screenFrame: NSRect) -> Bool {

        let width = NotchMetrics.collapsedSize.width
        let height = NotchMetrics.collapsedSize.height

        return mouse.x >= screenFrame.midX - width / 2
            && mouse.x <= screenFrame.midX + width / 2
            && mouse.y >= screenFrame.maxY - height
            && mouse.y <= screenFrame.maxY
    }

    private func mouseIsInsideExpandedPanel(_ mouse: NSPoint, screenFrame: NSRect) -> Bool {

        // Match the actual expanded NSWindow frame, including its 24pt safety
        // margin. This prevents hover tracking from treating the search field
        // or its outer padding as being outside the notch.
        let width = NotchMetrics.expandedWindowSize.width
        let height = NotchMetrics.expandedWindowSize.height

        return mouse.x >= screenFrame.midX - width / 2
            && mouse.x <= screenFrame.midX + width / 2
            && mouse.y >= screenFrame.maxY - height
            && mouse.y <= screenFrame.maxY
    }

    // MARK: Collapsed Hover State

    private func updateCollapsedHoverState() {

        guard let screenFrame else { return }

        let mouse = NSEvent.mouseLocation

        let inside = mouseIsInsideCollapsedNotch(mouse, screenFrame: screenFrame)

        cursorWasInsideCollapsedNotch = inside
        hoverState = inside ? .waitingForExit : .armed
    }

    // MARK: Mouse Hover Monitoring

    private func startMouseMonitoring() {

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved,
            handler: { [weak self] _ in
                self?.handleMouseMoved()
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func handleMouseMoved() {

        guard !isFileDragging else { return }
        guard let screenFrame else { return }

        let mouse = NSEvent.mouseLocation

        if hoverState == .closing {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(mouse, screenFrame: screenFrame)

            cursorWasInsideCollapsedNotch = insideCollapsed

            if insideCollapsed {
                hoverState = .armed
                scheduleHoverOpen()
            }

            return
        }

        if hoverState == .waitingForExit {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(mouse, screenFrame: screenFrame)

            cursorWasInsideCollapsedNotch = insideCollapsed

            if !insideCollapsed {
                hoverState = .armed
            }

            return
        }

        if !visualExpanded {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(mouse, screenFrame: screenFrame)

            if !insideCollapsed {
                hoverOpenWork?.cancel()
                cursorWasInsideCollapsedNotch = false
                hoverState = .armed
                return
            }

            let entered = hoverState == .armed && !cursorWasInsideCollapsedNotch

            cursorWasInsideCollapsedNotch = true

            guard entered else { return }

            scheduleHoverOpen()

            return
        }

        let insideExpanded = mouseIsInsideExpandedPanel(mouse, screenFrame: screenFrame)

        if insideExpanded { return }

        guard !isExpanded else { return }

        endHoverExpansion()
    }

    // MARK: File Drop Zone

    func canAcceptFileDrop(atScreenLocation location: NSPoint) -> Bool {

        guard visualExpanded || isExpanded || isPinned || isFileDragging else {
            return false
        }

        guard let screenFrame else { return false }

        return mouseIsInsideExpandedPanel(location, screenFrame: screenFrame)
    }

    // MARK: Drag State

    func beginFileDragging() {
        setFileDragging(true)
    }

    func endFileDragging() {
        setFileDragging(false)
    }

    private func setFileDragging(_ value: Bool) {

        guard isFileDragging != value else { return }

        isFileDragging = value

        if value {

            contractionGeneration += 1
            contractionWorkItem?.cancel()
            contractionWorkItem = nil

            cursorWasInsideCollapsedNotch = false
            hoverState = .expanded
        }

        refreshWindow()

        if value {

            startWatchdog()

        } else {

            stopWatchdog()

            if !visualExpanded && !isExpanded && !isPinned {
                updateCollapsedHoverState()
            }
        }
    }

    // FIX: The mouse-up monitor (and the watchdog) used to tear the drag state
    // down immediately, which happened BEFORE AppKit called performDragOperation.
    // By then canAcceptFileDrop() saw all flags false and rejected the drop.
    // Teardown is now delayed so the drop callback runs first. If the drop is
    // accepted, receiveDroppedFiles() sets visualExpanded, so the notch stays open.
    private func finishDragSession() {

        // Already scheduled: don't reschedule (the watchdog calls this repeatedly).
        guard !dragEndPending else { return }

        dragEndPending = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in

            guard let self else { return }

            self.dragEndPending = false

            // A new drag started in the meantime; leave state alone.
            if NSEvent.pressedMouseButtons & 1 != 0 { return }

            self.dragSessionActive = false
            self.stopDragPoll()
            self.setFileDragging(false)
        }
    }

    // MARK: Global Drag Detection

    private func startDragMonitoring() {

        lastDragChangeCount = NSPasteboard(name: .drag).changeCount

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDragged,
            handler: { [weak self] _ in
                self?.handleMouseDragged()
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDragged,
            handler: { [weak self] event in
                self?.handleMouseDragged()
                return event
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp,
            handler: { [weak self] _ in
                self?.finishDragSession()
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp,
            handler: { [weak self] event in
                self?.finishDragSession()
                return event
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func isCursorInTopCenterZone(_ size: CGSize) -> Bool {

        guard let screenFrame else { return false }

        let mouse = NSEvent.mouseLocation

        return abs(mouse.x - screenFrame.midX) <= size.width / 2
            && mouse.y >= screenFrame.maxY - size.height
            && mouse.y <= screenFrame.maxY
    }

    private func handleMouseDragged() {

        let pasteboard = NSPasteboard(name: .drag)

        if pasteboard.changeCount != lastDragChangeCount {

            lastDragChangeCount = pasteboard.changeCount

            dragSessionActive = pasteboard.canReadObject(
                forClasses: [NSURL.self, NSString.self],
                options: nil
            )

            if dragSessionActive {
                startDragPoll()
            }
        }

        updateDragActivation()
    }

    // MARK: Key-Gated Drag Hitbox

    private func isActivationKeyHeld() -> Bool {
        // Reads live hardware modifier state; needs no Accessibility permission.
        CGEventSource.flagsState(.combinedSessionState).contains(NotchMetrics.dragActivationKey)
    }

    /// Decides whether the drag hitbox (the big window) should be rendered.
    /// - Arms only when the cursor is in the zone AND the activation key is held.
    /// - Once armed it stays armed (so you can release the key to drop) until the
    ///   cursor leaves the zone or the drag ends.
    private func updateDragActivation() {

        guard dragSessionActive else { return }

        // Mouse released: finishDragSession() owns teardown; don't re-arm.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }

        let inside = isCursorInTopCenterZone(NotchMetrics.dragHitboxSize)

        if inside && (isFileDragging || isActivationKeyHeld()) {
            setFileDragging(true)
        } else {
            setFileDragging(false)
        }
    }

    private func startDragPoll() {

        guard dragPollTimer == nil else { return }

        // Pressing the key while the mouse is held still sends no drag events,
        // so poll briefly instead of relying on mouse movement.
        dragPollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            self?.updateDragActivation()
        }
    }

    private func stopDragPoll() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
    }

    // MARK: Watchdog

    private func startWatchdog() {

        stopWatchdog()

        dragWatchdog = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in

            if NSEvent.pressedMouseButtons & 1 == 0 {
                self?.finishDragSession()
            }
        }
    }

    private func stopWatchdog() {
        dragWatchdog?.invalidate()
        dragWatchdog = nil
    }

    // MARK: Drop / Clear

    enum DroppedContent {
        case text(String)
        case url(URL)
    }

    func receiveDroppedContent(_ content: DroppedContent) {
        contractionGeneration += 1
        contractionWorkItem?.cancel()
        contractionWorkItem = nil
        cursorWasInsideCollapsedNotch = false
        hoverState = .expanded
        setVisualExpansion(true)
        NotificationCenter.default.post(name: .notchDropContentReceived, object: content)
    }

    func receiveDroppedFiles(_ urls: [URL]) {

        // A successful drop must leave the notch expanded.
        contractionGeneration += 1
        contractionWorkItem?.cancel()
        contractionWorkItem = nil

        cursorWasInsideCollapsedNotch = false
        hoverState = .expanded

        setVisualExpansion(true)

        NotificationCenter.default.post(
            name: .notchDropFileReceived,
            object: urls
        )
    }

    func clearFiles() {
        clearTrigger.toggle()
    }
}

extension MediaController {
    static func setVolume(_ value: Double) {
        let percent = Int(max(0, min(100, value * 100)))
        let scripts = [
            "tell application \"Music\" to set sound volume to \(percent)",
            "tell application \"Spotify\" to set sound volume to \(percent)"
        ]
        for script in scripts { NSAppleScript(source: script)?.executeAndReturnError(nil) }
    }
}

// MARK: - Notch View Model

final class NotchViewModel: ObservableObject {

    @Published var isPinned = false
    @Published var selectedTab: NotchTab = NotchSettings.shared.startTab()
    @Published var isTopTargeted = false
    @Published var isShelfTargeted = false
    @Published var isPlaying = false
    @Published var currentSong = "Not Playing"
    @Published var currentArtist = "No Active Media"
    @Published var coverArt: NSImage?

    // Colour pulled from the cover art; nil when there is none.
    @Published var tint: Color?

    // The shelf. Newest first. Files stay where they are; only references are kept.
    @Published var storedFiles: [URL] = [] {
        didSet { persistShelf() }
    }
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published var folderShortcuts: [URL] = [] { didSet { UserDefaults.standard.set(folderShortcuts.map(\.path), forKey: "notchdrop.folderShortcuts") } }

    // Playback position (seconds), sampled at `positionSampledAt` and extrapolated between polls.
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var scrubPosition: Double?
    @Published var musicVolume: Double = 0.5
    @Published private(set) var recentlyPlayed: [String] = []

    private var positionSampledAt = Date()
    private var seekHoldUntil = Date.distantPast
    private var tintKey = ""

    private var mediaTimer: Timer?
    private var dropObserver: NSObjectProtocol?

    init() {

        dropObserver = NotificationCenter.default.addObserver(
            forName: .notchDropFileReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in

            guard let urls = notification.object as? [URL] else { return }

            self?.addFiles(urls)
        }

        if NotchSettings.shared.rememberFiles {
            restoreShelf()
        }
        let savedFolders = UserDefaults.standard.stringArray(forKey: "notchdrop.folderShortcuts") ?? []
        if savedFolders.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            folderShortcuts = ["Downloads", "Desktop", "Documents", "Applications"].map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        } else {
            folderShortcuts = savedFolders.map { URL(fileURLWithPath: $0) }.filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.path) }
        }

        startMediaMonitoring()
    }

    deinit {

        mediaTimer?.invalidate()

        if let dropObserver {
            NotificationCenter.default.removeObserver(dropObserver)
        }
    }

    // MARK: Media

    func startMediaMonitoring() {

        refreshMediaInfo()

        mediaTimer = Timer.scheduledTimer(
            withTimeInterval: 1.5,
            repeats: true
        ) { [weak self] _ in
            self?.refreshMediaInfo()
        }
    }

    func refreshMediaInfo() {

        MediaController.fetchCurrentTrack { [weak self] song, artist, playing, art, position, duration in

            guard let self else { return }

            // Only publish what actually changed, so a steady poll doesn't redraw the notch.
            if self.currentSong != song { self.currentSong = song }
            if self.currentArtist != artist { self.currentArtist = artist }
            if !song.isEmpty && song != "Not Playing" {
                let entry = artist.isEmpty || artist == "No Active Media" ? song : "\(song) · \(artist)"
                self.recentlyPlayed.removeAll { $0 == entry }
                self.recentlyPlayed.insert(entry, at: 0)
                self.recentlyPlayed = Array(self.recentlyPlayed.prefix(8))
            }
            if self.isPlaying != playing { self.isPlaying = playing }
            if self.coverArt !== art { self.coverArt = art }
            if self.duration != duration { self.duration = duration }

            let key = "\(song)|\(artist)"

            if key != self.tintKey || (self.tint == nil && art != nil) {
                self.tintKey = key
                self.tint = art?.notchTint()
            }

            // Don't let a poll that started before a seek (or a scrub in progress) undo it.
            if self.scrubPosition == nil && Date() >= self.seekHoldUntil {
                self.position = position
                self.positionSampledAt = Date()
            }
        }
    }

    /// Where the playhead should be drawn at `now`.
    func displayPosition(at now: Date) -> Double {

        if let scrubPosition {
            return scrubPosition
        }

        guard isPlaying else {
            return duration > 0 ? min(position, duration) : position
        }

        let live = position + now.timeIntervalSince(positionSampledAt)

        return duration > 0 ? min(live, duration) : live
    }

    func finishScrub(to seconds: Double) {

        let target = min(max(seconds, 0), duration)

        scrubPosition = nil
        position = target
        positionSampledAt = Date()
        seekHoldUntil = Date().addingTimeInterval(1.2)

        MediaController.seek(to: target)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshMediaInfo()
        }
    }

    func togglePlayback() {
        MediaController.togglePlayPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshMediaInfo()
        }
    }

    func nextTrack() {
        MediaController.nextTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshMediaInfo()
        }
    }

    func previousTrack() {
        MediaController.previousTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshMediaInfo()
        }
    }

    func setMusicVolume(_ value: Double) {
        musicVolume = value
        MediaController.setVolume(value)
    }

    // MARK: Shelf

    private static let shelfKey = "notchdrop.shelf"

    private func persistShelf() {

        let defaults = UserDefaults.standard

        if NotchSettings.shared.rememberFiles {
            defaults.set(storedFiles.map { $0.path }, forKey: Self.shelfKey)
        } else {
            defaults.removeObject(forKey: Self.shelfKey)
        }
    }

    private func restoreShelf() {

        let paths = UserDefaults.standard.stringArray(forKey: Self.shelfKey) ?? []

        let urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        storedFiles = urls

        for url in urls {
            loadThumbnail(for: url)
        }
    }

    /// Called when "remember files" is switched on or off in Settings.
    func rememberSettingChanged() {
        persistShelf()
    }

    /// Adds dropped files (newest first, no duplicates).
    func addFiles(_ urls: [URL]) {

        var fresh: [URL] = []

        for raw in urls {

            let url = raw.standardizedFileURL

            if storedFiles.contains(url) || fresh.contains(url) { continue }

            fresh.append(url)
        }

        guard !fresh.isEmpty else { return }

        storedFiles.insert(contentsOf: fresh, at: 0)

        for url in fresh {
            loadThumbnail(for: url)
        }
    }

    func removeFile(_ url: URL) {
        storedFiles.removeAll { $0 == url }
        thumbnails[url] = nil
    }

    func clearFiles() {
        storedFiles.removeAll()
        thumbnails.removeAll()
    }

    func addFolderShortcut(_ url: URL) {
        let value = url.standardizedFileURL
        guard value.hasDirectoryPath, !folderShortcuts.contains(value) else { return }
        folderShortcuts.insert(value, at: 0)
    }

    func removeFolderShortcut(_ url: URL) { folderShortcuts.removeAll { $0 == url } }

    /// Drops references to files that were moved or deleted since they were added.
    func pruneMissingFiles() {

        let missing = storedFiles.filter { !FileManager.default.fileExists(atPath: $0.path) }

        for url in missing {
            removeFile(url)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    func rename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename \(url.lastPathComponent)"
        let field = NSTextField(string: url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let finalName = url.pathExtension.isEmpty ? name : name + "." + url.pathExtension
        let destination = url.deletingLastPathComponent().appendingPathComponent(finalName)
        try? FileManager.default.moveItem(at: url, to: destination)
        if let index = storedFiles.firstIndex(of: url) { storedFiles[index] = destination; loadThumbnail(for: destination) }
    }

    func moveToTrash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        removeFile(url)
    }

    func share(_ url: URL) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
    }

    private func loadThumbnail(for url: URL) {

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in

            guard let image = representation?.nsImage else { return }

            DispatchQueue.main.async {

                guard let self, self.storedFiles.contains(url) else { return }

                self.thumbnails[url] = image
            }
        }
    }
}

// MARK: - Tabs

enum NotchTab: String, CaseIterable, Identifiable {

    case music
    case files
    case calendar
    case alarms
    case clipboard
    case notes
    case apps
    case quickActions
    case downloads
    case audio
    case timer
    case system

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .music: return "music.note"
        case .files: return "tray.fill"
        case .calendar: return "calendar"
        case .alarms: return "alarm.fill"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        case .apps: return "square.grid.2x2"
        case .quickActions: return "bolt.fill"
        case .downloads: return "arrow.down.circle"
        case .audio: return "speaker.wave.2.fill"
        case .timer: return "timer"
        case .system: return "chart.bar.fill"
        }
    }

    var title: String {
        switch self {
        case .music: return "Music"
        case .files: return "Files"
        case .calendar: return "Calendar"
        case .alarms: return "Alarms"
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        case .apps: return "Apps"
        case .quickActions: return "Quick Actions"
        case .downloads: return "Downloads"
        case .audio: return "Audio"
        case .timer: return "Timer"
        case .system: return "System"
        }
    }
}

// MARK: - Calendar Model

struct CalendarEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

final class CalendarViewModel: ObservableObject {

    @Published var isCreatingQuickEvent = false
    @Published var quickEventTitle = ""

    enum Access {
        case notDetermined
        case denied
        case granted
    }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var events: [CalendarEntry] = []

    // Remembers that the user accepted calendar access. macOS owns the real permission;
    // this flag lets the app skip the explainer and re-request automatically if macOS
    // has reset the grant (e.g. after an ad-hoc-signed rebuild).
    private static let acceptedKey = "calendarAccessAccepted"

    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    init() {

        access = Self.currentAccess()

        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()

        // Previously accepted but macOS forgot (grant reset): quietly ask again.
        if access == .notDetermined,
           UserDefaults.standard.bool(forKey: Self.acceptedKey) {

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.access == .notDetermined else { return }
                self.requestAccess()
            }
        }
    }

    deinit {

        refreshTimer?.invalidate()

        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    private static func currentAccess() -> Access {

        let status = EKEventStore.authorizationStatus(for: .event)

        switch status {

        case .notDetermined:
            return .notDetermined

        case .denied, .restricted:
            return .denied

        default:
            if #available(macOS 14.0, *) {
                // .writeOnly can't read events, so treat it as denied.
                return status == .fullAccess ? .granted : .denied
            }
            return .granted
        }
    }

    /// Shows the system permission prompt. The text comes from Info.plist
    /// (NSCalendarsFullAccessUsageDescription / NSCalendarsUsageDescription).
    func requestAccess() {

        // Accessory apps must be active for the system prompt to appear in front.
        NSApp.activate(ignoringOtherApps: true)

        let handler: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    func openSystemSettings() {

        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func createQuickEvent(title: String) {
        guard access == .granted, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let event = EKEvent(eventStore: store)
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = Date().addingTimeInterval(300)
        event.endDate = event.startDate.addingTimeInterval(1800)
        event.calendar = store.defaultCalendarForNewEvents
        try? store.save(event, span: .thisEvent)
        refresh()
    }

    func refresh() {

        access = Self.currentAccess()

        // Save the user's choice permanently.
        if access == .granted {
            UserDefaults.standard.set(true, forKey: Self.acceptedKey)
        } else if access == .denied {
            UserDefaults.standard.set(false, forKey: Self.acceptedKey)
        }

        guard access == .granted else {
            events = []
            return
        }

        let store = self.store
        let days = NotchSettings.shared.calendarDays
        let includeAllDay = NotchSettings.shared.showAllDay

        DispatchQueue.global(qos: .utility).async { [weak self] in

            let calendar = Calendar.current
            let now = Date()
            let start = calendar.startOfDay(for: now)

            guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

            let entries: [CalendarEntry] = store.events(matching: predicate)
                .filter { (includeAllDay || !$0.isAllDay) && ($0.isAllDay || $0.endDate > now) }
                .sorted { $0.startDate < $1.startDate }
                .prefix(30)
                .map { event in
                    CalendarEntry(
                        id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                        title: event.title ?? "Untitled",
                        start: event.startDate,
                        end: event.endDate,
                        isAllDay: event.isAllDay,
                        color: Color(nsColor: event.calendar?.color ?? NSColor.systemBlue)
                    )
                }

            DispatchQueue.main.async {
                self?.events = entries
            }
        }
    }
}


final class NotchContainerUIState: ObservableObject {
    @Published var showingGlobalSearch = false
    @Published var filesMode = 0
}

final class GlobalSearchState: ObservableObject {
    @Published var query = ""
    @Published var isClosing = false
}

final class QuickActionsState: ObservableObject {
    @Published var pending: QuickAction?
}

// MARK: - Calendar Tab View

struct CalendarTabView: View {

    @ObservedObject var model: CalendarViewModel

    var accent: Color = Color.blue

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {

        content
            .frame(maxWidth: .infinity)
            .frame(height: NotchMetrics.tabContentHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .onAppear {
                model.refresh()
            }
            .sheet(isPresented: $model.isCreatingQuickEvent) {
                VStack(spacing: 12) {
                    Text("New Event").font(.headline)
                    TextField("Event title", text: $model.quickEventTitle)
                    HStack {
                        Button("Cancel") { model.isCreatingQuickEvent = false }
                        Button("Create") {
                            model.createQuickEvent(title: model.quickEventTitle)
                            model.quickEventTitle = ""
                            model.isCreatingQuickEvent = false
                        }.keyboardShortcut(.return)
                    }
                }.padding(20).frame(width: 300)
            }
            
    }

    @ViewBuilder
    private var content: some View {

        switch model.access {
        case .notDetermined:
            permissionPrompt
        case .denied:
            deniedView
        case .granted:
            eventList
        }
    }

    // MARK: Permission states

    private var permissionPrompt: some View {

        VStack(spacing: 6) {

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundColor(accent)

            Text("See your upcoming events here. NotchDrop only reads them.")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: { model.requestAccess() }) {
                Text("Allow Calendar Access")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private var deniedView: some View {

        VStack(spacing: 6) {

            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 18))
                .foregroundColor(.orange)

            Text("Calendar access is off. Turn it on in System Settings to see your events.")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: { model.openSystemSettings() }) {
                Text("Open Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Event list

    private var eventList: some View {

        VStack(alignment: .leading, spacing: 4) {

            HStack {

                Text("Upcoming")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button { model.isCreatingQuickEvent = true } label: { Image(systemName: "plus") }.buttonStyle(.plain)

                Text(Self.dayFormatter.string(from: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            if model.events.isEmpty {

                VStack(spacing: 4) {

                    Spacer(minLength: 0)

                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.green)

                    Text("Nothing coming up")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

            } else {

                ScrollView(.vertical, showsIndicators: false) {

                    VStack(spacing: 3) {

                        ForEach(model.events) { event in
                            row(for: event)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(for event: CalendarEntry) -> some View {

        let now = Date()
        let isNow = !event.isAllDay && event.start <= now && event.end > now

        return HStack(spacing: 6) {

            Circle()
                .fill(event.color)
                .frame(width: 7, height: 7)

            Text(timeLabel(for: event, isNow: isNow))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(isNow ? .green : .gray)
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)

            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func timeLabel(for event: CalendarEntry, isNow: Bool) -> String {

        let calendar = Calendar.current

        if event.isAllDay {
            return calendar.isDateInToday(event.start) || event.start < Date()
                ? "All day"
                : "\(Self.weekdayFormatter.string(from: event.start)) all day"
        }

        if isNow {
            return "Now"
        }

        let time = Self.timeFormatter.string(from: event.start)

        if calendar.isDateInToday(event.start) {
            return time
        }

        return "\(Self.weekdayFormatter.string(from: event.start)) \(time)"
    }
}

// MARK: - Alarm Model
//
// macOS has no public alarm API (AlarmKit is iOS / iPadOS / Mac Catalyst only), so these
// are NotchDrop's own alarms. They are stored in UserDefaults, checked once a second while
// the app runs, and delivered with a looping sound, the notch popping open, and a
// notification. That is why the tab asks for notification access.

extension Notification.Name {
    static let notchDropAlarmRinging = Notification.Name("NotchDropAlarmRinging")
    static let notchDropTimerFinished = Notification.Name("NotchDropTimerFinished")
}

struct AlarmItem: Identifiable, Codable, Equatable {

    var id = UUID()
    var hour: Int
    var minute: Int
    var repeats: Bool
    var isEnabled = true
    var isSnooze = false
    var armedAt = Date()
    var lastTriggered: Date?

    /// Next time this alarm is due after the last time it fired (or was switched on).
    func nextOccurrence() -> Date? {

        Calendar.current.nextDate(
            after: lastTriggered ?? armedAt,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
    }
}

/// Lets notifications show as banners even while NotchDrop is the active app.
final class AlarmNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

final class AlarmViewModel: ObservableObject {

    enum Access {
        case notDetermined
        case denied
        case granted
    }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var alarms: [AlarmItem] = []
    @Published private(set) var ringing: AlarmItem?

    // Editor state lives in the view model so it remains testable and stable across view updates.
    @Published var isEditing = false
    @Published var draftHourText = "7"
    @Published var draftMinuteText = "00"
    @Published var draftIsPM = false
    @Published var isPeriodMenuOpen = false
    @Published var draftRepeats = false
    @Published var draftError: String?

    // Remembers that the user accepted. macOS owns the real permission; this flag lets the
    // app skip the explainer and quietly re-request if the grant was reset.
    private static let acceptedKey = "alarmAccessAccepted"
    private static let alarmsKey = "notchdrop.alarms"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private let notificationDelegate = AlarmNotificationDelegate()
    private var tickTimer: Timer?
    private var sound: NSSound?
    private var autoStopWork: DispatchWorkItem?
    private var didAutoRequest = false

    init() {

        UNUserNotificationCenter.current().delegate = notificationDelegate

        load()
        refreshAccess()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkAlarms()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: Formatting

    static func timeString(hour: Int, minute: Int) -> String {

        let date = Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()

        return timeFormatter.string(from: date)
    }

    var nextAlarmLabel: String? {

        let dates = alarms
            .filter { $0.isEnabled }
            .compactMap { $0.nextOccurrence() }

        guard let date = dates.min() else { return nil }

        let time = Self.timeFormatter.string(from: date)

        if Calendar.current.isDateInToday(date) {
            return time
        }

        return "\(Self.weekdayFormatter.string(from: date)) \(time)"
    }

    // MARK: Access

    func refreshAccess() {

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in

            DispatchQueue.main.async {

                guard let self else { return }

                switch settings.authorizationStatus {
                case .notDetermined:
                    self.access = .notDetermined
                case .denied:
                    self.access = .denied
                default:
                    self.access = .granted
                }

                // Save the user's choice permanently.
                if self.access == .granted {
                    UserDefaults.standard.set(true, forKey: Self.acceptedKey)
                } else if self.access == .denied {
                    UserDefaults.standard.set(false, forKey: Self.acceptedKey)
                }

                // Previously accepted but macOS forgot: quietly ask again (once per launch).
                if self.access == .notDetermined,
                   !self.didAutoRequest,
                   UserDefaults.standard.bool(forKey: Self.acceptedKey) {

                    self.didAutoRequest = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.access == .notDetermined else { return }
                        self.requestAccess()
                    }
                }
            }
        }
    }

    /// Shows the system notification prompt.
    func requestAccess() {

        // Accessory apps must be active for the system prompt to appear in front.
        NSApp.activate(ignoringOtherApps: true)

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAccess()
            }
        }
    }

    func openSystemSettings() {

        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Persistence

    private func load() {

        guard
            let data = UserDefaults.standard.data(forKey: Self.alarmsKey),
            let items = try? JSONDecoder().decode([AlarmItem].self, from: data)
        else { return }

        alarms = items
    }

    private func save() {

        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: Self.alarmsKey)
        }
    }

    // MARK: Editing

    func beginEditing() {

        // Start from the current time rounded up to the next 5 minutes.
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (now.hour ?? 7) * 60 + (now.minute ?? 0)
        let total = (((minutes / 5) + 1) * 5) % 1440

        let hour24 = total / 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12

        draftHourText = String(hour12)
        draftMinuteText = String(format: "%02d", total % 60)
        draftIsPM = hour24 >= 12
        draftRepeats = false
        draftError = nil
        isPeriodMenuOpen = false

        isEditing = true

        NotchWindowManager.shared.beginKeyboardInput()
    }

    func setHourText(_ text: String) {
        draftHourText = String(text.filter { $0.isASCII && $0.isNumber }.prefix(2))
        draftError = nil
        isPeriodMenuOpen = false
    }

    func setMinuteText(_ text: String) {
        draftMinuteText = String(text.filter { $0.isASCII && $0.isNumber }.prefix(2))
        draftError = nil
        isPeriodMenuOpen = false
    }

    /// Typed time -> 24-hour hour/minute. 1-12 uses the AM/PM menu; 0 or 13-23 is taken as 24-hour time.
    private func parseDraft() -> (hour: Int, minute: Int)? {

        guard let hour = Int(draftHourText) else { return nil }

        let typedMinute: Int? = draftMinuteText.isEmpty ? 0 : Int(draftMinuteText)

        guard let minute = typedMinute, (0...59).contains(minute) else { return nil }

        switch hour {
        case 1...12:
            let base = hour % 12
            return (draftIsPM ? base + 12 : base, minute)
        case 0, 13...23:
            return (hour, minute)
        default:
            return nil
        }
    }

    func cancelEditing() {

        guard isEditing else { return }

        isEditing = false
        draftError = nil
        isPeriodMenuOpen = false

        NotchWindowManager.shared.endKeyboardInput()
    }

    func saveDraft() {

        guard let time = parseDraft() else {
            draftError = "Enter a valid time, e.g. 7:30 PM"
            return
        }

        let item = AlarmItem(
            hour: time.hour,
            minute: time.minute,
            repeats: draftRepeats
        )

        alarms.append(item)
        alarms.sort { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }

        save()

        isEditing = false
        draftError = nil

        NotchWindowManager.shared.endKeyboardInput()
    }

    func toggle(_ alarm: AlarmItem) {

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }

        alarms[index].isEnabled.toggle()

        if alarms[index].isEnabled {
            alarms[index].armedAt = Date()
            alarms[index].lastTriggered = nil
        }

        save()
    }

    func delete(_ alarm: AlarmItem) {
        alarms.removeAll { $0.id == alarm.id }
        save()
    }

    // MARK: Firing

    private func checkAlarms() {

        guard access == .granted, ringing == nil else { return }

        let now = Date()
        var changed = false
        var snoozesToRemove: [UUID] = []

        for index in alarms.indices where alarms[index].isEnabled {

            let alarm = alarms[index]

            guard let due = alarm.nextOccurrence(), due <= now else { continue }

            alarms[index].lastTriggered = due
            changed = true

            if !alarm.repeats {
                if alarm.isSnooze {
                    snoozesToRemove.append(alarm.id)
                } else {
                    alarms[index].isEnabled = false
                }
            }

            // Only ring if it is reasonably fresh (e.g. not an alarm missed hours ago
            // while the Mac slept); older ones are skipped silently.
            if now.timeIntervalSince(due) < 15 * 60 {
                ring(alarms[index])
                break
            }
        }

        if !snoozesToRemove.isEmpty {
            alarms.removeAll { snoozesToRemove.contains($0.id) }
        }

        if changed {
            save()
        }
    }

    private func ring(_ alarm: AlarmItem) {

        ringing = alarm

        let alarmSound = NSSound(named: NSSound.Name(NotchSettings.shared.alarmSound))
        alarmSound?.loops = true
        alarmSound?.play()
        sound = alarmSound

        postNotification(for: alarm)

        // Pop the notch open on the Alarms tab and keep it open until dismissed.
        NotchWindowManager.shared.holdOpen()
        NotificationCenter.default.post(name: .notchDropAlarmRinging, object: nil)

        // Don't ring forever if nobody is around.
        autoStopWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.stopRinging()
        }

        autoStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(NotchSettings.shared.ringSeconds), execute: work)
    }

    private func postNotification(for alarm: AlarmItem) {

        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        content.body = Self.timeString(hour: alarm.hour, minute: alarm.minute)

        let request = UNNotificationRequest(
            identifier: alarm.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func stopRinging() {

        autoStopWork?.cancel()
        autoStopWork = nil

        sound?.stop()
        sound = nil

        if let ringing {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [ringing.id.uuidString])
        }

        ringing = nil

        NotchWindowManager.shared.releaseHold()
    }

    func snooze(minutes requested: Int? = nil) {

        guard ringing != nil else { return }

        let minutes = requested ?? NotchSettings.shared.snoozeMinutes

        stopRinging()

        // Land on a minute boundary so the snooze isn't shorter than asked.
        var target = Date().addingTimeInterval(Double(minutes) * 60)
        let seconds = Calendar.current.component(.second, from: target)

        if seconds != 0 {
            target = target.addingTimeInterval(Double(60 - seconds))
        }

        let parts = Calendar.current.dateComponents([.hour, .minute], from: target)

        var item = AlarmItem(
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            repeats: false
        )
        item.isSnooze = true

        alarms.append(item)
        save()
    }
}

// MARK: - Mini Switch

struct MiniSwitch: View {

    let isOn: Bool
    let action: () -> Void

    var body: some View {

        Button(action: action) {

            ZStack(alignment: isOn ? .trailing : .leading) {

                Capsule()
                    .fill(isOn ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 26, height: 14)

                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.15), value: isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alarm Tab View

struct AlarmTabView: View {

    @ObservedObject var model: AlarmViewModel

    var accent: Color = Color.blue

    // Each state of the Alarms tab is a "page". Moving between pages animates:
    // the editor slides in from the right, the list from the left,
    // a ringing alarm scales in, and the permission pages fade.
    private enum Page: Equatable {
        case permission
        case denied
        case list
        case editor
        case ringing
    }

    private var page: Page {

        if model.ringing != nil {
            return .ringing
        }

        switch model.access {
        case .notDetermined:
            return .permission
        case .denied:
            return .denied
        case .granted:
            return model.isEditing ? .editor : .list
        }
    }

    private var slideTrailing: AnyTransition {
        AnyTransition.move(edge: .trailing).combined(with: .opacity)
    }

    private var slideLeading: AnyTransition {
        AnyTransition.move(edge: .leading).combined(with: .opacity)
    }

    var body: some View {

        ZStack {

            switch page {
            case .ringing:
                ringingView
                    .transition(AnyTransition.scale(scale: 0.9).combined(with: .opacity))
            case .permission:
                permissionPrompt
                    .transition(.opacity)
            case .denied:
                deniedView
                    .transition(.opacity)
            case .editor:
                editor
                    .transition(slideTrailing)
            case .list:
                alarmList
                    .transition(slideLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchMetrics.tabContentHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: page)
        .onAppear {
            model.refreshAccess()
        }
    }

    // MARK: Permission states

    private var permissionPrompt: some View {

        VStack(spacing: 6) {

            Image(systemName: "alarm.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)

            Text("Set alarms here. NotchDrop needs notification access so it can alert you when one goes off.")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: { model.requestAccess() }) {
                Text("Allow Notifications")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private var deniedView: some View {

        VStack(spacing: 6) {

            Image(systemName: "bell.slash.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)

            Text("Notifications are off, so alarms can't alert you. Turn them on in System Settings.")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: { model.openSystemSettings() }) {
                Text("Open Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Ringing

    private var ringingView: some View {

        VStack(spacing: 8) {

            TimelineView(.periodic(from: Date(), by: 1.0 / 20.0)) { context in

                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
                    .rotationEffect(
                        .degrees(sin(context.date.timeIntervalSinceReferenceDate * 14) * 7)
                    )
            }

            if let alarm = model.ringing {
                Text(AlarmViewModel.timeString(hour: alarm.hour, minute: alarm.minute))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            HStack(spacing: 8) {

                Button(action: { model.snooze() }) {
                    Text("Snooze \(NotchSettings.shared.snoozeMinutes) min")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)

                Button(action: { model.stopRinging() }) {
                    Text("Stop")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: List

    private var alarmList: some View {

        VStack(alignment: .leading, spacing: 4) {

            HStack {

                Text("Alarms")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                if let next = model.nextAlarmLabel {
                    Text("Next \(next)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                Button(action: { model.beginEditing() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.15))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add alarm")
            }

            if model.alarms.isEmpty {

                VStack(spacing: 4) {

                    Spacer(minLength: 0)

                    Image(systemName: "alarm")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)

                    Text("No alarms yet. Tap + to add one.")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)

            } else {

                ScrollView(.vertical, showsIndicators: false) {

                    VStack(spacing: 3) {

                        ForEach(model.alarms) { alarm in
                            row(for: alarm)
                                .transition(AnyTransition.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.alarms)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.alarms.isEmpty)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(for alarm: AlarmItem) -> some View {

        HStack(spacing: 8) {

            Text(AlarmViewModel.timeString(hour: alarm.hour, minute: alarm.minute))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(alarm.isEnabled ? .white : .gray)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)

            Text(alarm.isSnooze ? "Snooze" : (alarm.repeats ? "Daily" : "Once"))
                .font(.system(size: 9))
                .foregroundColor(.gray)

            Spacer(minLength: 0)

            MiniSwitch(isOn: alarm.isEnabled) {
                model.toggle(alarm)
            }

            Button(action: { model.delete(alarm) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Editor (type the time; the panel accepts typing only while this is open)

    private var editor: some View {

        VStack(spacing: 6) {

            HStack(spacing: 6) {

                Spacer()

                timeField(
                    placeholder: "hh",
                    text: Binding(
                        get: { model.draftHourText },
                        set: { model.setHourText($0) }
                    )
                )

                Text(":")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                timeField(
                    placeholder: "mm",
                    text: Binding(
                        get: { model.draftMinuteText },
                        set: { model.setMinuteText($0) }
                    )
                )

                periodMenu

                Spacer()
            }
            .zIndex(1)

            if let error = model.draftError {

                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.red)
                    .transition(.opacity)

            } else {

                Text("Click a box and type the time")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {

                Button(action: { model.draftRepeats.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.draftRepeats ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                        Text("Repeat daily")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(model.draftRepeats ? .green : .gray)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { model.cancelEditing() }) {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)

                Button(action: { model.saveDraft() }) {
                    Text("Save")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeOut(duration: 0.18), value: model.draftError)
    }

    private func timeField(placeholder: String, text: Binding<String>) -> some View {

        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .frame(width: 44, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.14))
            )
            .onSubmit {
                model.saveDraft()
            }
    }

    private var periodMenu: some View {

        // A plain button + our own list, so the chevron sits exactly where we put it
        // (native macOS menus re-arrange their labels).
        Button(action: { model.isPeriodMenuOpen.toggle() }) {

            HStack(spacing: 6) {

                Text(model.draftIsPM ? "PM" : "AM")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Image(systemName: model.isPeriodMenuOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 62, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {

            if model.isPeriodMenuOpen {
                periodDropdown
                    .offset(y: 34)
                    .transition(AnyTransition.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isPeriodMenuOpen)
    }

    private var periodDropdown: some View {

        VStack(spacing: 0) {
            periodOption("AM", isPM: false)
            periodOption("PM", isPM: true)
        }
        .frame(width: 62)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(white: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
    }

    private func periodOption(_ title: String, isPM: Bool) -> some View {

        Button(action: {
            model.draftIsPM = isPM
            model.isPeriodMenuOpen = false
        }) {

            HStack {

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Spacer(minLength: 0)

                if model.draftIsPM == isPM {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Seek Bar

struct SeekBarView: View {

    @ObservedObject var viewModel: NotchViewModel

    /// Progress colour (cover-art tint), or nil for plain white.
    let tint: Color?

    /// False while the notch is collapsed, so the clock isn't ticking for nothing.
    let isActive: Bool
    let onScrubBegan: () -> Void
    let onScrubEnded: () -> Void

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: Date(), by: 0.5)) { context in
                bar(at: context.date)
            }
        } else {
            bar(at: Date())
        }
    }

    private func bar(at now: Date) -> some View {

        let duration = viewModel.duration
        let position = viewModel.displayPosition(at: now)
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        let isScrubbing = viewModel.scrubPosition != nil

        return HStack(spacing: 6) {

            Text(Self.format(position))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(isScrubbing ? .white : .gray)
                .frame(width: 36, alignment: .trailing)

            GeometryReader { geo in

                ZStack(alignment: .leading) {

                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: isScrubbing ? 6 : 4)

                    Capsule()
                        .fill(tint ?? Color.white)
                        .frame(width: geo.size.width * fraction, height: isScrubbing ? 6 : 4)

                    if isScrubbing {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: max(0, geo.size.width * fraction - 5))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard viewModel.duration > 0 else { return }
                            if viewModel.scrubPosition == nil {
                                onScrubBegan()
                            }
                            viewModel.scrubPosition = seconds(at: value.location.x, width: geo.size.width)
                        }
                        .onEnded { value in
                            guard viewModel.duration > 0 else { return }
                            viewModel.finishScrub(to: seconds(at: value.location.x, width: geo.size.width))
                            onScrubEnded()
                        }
                )
            }
            .frame(height: 12)

            Text(Self.format(duration))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(.gray)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {

        guard width > 0 else { return 0 }

        let fraction = min(max(Double(x / width), 0), 1)

        return fraction * viewModel.duration
    }

    private static func format(_ seconds: Double) -> String {

        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Small UI Pieces

/// Gentle press feedback for the small icon buttons.
struct PressButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Text that scrolls sideways when it doesn't fit, and just truncates otherwise.
/// Time-driven, so it needs no state of its own; it only ticks while `isActive`.
struct MarqueeText: View {

    let text: String
    let size: CGFloat
    let semibold: Bool
    let color: Color
    let isActive: Bool

    private let gap: CGFloat = 28
    private let speed: Double = 28
    private let pause: Double = 1.8

    private var textWidth: CGFloat {

        let font = NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
        let width = (text as NSString).size(withAttributes: [.font: font]).width

        return ceil(width)
    }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: semibold ? .semibold : .regular))
            .foregroundColor(color)
            .lineLimit(1)
    }

    var body: some View {

        GeometryReader { geo in

            if isActive && textWidth > geo.size.width + 1 {
                scrolling(width: geo.size.width)
            } else {
                label
                    .frame(width: geo.size.width, alignment: .leading)
            }
        }
        .frame(height: size + 4)
    }

    private func scrolling(width: CGFloat) -> some View {

        TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { context in

            HStack(spacing: gap) {
                label.fixedSize()
                label.fixedSize()
            }
            .offset(x: offset(at: context.date))
            .frame(width: width, alignment: .leading)
            .clipped()
        }
    }

    private func offset(at date: Date) -> CGFloat {

        let travel = Double(textWidth + gap)
        let cycle = travel / speed + pause

        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)

        if t < pause { return 0 }

        return -CGFloat((t - pause) * speed)
    }
}

/// Four little bars that dance while music plays. Used beside the closed notch.
struct NotchBars: View {

    let color: Color

    /// When false the bars sit still and nothing is scheduled.
    var isAnimating: Bool = true

    private let barCount = 4

    var body: some View {

        Group {

            if isAnimating {

                TimelineView(.periodic(from: Date(), by: 0.12)) { context in
                    bars(at: context.date.timeIntervalSinceReferenceDate)
                }

            } else {

                bars(at: 0)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func bars(at time: Double) -> some View {

        HStack(alignment: .center, spacing: 2) {

            ForEach(0..<barCount, id: \.self) { index in

                Capsule()
                    .fill(color)
                    .frame(width: 2, height: height(for: index, at: time))
            }
        }
        .animation(.easeInOut(duration: 0.12), value: time)
    }

    private func height(for index: Int, at time: Double) -> CGFloat {

        let phase = Double(index) * 1.7
        let wave = (sin(time * 7.0 + phase) + sin(time * 3.3 + phase * 2.1)) / 2

        return 4 + CGFloat((wave + 1) / 2) * 10
    }
}

/// Hover tracking for a single shelf tile (kept in a class so no @State is needed).
final class TileHoverModel: ObservableObject {
    @Published var isOver = false
}

/// One file on the shelf: preview, name, hover-to-remove, drag out, double-click to open.
struct FileTileView: View {

    let url: URL

    @ObservedObject var viewModel: NotchViewModel

    @StateObject private var hover = TileHoverModel()

    private var icon: NSImage {
        viewModel.thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {

        VStack(spacing: 3) {

            ZStack(alignment: .topTrailing) {

                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if hover.isOver {

                    Button(action: { viewModel.removeFile(url) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -5)
                    .transition(.opacity)
                }
            }
            .frame(width: 36, height: 32)

            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 54)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hover.isOver ? 0.1 : 0.0))
        )
        .animation(.easeOut(duration: 0.12), value: hover.isOver)
        .contentShape(Rectangle())
        .onHover { hovering in
            hover.isOver = hovering
        }
        .onDrag {
            NSItemProvider(object: url as NSURL)
        }
        .onTapGesture(count: 2) {
            viewModel.open(url)
        }
        .contextMenu {
            Button("Open") { viewModel.open(url) }
            Button("Show in Finder") { viewModel.reveal(url) }
            Button("Copy") { viewModel.copy(url) }
            Button("Copy Path") { viewModel.copyPath(url) }
            Button("Rename…") { viewModel.rename(url) }
            Button("Share") { viewModel.share(url) }
            Divider()
            Button("Move to Trash", role: .destructive) { viewModel.moveToTrash(url) }
            Button("Remove from NotchDrop") { viewModel.removeFile(url) }
        }
        .help(url.path)
    }
}

// MARK: - Notch Brand

enum NotchBrand {

    /// AppIcon.icns from the app bundle (add the file to the target's
    /// "Copy Bundle Resources"), falling back to the system app icon.
    static let icon: NSImage? = {

        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSApp.applicationIconImage
    }()
}

// MARK: - Notch Container View

struct NotchContainerView: View {

    @ObservedObject private var windowManager = NotchWindowManager.shared

    @ObservedObject private var settings = NotchSettings.shared

    @StateObject private var viewModel = NotchViewModel()

    @StateObject private var calendarModel = CalendarViewModel()

    @StateObject private var alarmModel = AlarmViewModel()
    @StateObject private var timerModel = TimerViewModel()
    @StateObject private var downloadsModel = DownloadsViewModel()
    @StateObject private var audioModel = AudioDeviceManager()
    @StateObject private var systemModel = SystemStatusViewModel()
    @StateObject private var uiState = NotchContainerUIState()
    @StateObject private var recentFilesModel = RecentFilesViewModel()
    @StateObject private var clipboardModel = ClipboardViewModel.shared

    private var accent: Color {
        settings.accent.color
    }

    /// Cover-art colour, or nil when the user turned tinting off.
    private var tint: Color? {
        settings.tintWithArt ? viewModel.tint : nil
    }

    private var isExpandedState: Bool {
        windowManager.isExpanded ||
        viewModel.isPinned ||
        windowManager.visualExpanded ||
        windowManager.isFileDragging
    }

    private var visualWidth: CGFloat {
        isExpandedState
            ? NotchMetrics.expandedSize.width
            : NotchMetrics.collapsedSize.width
    }

    private var visualHeight: CGFloat {
        isExpandedState
            ? NotchMetrics.expandedSize.height
            : NotchMetrics.collapsedSize.height
    }

    private var shapeTopRadius: CGFloat {
        isExpandedState ? NotchMetrics.expandedTopRadius : NotchMetrics.collapsedTopRadius
    }

    private var shapeBottomRadius: CGFloat {
        isExpandedState ? NotchMetrics.expandedRadius : NotchMetrics.collapsedRadius
    }

    private var morphAnimation: Animation {
        isExpandedState ? NotchMetrics.openSpring : NotchMetrics.closeSpring
    }

    private var artistColor: Color {
        viewModel.isPlaying ? (tint ?? Color.gray) : Color.gray
    }

    private var marqueeActive: Bool {
        isExpandedState && settings.scrollingText
    }

    // MARK: Closed notch: live activity
    // The closed notch is the same width whether anything is going on or not.
    // The playing look and the idle look are both always in the view and just
    // crossfade, so nothing jumps when music starts, pauses or stops.

    /// Whether the closed notch is wider than the hardware notch at all.
    private var wideClosedNotch: Bool {
        true
    }

    private var showMusicActivity: Bool {
        settings.liveMusic && viewModel.isPlaying
    }

    private var showPausedMusicActivity: Bool {
        settings.liveMusic && !viewModel.isPlaying && !viewModel.currentSong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showFilesActivity: Bool {
        settings.liveFiles && !viewModel.storedFiles.isEmpty
    }

    /// Anything at all to show beside the closed notch.
    private var showAlarmActivity: Bool { alarmModel.ringing != nil }
    private var showTimerActivity: Bool { timerModel.isRunning && timerModel.mode == .timer }
    private var showDownloadActivity: Bool { settings.showActiveDownloadsLive && !downloadsModel.active.isEmpty }
    private var nextCalendarEvent: CalendarEntry? {
        guard let event = calendarModel.events.first, !event.isAllDay else { return nil }
        return event
    }
    private var showCalendarActivity: Bool {
        guard let event = nextCalendarEvent else { return false }
        return event.start > Date() && event.start.timeIntervalSinceNow <= 1800
    }
    private var showBatteryActivity: Bool { systemModel.status.charging }
    private var hasActivity: Bool {
        showAlarmActivity || showTimerActivity || showDownloadActivity || showMusicActivity || showCalendarActivity || showBatteryActivity || showFilesActivity
    }
    private var calendarActivityText: String {
        guard let event = nextCalendarEvent else { return "Calendar" }
        let minutes = max(1, Int(event.start.timeIntervalSinceNow / 60))
        return minutes < 60 ? "\(event.title) · \(minutes)m" : event.title
    }

    @ViewBuilder
    private var playingLeftWing: some View {

        Group {
            if let art = viewModel.coverArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                brandIcon
            }
        }
        .frame(width: NotchMetrics.liveWingWidth, height: NotchMetrics.collapsedSize.height)
    }

    @ViewBuilder
    private var playingRightWing: some View {

        NotchBars(
            color: tint ?? Color.white,
            isAnimating: showMusicActivity && !isExpandedState
        )
        .frame(width: 18, height: 18)
    }

    private var playingLook: some View {

        HStack(spacing: 0) {

            playingLeftWing

            Spacer(minLength: 0)

            playingRightWing
                .frame(width: NotchMetrics.liveWingWidth, height: NotchMetrics.collapsedSize.height)
        }
    }

    @ViewBuilder
    private var brandIcon: some View {

        Group {
            if let icon = NotchBrand.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// The minimised notch when nothing else is going on:
    /// icon on the left, "Notch / Drop" on the right. Nothing else.
    private var brandLook: some View {

        HStack(spacing: 0) {

            brandIcon
                .frame(width: NotchMetrics.liveWingWidth, height: NotchMetrics.collapsedSize.height)

            Spacer(minLength: 0)

            Text("Notch\nDrop")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .frame(width: NotchMetrics.liveWingWidth)
        }
    }

    private var liveActivityView: some View {

        ZStack {
            playingLook
                .opacity(!showAlarmActivity && !showTimerActivity && !showDownloadActivity && showMusicActivity ? 1.0 : 0.0)

            brandLook
                .opacity(!showAlarmActivity && !showTimerActivity && !showDownloadActivity && !showMusicActivity && !showCalendarActivity && !showBatteryActivity ? 1.0 : 0.0)

            if showAlarmActivity {
                HStack(spacing: 4) { Image(systemName: "alarm.fill"); Text("Alarm").font(.system(size: 9, weight: .semibold)) }.foregroundColor(.white)
            } else if showTimerActivity {
                TimerActivityView(model: timerModel)
            } else if showDownloadActivity {
                HStack(spacing: 4) { Image(systemName: "arrow.down.circle.fill"); Text("Downloading").font(.system(size: 9, weight: .semibold)) }.foregroundColor(.white)
            } else if showMusicActivity {
                EmptyView()
            } else if showCalendarActivity {
                HStack(spacing: 4) { Image(systemName: "calendar"); Text(calendarActivityText).font(.system(size: 9, weight: .semibold)).lineLimit(1) }.foregroundColor(.white)
            } else if showBatteryActivity {
                HStack(spacing: 4) { Image(systemName: "bolt.fill"); Text("Charging").font(.system(size: 9, weight: .semibold)) }.foregroundColor(.white)
            }
        }
        .padding(.horizontal, NotchMetrics.collapsedTopRadius)
        .frame(
            width: NotchMetrics.collapsedSize.width,
            height: NotchMetrics.collapsedSize.height,
            alignment: .center
        )
        .animation(.easeInOut(duration: 0.35), value: showMusicActivity)
        .animation(.easeInOut(duration: 0.35), value: showFilesActivity)
        .animation(.easeInOut(duration: 0.25), value: showTimerActivity)
        .animation(.easeInOut(duration: 0.25), value: showDownloadActivity)
        .animation(.easeInOut(duration: 0.25), value: showCalendarActivity)
        .animation(.easeInOut(duration: 0.25), value: showBatteryActivity)
        .opacity(isExpandedState ? 0.0 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isExpandedState)
    }

    // MARK: Music tab

    private func artworkView(size: CGFloat) -> some View {

        Button(action: { MediaController.openSourceApp() }) {

            Group {

                if let coverArt = viewModel.coverArt {

                    Image(nsImage: coverArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)

                } else {

                    Image(systemName: viewModel.isPlaying ? "waveform" : "music.note")
                        .font(.system(size: size * 0.32, weight: .bold))
                        .foregroundColor(tint ?? accent)
                }
            }
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
            .scaleEffect(viewModel.isPlaying ? 1.0 : 0.92)
            .opacity(viewModel.isPlaying ? 1.0 : 0.7)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isPlaying)
        }
        .buttonStyle(.plain)
        .help("Open player")
    }

    private var transportControls: some View {

        HStack(spacing: 22) {

            Button(action: { viewModel.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())

            Button(action: { viewModel.togglePlayback() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
                    .contentShape(Circle())
            }
            .buttonStyle(PressButtonStyle())

            Button(action: { viewModel.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private var musicCardBackground: some View {

        ZStack {

            Color.clear
                .notchLiquidGlass(cornerRadius: 12)

            if viewModel.isPlaying, let tint = tint {

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.26), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.isPlaying)
    }

    private var musicTab: some View {

        let artSize = min(NotchMetrics.tabContentHeight - 28, 112)

        return HStack(spacing: 14) {

            artworkView(size: artSize)

            VStack(alignment: .leading, spacing: 2) {

                MarqueeText(
                    text: viewModel.currentSong,
                    size: 13,
                    semibold: true,
                    color: .white,
                    isActive: marqueeActive
                )

                MarqueeText(
                    text: viewModel.currentArtist,
                    size: 11,
                    semibold: false,
                    color: artistColor,
                    isActive: marqueeActive
                )

                // Controls sit exactly midway between the artist name and the seek bar.
                Spacer(minLength: 0)

                transportControls

                Spacer(minLength: 0)

                SeekBarView(
                    viewModel: viewModel,
                    tint: tint,
                    isActive: isExpandedState,
                    onScrubBegan: { windowManager.holdOpen() },
                    onScrubEnded: { windowManager.releaseHold() }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: NotchMetrics.tabContentHeight)
        .background(musicCardBackground)
        .contextMenu {
            if !viewModel.recentlyPlayed.isEmpty {
                Text("Recently Played")
                ForEach(viewModel.recentlyPlayed, id: \.self) { Text($0) }
            }
        }
    }

    // MARK: Files tab

    private var dropZoneBackground: some View {

        ZStack {

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    windowManager.isFileDragging
                        ? accent.opacity(0.18)
                        : Color.white.opacity(0.07)
                )

            if windowManager.isFileDragging {

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        accent.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: windowManager.isFileDragging)
    }

    private var emptyShelfHint: some View {

        VStack(spacing: 5) {

            Image(systemName: windowManager.isFileDragging ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundColor(accent)

            Text(
                windowManager.isFileDragging
                    ? "Drop to add"
                    : "Hold \(settings.dragKey.symbol) while dragging files here"
            )
            .font(.system(size: 10.5))
            .foregroundColor(.gray)
        }
    }

    private var shelfGrid: some View {

        VStack(spacing: 2) {

            HStack {

                Text(viewModel.storedFiles.count == 1 ? "1 file" : "\(viewModel.storedFiles.count) files")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        viewModel.clearFiles()
                    }
                }) {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressButtonStyle())
                .help("Clear all files")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 62), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(viewModel.storedFiles, id: \.self) { url in
                        FileTileView(url: url, viewModel: viewModel)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.storedFiles)
            }
        }
    }

    private var recentFilesGrid: some View {
        VStack(spacing: 6) {
            UtilitySearchField(text: $recentFilesModel.query, placeholder: "Search recent files")

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(recentFilesModel.filteredURLs, id: \.self) { url in
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                                Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.right.square").font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(5)
                            .notchLiquidGlass(cornerRadius: 7)
                        }
                        .buttonStyle(.plain)
                        .onDrag {
                            NSItemProvider(object: url as NSURL)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { viewModel.reveal(url) }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                            }
                        }
                    }
                }
                .padding(.horizontal, 7)
            }
        }
    }

    private var folderShortcutsGrid: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Folders").font(.system(size: 10, weight: .semibold))
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { viewModel.addFolderShortcut(url) }
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 5)], spacing: 5) {
                    ForEach(viewModel.folderShortcuts, id: \.self) { url in
                        Button { NSWorkspace.shared.open(url) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "folder.fill").foregroundColor(accent)
                                Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent).font(.system(size: 9)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).padding(7)
                            .notchLiquidGlass(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Reveal in Finder") { viewModel.reveal(url) }
                            Button("Remove Shortcut", role: .destructive) { viewModel.removeFolderShortcut(url) }
                        }
                    }
                }
            }
        }
        .padding(7)
    }

    private var filesTab: some View {
        VStack(spacing: 5) {
            Picker("Files", selection: $uiState.filesMode) { Text("Shelf").tag(0); Text("Recent").tag(1); Text("Folders").tag(2) }.pickerStyle(.segmented).padding(.horizontal, 8)
            Group {
                if uiState.filesMode == 0 { ZStack { dropZoneBackground; if viewModel.storedFiles.isEmpty { emptyShelfHint } else { shelfGrid } } }
                else if uiState.filesMode == 1 { recentFilesGrid }
                else { folderShortcutsGrid }
            }.frame(height: NotchMetrics.tabContentHeight - 30)
        }.frame(maxWidth: .infinity).frame(height: NotchMetrics.tabContentHeight).onAppear { recentFilesModel.refresh() }
    }

    // MARK: Header

    private func handleSelectedTabChange(_ tab: NotchTab) {

        if settings.lastTab != tab.rawValue {
            settings.lastTab = tab.rawValue
        }

        switch tab {
        case .music, .files, .clipboard, .notes, .apps, .quickActions, .audio:
            break
        case .calendar:
            calendarModel.refresh()
        case .alarms:
            alarmModel.refreshAccess()
        case .downloads:
            downloadsModel.refresh()
        case .timer:
            break
        case .system:
            systemModel.refresh()
        }

        if tab != .alarms {
            alarmModel.cancelEditing()
        }
    }

    /// If the tab on screen was just switched off in Settings, move to one that is still on.
    private func ensureValidTab() {

        let tabs = settings.enabledTabs

        if !tabs.contains(viewModel.selectedTab), let first = tabs.first {
            viewModel.selectedTab = first
        }
    }

    // Each side of the header gets the room left over beside the (real) notch,
    // so the buttons never sit behind it.
    private var headerWingWidth: CGFloat {

        let gap = NotchMetrics.hasHardwareNotch ? NotchMetrics.notchSize.width : 0

        return max(0, (NotchMetrics.expandedContentWidth - gap) / 2)
    }

    /// Tab buttons shrink a little if four of them don't fit beside the notch.
    private var tabButtonWidth: CGFloat {

        let count = max(1, settings.enabledTabs.count)

        let available = headerWingWidth - 8 - CGFloat(count - 1) * 2

        return max(16, min(24, available / CGFloat(count)))
    }

    private var notchHeader: some View {

        HStack(spacing: 0) {

            tabBar
                .frame(width: headerWingWidth, alignment: .leading)

            Spacer(minLength: 0)

            trailingButtons
                .frame(width: headerWingWidth, alignment: .trailing)
        }
        .frame(
            width: NotchMetrics.expandedContentWidth,
            height: NotchMetrics.headerHeight
        )
    }

    private var tabBar: some View {

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if settings.enabledTabs.count > 1 {
                    ForEach(settings.enabledTabs) { tab in
                        Button(action: { switchToTab(tab) }) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(viewModel.selectedTab == tab ? .white : .gray)
                                .frame(width: max(22, tabButtonWidth), height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(viewModel.selectedTab == tab ? 0.18 : 0.0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressButtonStyle())
                        .help(tab.title)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedTab)
    }

    private var trailingButtons: some View {

        HStack(spacing: 2) {

            Button(action: { uiState.showingGlobalSearch = true }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PressButtonStyle())
            .help("Search NotchDrop")

            Button(action: { SettingsWindowController.shared.show() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .help("Settings (⌘,)")

            Button(action: {
                viewModel.isPinned.toggle()
                windowManager.setPinned(viewModel.isPinned)
            }) {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(viewModel.isPinned ? .orange : .gray)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .help(viewModel.isPinned ? "Unpin Notch" : "Pin Notch Open")
        }
    }

    private func switchToTab(_ tab: NotchTab) {
        guard viewModel.selectedTab != tab else { return }

        withAnimation(.easeInOut(duration: 0.30)) {
            viewModel.selectedTab = tab
        }

        windowManager.debugState("tab clicked")
        windowManager.clearManualExpansion()
    }

    private var tabTransition: AnyTransition {
        AnyTransition.opacity.combined(with: .scale(scale: 0.97))
    }

    @ViewBuilder
    private var selectedTabContent: some View {

        switch viewModel.selectedTab {
        case .music:
            musicTab
                .transition(tabTransition)
        case .files:
            filesTab
                .transition(tabTransition)
        case .calendar:
            CalendarTabView(model: calendarModel, accent: accent)
                .transition(tabTransition)
        case .alarms:
            AlarmTabView(model: alarmModel, accent: accent)
                .transition(tabTransition)
        case .clipboard:
            ClipboardTabView(model: clipboardModel, accent: accent)
                .transition(tabTransition)
        case .notes:
            NotesTabView(accent: accent)
                .transition(tabTransition)
        case .apps:
            AppsTabView(accent: accent)
                .transition(tabTransition)
        case .quickActions:
            QuickActionsTabView(accent: accent)
                .transition(tabTransition)
        case .downloads:
            DownloadsTabView(model: downloadsModel, accent: accent)
                .transition(tabTransition)
        case .audio:
            AudioTabView(model: audioModel, accent: accent)
                .transition(tabTransition)
        case .timer:
            TimerTabView(model: timerModel, accent: accent)
                .transition(tabTransition)
        case .system:
            SystemTabView(model: systemModel, accent: accent)
                .transition(tabTransition)
        }
    }

    private var mainContent: some View {

        VStack(spacing: NotchMetrics.headerSpacing) {
            notchHeader

            ZStack {
                selectedTabContent
                    .id(viewModel.selectedTab.rawValue)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.30), value: viewModel.selectedTab)
        }
        .frame(width: NotchMetrics.expandedContentWidth, alignment: .top)
        .padding(.horizontal, NotchMetrics.expandedSidePadding)
        .padding(.bottom, NotchMetrics.bottomPadding)
        .offset(y: isExpandedState ? 0 : -10)
        .opacity(isExpandedState ? 1.0 : 0.0)
        .animation(morphAnimation, value: isExpandedState)
        .allowsHitTesting(isExpandedState)
    }

    var body: some View {

        ZStack(alignment: .top) {

            NotchShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius)
                .fill(Color.black)
                .shadow(
                    color: Color.black.opacity(isExpandedState ? 0.45 : 0.0),
                    radius: 9,
                    x: 0,
                    y: 3
                )
                .frame(width: visualWidth, alignment: .top)
                .frame(height: visualHeight, alignment: .top)
                .contentShape(NotchShape(topRadius: shapeTopRadius, bottomRadius: shapeBottomRadius))
                .onTapGesture {
                    windowManager.handleNotchTap()
                }
                .animation(morphAnimation, value: visualHeight)
                .animation(morphAnimation, value: visualWidth)

            if windowManager.liveWing > 0 {
                liveActivityView
                    .zIndex(5)
                    .allowsHitTesting(false)
            }

            mainContent

            if uiState.showingGlobalSearch {
                GlobalSearchView(
                    isPresented: $uiState.showingGlobalSearch,
                    fileURLs: viewModel.storedFiles,
                    events: calendarModel.events,
                    alarms: alarmModel.alarms,
                    recentFileURLs: recentFilesModel.filteredURLs,
                    accent: accent,
                    clipboard: clipboardModel,
                    windowManager: windowManager,
                    onSelectTab: { viewModel.selectedTab = $0 }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
                )
            }
        }
        .frame(
            width: NotchMetrics.dragHitboxSize.width,
            height: NotchMetrics.dragHitboxSize.height,
            alignment: .top
        )
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.24), value: uiState.showingGlobalSearch)
        .onAppear {
            windowManager.setPinned(viewModel.isPinned)
            windowManager.setLiveActivity(wideClosedNotch)

            if windowManager.isExpanded {
                windowManager.setVisualExpansion(true)
            }
        }
        .onChange(of: viewModel.isPinned) { newValue in
            windowManager.setPinned(newValue)
        }
        .onChange(of: wideClosedNotch) { wide in
            windowManager.setLiveActivity(wide)
        }
        .onChange(of: isExpandedState) { expanded in

            guard expanded else { return }

            viewModel.pruneMissingFiles()

            // Optionally always open to the same tab (not while a drag or an alarm is steering it).
            if settings.defaultTab != "last" && !windowManager.isFileDragging && alarmModel.ringing == nil {

                let tab = settings.startTab()

                if viewModel.selectedTab != tab {
                    viewModel.selectedTab = tab
                }
            }
        }
        .onChange(of: settings.tabOrder) { _ in
            ensureValidTab()
        }
        .onChange(of: settings.rememberFiles) { _ in
            viewModel.rememberSettingChanged()
        }
        .onChange(of: settings.calendarDays) { _ in
            calendarModel.refresh()
        }
        .onChange(of: settings.showAllDay) { _ in
            calendarModel.refresh()
        }
        .onChange(of: windowManager.clearTrigger) { _ in
            viewModel.clearFiles()
        }
        .onChange(of: windowManager.isFileDragging) { dragging in
            if dragging {
                viewModel.selectedTab = .files
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropFileReceived)) { _ in
            viewModel.selectedTab = .files
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropContentReceived)) { note in
            guard let content = note.object as? NotchWindowManager.DroppedContent else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            switch content {
            case .text(let value): pb.setString(value, forType: .string)
            case .url(let url): pb.writeObjects([url as NSURL]); pb.setString(url.absoluteString, forType: .URL)
            }
            viewModel.selectedTab = .clipboard
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropOpenRequested)) { _ in
            windowManager.togglePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropSelectTab)) { note in
            if let raw = note.object as? String, let tab = NotchTab(rawValue: raw), settings.isTabEnabled(tab) {
                viewModel.selectedTab = tab
                windowManager.setVisualExpansion(true)
            }
        }
        .onChange(of: viewModel.selectedTab) { tab in
            handleSelectedTabChange(tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropAlarmRinging)) { _ in
            viewModel.selectedTab = .alarms
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropTimerFinished)) { _ in
            viewModel.selectedTab = .timer
            windowManager.holdOpen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { windowManager.releaseHold() }
        }
    }
}

struct GlobalSearchView: View {
    @Binding var isPresented: Bool
    let fileURLs: [URL]
    let events: [CalendarEntry]
    let alarms: [AlarmItem]
    let recentFileURLs: [URL]
    let accent: Color
    let clipboard: ClipboardViewModel
    @ObservedObject var windowManager: NotchWindowManager
    let onSelectTab: (NotchTab) -> Void
    @StateObject private var state = GlobalSearchState()
    @StateObject private var apps = AppLauncherViewModel()
    @StateObject private var notes = NotesViewModel()
    @StateObject private var downloads = DownloadsViewModel()
    @StateObject private var audio = AudioDeviceManager()
    @StateObject private var timer = TimerViewModel()
    @StateObject private var system = SystemStatusViewModel()

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                UtilitySearchField(text: $state.query, placeholder: "Search NotchDrop", autoFocus: true)
                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    resultsSection("Apps", apps.filtered.filter { matches(state.query, $0.name) }.prefix(6)) { app in Button { apps.launch(app); isPresented = false } label: { searchRow("app.fill", app.name) }.buttonStyle(.plain) }
                    resultsSection("Files", fileURLs.filter { matches(state.query, $0.lastPathComponent) || matches(state.query, $0.path) }.prefix(6)) { url in Button { NSWorkspace.shared.open(url); isPresented = false } label: { searchRow("doc", url.lastPathComponent) }.buttonStyle(.plain) }
                    resultsSection("Recent Files", recentFileURLs.filter { matches(state.query, $0.lastPathComponent) || matches(state.query, $0.path) }.prefix(5)) { url in Button { NSWorkspace.shared.open(url); isPresented = false } label: { searchRow("clock.arrow.circlepath", url.lastPathComponent) }.buttonStyle(.plain) }
                    resultsSection("Clipboard", clipboard.filteredItems.filter { matches(state.query, $0.displayTitle) }.prefix(5)) { item in Button { clipboard.recopy(item); isPresented = false } label: { searchRow("doc.on.clipboard", item.displayTitle) }.buttonStyle(.plain) }
                    resultsSection("Notes", notes.filtered.filter { matches(state.query, $0.title) || matches(state.query, $0.body) }.prefix(5)) { note in Button { onSelectTab(.notes); isPresented = false } label: { searchRow("note.text", note.title) }.buttonStyle(.plain) }
                    resultsSection("Calendar", events.filter { matches(state.query, $0.title) }.prefix(5)) { event in Button { onSelectTab(.calendar); isPresented = false } label: { searchRow("calendar", event.title) }.buttonStyle(.plain) }
                    resultsSection("Alarms", alarms.filter { matches(state.query, String(format: "%02d:%02d", $0.hour, $0.minute)) }.prefix(8)) { alarm in Button { onSelectTab(.alarms); isPresented = false } label: { searchRow("alarm.fill", String(format: "%02d:%02d", alarm.hour, alarm.minute)) }.buttonStyle(.plain) }
                    resultsSection("Downloads", downloads.items.filter { matches(state.query, $0.url.lastPathComponent) }.prefix(5)) { item in Button { downloads.open(item); isPresented = false } label: { searchRow("arrow.down.circle", item.url.lastPathComponent) }.buttonStyle(.plain) }
                    resultsSection("Audio", audio.devices.filter { matches(state.query, $0.name) }.prefix(5)) { device in Button { audio.select(device.id); onSelectTab(.audio); isPresented = false } label: { searchRow("speaker.wave.2.fill", device.name) }.buttonStyle(.plain) }
                    resultsSection("Timer", timerSearchResults.filter { matches(state.query, $0) }.prefix(3)) { value in Button { onSelectTab(.timer); isPresented = false } label: { searchRow("timer", value) }.buttonStyle(.plain) }
                    resultsSection("System", systemSearchResults.filter { matches(state.query, $0) }.prefix(5)) { value in Button { onSelectTab(.system); isPresented = false } label: { searchRow("chart.bar.fill", value) }.buttonStyle(.plain) }
                    resultsSection("Quick Actions", QuickAction.allCases.filter { matches(state.query, $0.title) }.prefix(8)) { action in Button { onSelectTab(.quickActions); isPresented = false } label: { searchRow(action.icon, action.title) }.buttonStyle(.plain) }
                }
            }
        }
        .padding(10)
        .frame(width: NotchMetrics.expandedContentWidth, height: NotchMetrics.tabContentHeight + NotchMetrics.headerHeight + 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.98)))
        .scaleEffect(state.isClosing ? 0.965 : 1.0, anchor: .top)
        .offset(y: state.isClosing ? -5 : 0)
        .opacity(state.isClosing ? 0.0 : 1.0)
        .allowsHitTesting(!state.isClosing && windowManager.visualExpanded)
        .animation(.easeInOut(duration: 0.24), value: state.isClosing)
        .onAppear {
            state.isClosing = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if !state.isClosing, windowManager.visualExpanded {
                    // The panel is non-activating, so make it key before
                    // asking SwiftUI to focus the TextField.
                    if let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                        window.makeKey()
                    }
                }
            }
        }
        .onChange(of: windowManager.visualExpanded) { expanded in
            if !expanded {
                closeSearch()
            }
        }
        .onDisappear {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func closeSearch() {
        guard !state.isClosing else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            state.isClosing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            isPresented = false
        }
    }

    private var timerSearchResults: [String] { [timer.display, timer.mode.rawValue] + (timer.isRunning ? ["Running"] : ["Stopped"]) }
    private var systemSearchResults: [String] { [system.status.battery, system.status.wifi, system.status.bluetooth, system.status.charging ? "Charging" : "Battery"] }
    private func matches(_ query: String, _ value: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || value.localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder private func resultsSection<T, Content: View>(_ title: String, _ items: ArraySlice<T>, content: @escaping (T) -> Content) -> some View {
        if !items.isEmpty { VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundColor(accent); ForEach(Array(items.enumerated()), id: \.offset) { _, item in content(item) } } }
    }
    private func searchRow(_ icon: String, _ title: String) -> some View { HStack { Image(systemName: icon).frame(width: 20).foregroundColor(accent); Text(title).font(.system(size: 10)).lineLimit(1); Spacer() }.padding(5).notchLiquidGlass(cornerRadius: 7) }
}

// MARK: - Utility Features

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, url, file, image }
    let id: UUID
    let kind: Kind
    let value: String
    let createdAt: Date
    var isPinned: Bool

    var displayTitle: String {
        switch kind {
        case .file: return URL(fileURLWithPath: value).lastPathComponent
        case .image: return "Image"
        case .url: return value
        case .text: return value.replacingOccurrences(of: "\n", with: " ")
        }
    }
}

final class ClipboardViewModel: ObservableObject {
    static let shared = ClipboardViewModel()

    @Published private(set) var items: [ClipboardItem] = []
    @Published var query = ""
    @Published var image: NSImage?

    private var timer: Timer?
    private var lastChangeCount = -1
    private let key = "notchdrop.clipboard.history"

    var filteredItems: [ClipboardItem] {
        let source = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? items : items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
        return source.sorted { $0.isPinned != $1.isPinned ? $0.isPinned && !$1.isPinned : $0.createdAt > $1.createdAt }
    }

    private init() {
        restore()
        poll()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    private func poll() {
        guard NotchSettings.shared.clipboardEnabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            add(kind: .file, value: url.path)
            image = nil
            return
        }

        if let url = pb.string(forType: .URL), !url.isEmpty {
            add(kind: .url, value: url)
            image = nil
            return
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        if let imageType = imageTypes.first(where: { pb.data(forType: $0) != nil }),
           let data = pb.data(forType: imageType),
           let img = NSImage(data: data) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("NotchDrop/ClipboardImages", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).png")
            if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                add(kind: .image, value: file.path)
            }
            image = img
            return
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            add(kind: .text, value: text)
            image = nil
            return
        }
    }

    private func add(kind: ClipboardItem.Kind, value: String) {
        if let existing = items.first(where: { $0.kind == kind && $0.value == value }) {
            items.removeAll { $0.id == existing.id }
        }
        items.insert(ClipboardItem(id: UUID(), kind: kind, value: value, createdAt: Date(), isPinned: false), at: 0)
        trim()
        persist()
    }

    func recopy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text: pb.setString(item.value, forType: .string)
        case .url:
            pb.setString(item.value, forType: .URL)
            pb.setString(item.value, forType: .string)
        case .file: pb.writeObjects([URL(fileURLWithPath: item.value) as NSURL])
        case .image:
            if let img = NSImage(contentsOfFile: item.value) { pb.writeObjects([img]) }
        }
        lastChangeCount = pb.changeCount
    }

    func togglePin(_ item: ClipboardItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isPinned.toggle()
        persist()
    }

    func delete(_ item: ClipboardItem) { items.removeAll { $0.id == item.id }; persist() }
    func clear() { items.removeAll { !$0.isPinned }; persist() }

    private func trim() {
        let limit = max(10, NotchSettings.shared.clipboardHistoryLimit)
        while items.count > limit {
            if let i = items.lastIndex(where: { !$0.isPinned }) { items.remove(at: i) } else { break }
        }
    }

    private func persist() {
        guard NotchSettings.shared.clipboardPersist else { return }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func restore() {
        guard NotchSettings.shared.clipboardPersist,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
        trim()
    }
}

struct NoteItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool
}

final class NotesViewModel: ObservableObject {
    @Published var notes: [NoteItem] = [] { didSet { persist() } }
    @Published var selectedID: UUID?
    @Published var query = ""

    // Keep the active editor separate from the published notes array. Updating the
    // array on every TextEditor keystroke causes SwiftUI to recreate the binding and
    // can move the insertion point to the end of the document.
    @Published var draftTitle = ""
    @Published var draftBody = ""

    private var editingID: UUID?
    private let key = "notchdrop.notes"

    var filtered: [NoteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = q.isEmpty ? notes : notes.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.body.localizedCaseInsensitiveContains(q)
        }
        return result.sorted {
            $0.isPinned != $1.isPinned
                ? $0.isPinned && !$1.isPinned
                : $0.modifiedAt > $1.modifiedAt
        }
    }

    init() { restore() }

    func create() {
        commitEditing()
        let n = NoteItem(
            id: UUID(),
            title: "New Note",
            body: "",
            createdAt: Date(),
            modifiedAt: Date(),
            isPinned: false
        )
        notes.insert(n, at: 0)
        selectedID = n.id
        beginEditing(n)
    }

    func select(_ note: NoteItem) {
        commitEditing()
        selectedID = note.id
        beginEditing(note)
    }

    func beginEditing(_ note: NoteItem) {
        guard editingID != note.id else { return }
        editingID = note.id
        draftTitle = note.title
        draftBody = note.body
    }

    func closeEditor() {
        commitEditing()
        selectedID = nil
        editingID = nil
        draftTitle = ""
        draftBody = ""
    }

    func commitEditing() {
        guard let id = editingID,
              let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        let changed = notes[index].title != draftTitle || notes[index].body != draftBody
        guard changed else { return }

        notes[index].title = draftTitle
        notes[index].body = draftBody
        notes[index].modifiedAt = Date()
    }

    func delete(_ note: NoteItem) {
        if editingID == note.id {
            editingID = nil
            draftTitle = ""
            draftBody = ""
        }
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id { selectedID = nil }
    }

    func togglePin(_ note: NoteItem) {
        update(note.id) { $0.isPinned.toggle() }
    }

    func update(_ id: UUID, _ change: (inout NoteItem) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].modifiedAt = Date()
    }

    private func persist() {
        guard NotchSettings.shared.notesPersist else { return }
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func restore() {
        guard NotchSettings.shared.notesPersist,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NoteItem].self, from: data) else {
            return
        }
        notes = decoded
    }
}

struct AppShortcut: Identifiable, Equatable {
    let id: String
    let url: URL
    let name: String
    let icon: NSImage
}

final class AppLauncherViewModel: ObservableObject {
    @Published private(set) var apps: [AppShortcut] = []
    @Published var query = ""
    @Published var favorites: Set<String> = [] { didSet { UserDefaults.standard.set(Array(favorites), forKey: "notchdrop.appFavorites") } }
    @Published private(set) var recent: [String] = []
    private let workspace = NSWorkspace.shared

    var filtered: [AppShortcut] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return result.sorted { a, b in
            let af = favorites.contains(a.id), bf = favorites.contains(b.id)
            if af != bf { return af && !bf }
            let ar = recent.firstIndex(of: a.id), br = recent.firstIndex(of: b.id)
            if ar != nil || br != nil { return (ar ?? 999) < (br ?? 999) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    init() { refresh(); favorites = Set(UserDefaults.standard.stringArray(forKey: "notchdrop.appFavorites") ?? []); recent = UserDefaults.standard.stringArray(forKey: "notchdrop.appRecent") ?? [] }

    func refresh() {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        ]
        var seen = Set<String>()
        var found: [AppShortcut] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                guard seen.insert(url.path).inserted else { continue }
                let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.deletingPathExtension().lastPathComponent
                found.append(AppShortcut(id: url.path, url: url, name: name, icon: workspace.icon(forFile: url.path)))
            }
        }
        apps = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func launch(_ app: AppShortcut) {
        workspace.open(app.url)
        recent.removeAll { $0 == app.id }
        recent.insert(app.id, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: "notchdrop.appRecent")
    }
    func toggleFavorite(_ app: AppShortcut) { if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) } }
}

enum QuickAction: String, CaseIterable, Identifiable {
    case lock, sleep, restart, shutdown, trash, screenshot, darkMode, settings, activity, finder
    var id: String { rawValue }
    var title: String {
        switch self { case .lock: return "Lock Screen"; case .sleep: return "Sleep"; case .restart: return "Restart"; case .shutdown: return "Shut Down"; case .trash: return "Empty Trash"; case .screenshot: return "Screenshot"; case .darkMode: return "Dark Mode"; case .settings: return "System Settings"; case .activity: return "Activity Monitor"; case .finder: return "Finder" }
    }
    var icon: String {
        switch self { case .lock: return "lock.fill"; case .sleep: return "moon.fill"; case .restart: return "arrow.clockwise"; case .shutdown: return "power"; case .trash: return "trash"; case .screenshot: return "camera.viewfinder"; case .darkMode: return "moon.circle"; case .settings: return "gearshape"; case .activity: return "waveform.path.ecg"; case .finder: return "folder.fill" }
    }
    var destructive: Bool { self == .restart || self == .shutdown || self == .trash }
}

final class QuickActionManager {
    static let shared = QuickActionManager()
    private init() {}
    func run(_ action: QuickAction) {
        switch action {
        case .lock:
            lockScreen()
        case .sleep: runShell("pmset", ["sleepnow"])
        case .restart: runShell("osascript", ["-e", "tell app \"System Events\" to restart"])
        case .shutdown: runShell("osascript", ["-e", "tell app \"System Events\" to shut down"])
        case .trash:
            let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
            if let urls = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }
        case .screenshot:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
        case .darkMode: runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .settings: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .activity: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .finder: NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }
    private func lockScreen() {
        // Primary path: macOS's private login framework exposes the same
        // immediate session-lock operation used by the system login UI.
        // This avoids Accessibility permission and does not depend on
        // Screen Saver password settings.
        let loginFramework = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

        if let handle = dlopen(loginFramework, RTLD_LAZY) {
            defer { dlclose(handle) }

            if let symbol = dlsym(handle, "SACLockScreenImmediate") {
                typealias LockFunction = @convention(c) () -> Void
                let lockFunction = unsafeBitCast(symbol, to: LockFunction.self)
                lockFunction()
                return
            }
        }

        // Fallback 1: CGSession. Confirm success before stopping here.
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.isExecutableFile(atPath: cgSession) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cgSession)
            process.arguments = ["-suspend"]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return
                }
            } catch {
                // Continue to the next fallback.
            }
        }

        // Fallback 2: start ScreenSaverEngine. This secures the session when
        // the user's Lock Screen settings require a password immediately.
        let screenSaver = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        if FileManager.default.fileExists(atPath: screenSaver.path), NSWorkspace.shared.open(screenSaver) {
            return
        }

        // Final fallback: native Lock Screen shortcut through System Events.
        runAppleScript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
    }

    private func runShell(_ path: String, _ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [path] + args; try? p.run() }
    private func runAppleScript(_ source: String) { NSAppleScript(source: source)?.executeAndReturnError(nil) }
}

struct DownloadItem: Identifiable, Equatable {
    let id: URL
    var url: URL
    var isPartial: Bool
    var size: Int64
    var modified: Date
}

final class DownloadsViewModel: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    private var timer: Timer?
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    var active: [DownloadItem] { items.filter(\.isPartial) }

    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() } }
    deinit { timer?.invalidate() }
    func refresh() {
        guard NotchSettings.shared.downloadsEnabled else { items = []; return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return DownloadItem(id: url, url: url, isPartial: url.pathExtension == "download" || url.pathExtension == "crdownload" || url.pathExtension == "part", size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }
    func open(_ item: DownloadItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: DownloadItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func remove(_ item: DownloadItem) { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil); refresh() }
    func cancel(_ item: DownloadItem) { try? FileManager.default.removeItem(at: item.url); refresh() }
}

final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [(id: AudioDeviceID, name: String)] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published var volume: Double = 0.5
    @Published var muted = false
    private var timer: Timer?

    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() } }
    deinit { timer?.invalidate() }

    func refresh() {
        devices = outputDevices()
        defaultDeviceID = defaultOutput()
        if let descriptor = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(nil), descriptor.int32Value >= 0 {
            volume = Double(descriptor.int32Value) / 100.0
        }
    }
    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        runAppleScript("set volume output volume \(Int(volume * 100))")
    }
    func toggleMute() { runAppleScript("set volume output muted not (output muted of (get volume settings))"); muted.toggle() }
    func select(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        refresh()
    }
    private func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    private func outputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let name = name(for: id) else { return nil }
            return (id, name)
        }
    }
    private func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else { return false }
        return bufferList.pointee.mNumberBuffers > 0 && bufferList.pointee.mBuffers.mNumberChannels > 0
    }
    private func name(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
    private func runAppleScript(_ source: String) { NSAppleScript(source: source)?.executeAndReturnError(nil) }
}

struct SystemStatusSnapshot {
    var battery = "--"
    var charging = false
    var wifi = "Unavailable"
    var bluetooth = "Unavailable"
}

final class SystemStatusViewModel: ObservableObject {
    @Published private(set) var status = SystemStatusSnapshot()
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    init() {
        // Refresh the moment the network changes instead of waiting for the timer.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
                self?.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "notchdrop.network"))

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        timer?.invalidate()
        pathMonitor.cancel()
    }

    func refresh() {
        let path = currentPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let battery = self?.shell("pmset", ["-g", "batt"]) ?? ""
            let wifi = Self.wifiSummary(path: path)
            let bluetooth = self?.shell("system_profiler", ["SPBluetoothDataType"]) ?? ""
            let percent = battery.range(of: #"(\d+)%"#, options: .regularExpression).map { String(battery[$0]) } ?? "--"
            let charging = battery.localizedCaseInsensitiveContains("charging") && !battery.localizedCaseInsensitiveContains("discharging")
            let bt = bluetooth.localizedCaseInsensitiveContains("state: on") ? "On" : "Off"
            DispatchQueue.main.async { self?.status = SystemStatusSnapshot(battery: percent, charging: charging, wifi: wifi, bluetooth: bt) }
        }
    }

    /// "Network name · signal · speed" from CoreWLAN, with NWPath for wired / no-internet cases.
    /// On macOS 14+ the network NAME is only readable with Location permission,
    /// so without it this shows "Connected" plus signal and speed (which need no permission).
    private static func wifiSummary(path: NWPath?) -> String {

        let wired = path?.usesInterfaceType(.wiredEthernet) == true

        guard let interface = CWWiFiClient.shared().interface() else {
            return wired ? "Ethernet" : "No Wi-Fi adapter"
        }

        guard interface.powerOn() else { return "Off" }

        let rssi = interface.rssiValue()

        // CoreWLAN reports 0 dBm when not associated with any network.
        guard rssi != 0 else { return wired ? "Ethernet" : "Not connected" }

        var parts = [interface.ssid() ?? "Connected", "\(rssi) dBm"]

        let rate = interface.transmitRate()
        if rate > 0 { parts.append("\(Int(rate)) Mbps") }

        if let path, path.status != .satisfied { parts.append("No internet") }

        return parts.joined(separator: " · ")
    }

    private func shell(_ command: String, _ args: [String]) -> String {
        let p = Process(); let pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [command] + args; p.standardOutput = pipe; try? p.run(); p.waitUntilExit(); return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

final class TimerViewModel: ObservableObject {
    enum Mode: String, CaseIterable { case timer = "Timer", stopwatch = "Stopwatch" }
    @Published var mode: Mode = .timer
    @Published var remaining: TimeInterval = 300
    @Published var stopwatch: TimeInterval = 0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var customMinutes = 5
    @Published var laps: [TimeInterval] = []
    private var timer: Timer?
    private var lastTick = Date()
    private var completionGeneration = 0

    init() { timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() } }
    deinit { timer?.invalidate() }
    func start() { isRunning = true; isPaused = false; lastTick = Date(); completionGeneration += 1 }
    func pause() { isPaused = true; isRunning = false }
    func reset() { isRunning = false; isPaused = false; remaining = 300; stopwatch = 0; laps.removeAll() }
    func setPreset(_ seconds: TimeInterval) { remaining = seconds; isRunning = false; isPaused = false }
    func lap() { laps.insert(stopwatch, at: 0) }
    private func tick() {
        guard isRunning else { lastTick = Date(); return }
        let now = Date(); let delta = now.timeIntervalSince(lastTick); lastTick = now
        if mode == .timer {
            remaining -= delta
            if remaining <= 0 {
                remaining = 0; isRunning = false; completionGeneration += 1
                NSSound(named: NSSound.Name(NotchSettings.shared.timerSound))?.play()
                if NotchSettings.shared.timerHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
                NotificationCenter.default.post(name: .notchDropTimerFinished, object: nil)
            }
        } else { stopwatch += delta }
    }
    var display: String { let t = mode == .timer ? remaining : stopwatch; return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
}

final class RecentFilesViewModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published var query = ""

    var filteredURLs: [URL] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return urls }
        return urls.filter {
            $0.lastPathComponent.localizedCaseInsensitiveContains(q) ||
            $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    func refresh() {
        let roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")]
        let fm = FileManager.default
        var all: [(URL, Date)] = []
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _,_ in true }) else { continue }
            for case let url as URL in e {
                guard !url.hasDirectoryPath, let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                all.append((url, date))
                if all.count > 200 { break }
            }
        }
        urls = all.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
    }
}

struct UtilitySearchField: View {
    @Binding var text: String
    var placeholder: String
    var autoFocus: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            if autoFocus {
                AutoFocusSearchTextField(text: $text, placeholder: placeholder)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .notchLiquidGlass(cornerRadius: 8)
    }
}

private struct AutoFocusSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeKey()
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct ClipboardTabView: View {
    @ObservedObject var model: ClipboardViewModel
    let accent: Color
    var body: some View {
        VStack(spacing: 6) {
            UtilitySearchField(text: $model.query, placeholder: "Search clipboard")
            HStack { Text("\(model.items.count) items").font(.caption).foregroundColor(.secondary); Spacer(); Button("Clear") { model.clear() }.buttonStyle(.borderless) }
            ScrollView { LazyVStack(spacing: 4) { ForEach(model.filteredItems) { item in ClipboardRow(item: item, model: model, accent: accent) } } }
        }.padding(10).frame(height: NotchMetrics.tabContentHeight)
    }
}

struct ClipboardRow: View {
    let item: ClipboardItem; @ObservedObject var model: ClipboardViewModel; let accent: Color
    var body: some View {
        Button(action: { model.recopy(item) }) {
            HStack(spacing: 8) {
                if item.kind == .image, let preview = NSImage(contentsOfFile: item.value) {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: item.kind == .url ? "link" : item.kind == .file ? "doc" : "doc.on.doc").foregroundColor(accent).frame(width: 20)
                }
                Text(item.displayTitle).lineLimit(2).font(.system(size: 10)); Spacer(); if item.isPinned { Image(systemName: "pin.fill").font(.caption2) }
            }
                .padding(7).notchLiquidGlass(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .onDrag {
            switch item.kind {
            case .text, .url: return NSItemProvider(object: item.value as NSString)
            case .file, .image: return NSItemProvider(contentsOf: URL(fileURLWithPath: item.value)) ?? NSItemProvider(object: item.displayTitle as NSString)
            }
        }
        .contextMenu { Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }; Button("Delete", role: .destructive) { model.delete(item) } }
    }
}

struct NotesTabView: View {
    @StateObject private var model = NotesViewModel()
    let accent: Color

    var selected: NoteItem? {
        model.notes.first(where: { $0.id == model.selectedID })
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                UtilitySearchField(text: $model.query, placeholder: "Search notes")
                Button { model.create() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }

            if let note = selected {
                NoteEditor(note: note, model: model, accent: accent)
            } else {
                ScrollView {
                    LazyVStack {
                        ForEach(model.filtered) { note in
                            Button { model.select(note) } label: {
                                noteRow(note)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(height: NotchMetrics.tabContentHeight)
    }

    private func noteRow(_ note: NoteItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(note.body.isEmpty ? "No text" : note.body)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
            }
        }
        .padding(7)
        .notchLiquidGlass(cornerRadius: 8)
    }
}

struct NoteEditor: View {
    let note: NoteItem
    @ObservedObject var model: NotesViewModel
    let accent: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Button { model.closeEditor() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                TextField("Title", text: $model.draftTitle)
                    .textFieldStyle(.plain)

                Spacer()

                Button { model.togglePin(note) } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    model.delete(note)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: $model.draftBody)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            model.beginEditing(note)
        }
        .onDisappear {
            model.commitEditing()
        }
    }
}

struct AppsTabView: View {
    @StateObject private var model = AppLauncherViewModel(); let accent: Color
    var body: some View { VStack(spacing: 6) { UtilitySearchField(text: $model.query, placeholder: "Search applications"); ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 5)], spacing: 5) { ForEach(model.filtered.prefix(40)) { app in Button { model.launch(app) } label: { VStack(spacing: 3) { Image(nsImage: app.icon).resizable().frame(width: 32, height: 32); Text(app.name).font(.system(size: 9)).lineLimit(1) } .frame(maxWidth: .infinity).padding(5).notchLiquidGlass(cornerRadius: 8) }.buttonStyle(.plain).contextMenu { Button(model.favorites.contains(app.id) ? "Unfavorite" : "Favorite") { model.toggleFavorite(app) } } } } } }.padding(10).frame(height: NotchMetrics.tabContentHeight) }
}

struct QuickActionsTabView: View {
    let accent: Color
    @StateObject private var state = QuickActionsState()

    private var availableActions: [QuickAction] {
        QuickAction.allCases.filter { !NotchSettings.shared.hiddenQuickActions.contains($0.rawValue) }
    }

    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(availableActions) { action in
                        Button {
                            if action.destructive {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    state.pending = action
                                }
                            } else {
                                QuickActionManager.shared.run(action)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: action.icon).font(.system(size: 14))
                                Text(action.title).font(.system(size: 8.5)).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
            .frame(height: NotchMetrics.tabContentHeight)
            .clipped()

            if let action = state.pending {
                quickActionConfirmation(for: action)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
                    .zIndex(10)
            }
        }
        .frame(height: NotchMetrics.tabContentHeight)
        .animation(.easeInOut(duration: 0.18), value: state.pending != nil)
    }

    private func quickActionConfirmation(for action: QuickAction) -> some View {
        VStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(action.destructive ? .red : accent)

            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Text("Are you sure you want to continue?")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 7) {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.pending = nil
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.10)))

                Button(action.title == "Empty Trash" ? "Empty" : "Continue") {
                    let confirmed = action
                    state.pending = nil
                    QuickActionManager.shared.run(confirmed)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(action.destructive ? Color.red.opacity(0.75) : accent))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(5)
    }
}

struct DownloadsTabView: View {
    @ObservedObject var model: DownloadsViewModel; let accent: Color
    var body: some View { VStack(spacing: 5) { HStack { Text("Downloads").font(.system(size: 11, weight: .semibold)); Spacer(); Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain) }; ScrollView { LazyVStack(spacing: 4) { ForEach(model.items.prefix(25)) { item in HStack { Image(systemName: item.isPartial ? "arrow.down.circle" : "doc.fill").foregroundColor(item.isPartial ? accent : .secondary); VStack(alignment: .leading, spacing: 2) { Text(item.url.lastPathComponent).font(.system(size: 9)).lineLimit(1); Text(item.isPartial ? "Downloading…" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.system(size: 8)).foregroundColor(.secondary) }; Spacer(); Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain) }.padding(5).notchLiquidGlass(cornerRadius: 7).contextMenu { Button("Open") { model.open(item) }; Button("Reveal in Finder") { model.reveal(item) }; if item.isPartial { Button("Cancel", role: .destructive) { model.cancel(item) } } else { Button("Remove", role: .destructive) { model.remove(item) } } } } } } }.padding(10).frame(height: NotchMetrics.tabContentHeight) }
}

struct AudioTabView: View {
    @ObservedObject var model: AudioDeviceManager; let accent: Color
    var body: some View { VStack(alignment: .leading, spacing: 7) { HStack { Text("Volume").font(.caption); Spacer(); Text("\(Int(model.volume * 100))%").font(.caption.monospacedDigit()) }; HStack { Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"); Slider(value: $model.volume, in: 0...1) { _ in model.setVolume(model.volume) }.tint(accent); Button { model.toggleMute() } label: { Image(systemName: model.muted ? "speaker.slash" : "speaker.wave.2") }.buttonStyle(.plain) }; Text("Output").font(.caption).foregroundColor(.secondary); ScrollView { ForEach(model.devices, id: \.id) { device in Button { model.select(device.id) } label: { HStack { Image(systemName: device.id == model.defaultDeviceID ? "checkmark.circle.fill" : "circle"); Text(device.name).font(.system(size: 10)); Spacer() } }.buttonStyle(.plain) } } }.padding(10).frame(height: NotchMetrics.tabContentHeight) }
}

struct TimerTabView: View {
    @ObservedObject var model: TimerViewModel; let accent: Color
    var body: some View { VStack(spacing: 7) { Picker("Mode", selection: $model.mode) { ForEach(TimerViewModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented); Text(model.display).font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit()); HStack { ForEach([60.0, 300.0, 600.0, 1500.0], id: \.self) { seconds in Button(Int(seconds) >= 60 ? "\(Int(seconds)/60)m" : "1m") { model.setPreset(seconds) }.buttonStyle(.borderless) } }; HStack { Button(model.isRunning ? "Pause" : "Start") { model.isRunning ? model.pause() : model.start() }.buttonStyle(.borderedProminent).tint(accent); Button("Reset") { model.reset() }.buttonStyle(.borderless); if model.mode == .stopwatch { Button("Lap") { model.lap() }.buttonStyle(.borderless) } } }.padding(10).frame(height: NotchMetrics.tabContentHeight) }
}

struct SystemTabView: View {
    @ObservedObject var model: SystemStatusViewModel; let accent: Color
    var body: some View { VStack(spacing: 8) { HStack { Image(systemName: "battery.75horizontal"); Text("Battery"); Spacer(); Text(model.status.battery + (model.status.charging ? " · Charging" : "")) }; HStack { Image(systemName: "wifi"); Text("Wi-Fi"); Spacer(); Text(model.status.wifi).lineLimit(1) }; HStack { Image(systemName: "dot.radiowaves.left.and.right"); Text("Bluetooth"); Spacer(); Text(model.status.bluetooth) }; Spacer() }.font(.system(size: 10)).padding(12).frame(height: NotchMetrics.tabContentHeight) }
}

struct TimerActivityView: View {
    @ObservedObject var model: TimerViewModel
    var body: some View { Text(model.display).font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit()).foregroundColor(.white).frame(width: NotchMetrics.liveWingWidth * 2) }
}