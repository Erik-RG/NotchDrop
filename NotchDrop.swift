import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EventKit
import UserNotifications

// MARK: - Notch Metrics

enum NotchMetrics {
    static let collapsedSize = CGSize(width: 200, height: 26)
    static let collapsedRadius: CGFloat = 10
    static let expandedSize = CGSize(width: 350, height: 190)
    // Extra window bounds clearance so the spring overshoot is never clipped by the NSWindow frame.
    static let expandedWindowSize = CGSize(width: 370, height: 210)
    // Height of the tab content area (Media & Files / Calendar / Alarms all share it).
    static let tabContentHeight: CGFloat = 130
    static let dragHitboxSize = CGSize(width: 350, height: 680)

    // The drag hitbox is only rendered while this key is held during a file drag.
    // Without it the window never grows, so Finder keeps full control of the drag.
    // Options: .maskControl, .maskShift, .maskAlternate (Finder: copy), .maskCommand
    static let dragActivationKey: CGEventFlags = .maskControl
    static let expansionAnimationDuration: TimeInterval = 0.45
    static let expansionSpring: Animation = .spring(
        response: 0.38,
        dampingFraction: 0.62,
        blendDuration: 0
    )
}

// MARK: - Notch Shape
// Top corners are ALWAYS square. Only the bottom corners are rounded.

struct NotchShape: Shape {

    var bottomRadius: CGFloat = 10

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(bottomRadius, rect.height / 2, rect.width / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
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

                // No cover art (e.g. browser, VLC): show the source app's icon instead.
                let image = art ?? (source.isEmpty ? nil : appIcon(name: source, bundle: bundle))

                completion(title, artist, playing, image, position, duration)
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct NotchDropApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        MenuBarExtra("NotchDrop", systemImage: "tray.and.arrow.down.fill") {
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

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchWindowManager.shared.setupWindow()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let notchDropFileReceived = Notification.Name("NotchDropFileReceived")
}

// MARK: - AppKit Drag Destination

final class NotchPanel: NSPanel, NSDraggingDestination {

    weak var windowManager: NotchWindowManager?

    // Needed so text fields can receive typing; only enabled while a time is being typed.
    override var canBecomeKey: Bool {
        windowManager?.allowsKeyboardInput ?? false
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func isOverDropZone(_ sender: NSDraggingInfo) -> Bool {
        let screenPoint = convertToScreen(
            NSRect(origin: sender.draggingLocation, size: .zero)
        ).origin

        return windowManager?.canAcceptFileDrop(atScreenLocation: screenPoint) == true
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender), isOverDropZone(sender) else { return [] }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender), isOverDropZone(sender) else { return [] }
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        // The global drag monitor owns the drag state.
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        // The global drag monitor ends the drag session.
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURLs(sender) && isOverDropZone(sender)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {

        guard isOverDropZone(sender) else { return false }

        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            let url = urls.first
        else {
            return false
        }

        windowManager?.receiveDroppedFile(url)
        return true
    }

    func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // Expansion state is handled by the window manager.
    }
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

        let notchPath = NotchShape(bottomRadius: NotchMetrics.collapsedRadius)
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

    private var monitors: [Any] = []

    private enum HoverState {
        case armed
        case expanded
        case closing
        case waitingForExit
    }

    private var hoverState: HoverState = .armed
    private var cursorWasInsideCollapsedNotch = false
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

        panel.registerForDraggedTypes([.fileURL])

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

            if !isFileDragging {
                hoverState = .expanded
            }

        } else {

            if !isExpanded && !isPinned && !isFileDragging {
                hoverState = .closing
            }
        }

        visualExpanded = expanded

        if expanded {
            startHoverExitWatch()
        } else {
            stopHoverExitWatch()
        }

        refreshWindow()
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

        setVisualExpansion(false)
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

        setVisualExpansion(false)
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

        let width = NotchMetrics.expandedSize.width
        let height = NotchMetrics.expandedSize.height

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
                beginHoverExpansion()
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
                cursorWasInsideCollapsedNotch = false
                hoverState = .armed
                return
            }

            let entered = hoverState == .armed && !cursorWasInsideCollapsedNotch

            cursorWasInsideCollapsedNotch = true

            guard entered else { return }

            beginHoverExpansion()

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
    // accepted, receiveDroppedFile() sets visualExpanded, so the notch stays open.
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
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
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

    func receiveDroppedFile(_ url: URL) {

        // A successful drop must leave the notch expanded.
        contractionGeneration += 1
        contractionWorkItem?.cancel()
        contractionWorkItem = nil

        cursorWasInsideCollapsedNotch = false
        hoverState = .expanded

        setVisualExpansion(true)

        NotificationCenter.default.post(
            name: .notchDropFileReceived,
            object: url
        )
    }

    func clearFiles() {
        clearTrigger.toggle()
    }
}

// MARK: - Notch View Model

final class NotchViewModel: ObservableObject {

    @Published var isPinned = false
    @Published var selectedTab: NotchTab = .home
    @Published var isTopTargeted = false
    @Published var isShelfTargeted = false
    @Published var storedFiles: [URL] = []
    @Published var isPlaying = false
    @Published var currentSong = "Not Playing"
    @Published var currentArtist = "No Active Media"
    @Published var coverArt: NSImage?

    // Playback position (seconds), sampled at `positionSampledAt` and extrapolated between polls.
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var scrubPosition: Double?

    private var positionSampledAt = Date()
    private var seekHoldUntil = Date.distantPast

    private var mediaTimer: Timer?
    private var dropObserver: NSObjectProtocol?

    init() {

        dropObserver = NotificationCenter.default.addObserver(
            forName: .notchDropFileReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in

            guard let url = notification.object as? URL else { return }

            self?.storedFiles = [url]
        }

        startMediaMonitoring()
    }

    deinit {

        mediaTimer?.invalidate()

        if let dropObserver {
            NotificationCenter.default.removeObserver(dropObserver)
        }
    }

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

            self.currentSong = song
            self.currentArtist = artist
            self.isPlaying = playing
            self.coverArt = art
            self.duration = duration

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

    func removeFile(_ url: URL) {
        storedFiles.removeAll { $0 == url }
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
}

// MARK: - Tabs

enum NotchTab: String, CaseIterable, Identifiable {

    case home
    case calendar
    case alarms

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .alarms: return "alarm.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return "Media & Files"
        case .calendar: return "Calendar"
        case .alarms: return "Alarms"
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

        DispatchQueue.global(qos: .utility).async { [weak self] in

            let calendar = Calendar.current
            let now = Date()
            let start = calendar.startOfDay(for: now)

            guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

            let entries: [CalendarEntry] = store.events(matching: predicate)
                .filter { $0.isAllDay || $0.endDate > now }
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

// MARK: - Calendar Tab View

struct CalendarTabView: View {

    @ObservedObject var model: CalendarViewModel

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
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
            .onAppear {
                model.refresh()
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
                .foregroundColor(.blue)

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
                    .background(Capsule().fill(Color.blue))
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

                    Text("Nothing coming up this week")
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

    // Editor state (kept here because @State needs a macro plugin that plain swiftc lacks).
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

        let alarmSound = NSSound(named: NSSound.Name("Glass"))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
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

    func snooze(minutes: Int = 5) {

        guard ringing != nil else { return }

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

    var body: some View {

        content
            .frame(maxWidth: .infinity)
            .frame(height: NotchMetrics.tabContentHeight)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
            .onAppear {
                model.refreshAccess()
            }
    }

    @ViewBuilder
    private var content: some View {

        if model.ringing != nil {

            ringingView

        } else {

            switch model.access {
            case .notDetermined:
                permissionPrompt
            case .denied:
                deniedView
            case .granted:
                if model.isEditing {
                    editor
                } else {
                    alarmList
                }
            }
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
                    .background(Capsule().fill(Color.blue))
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

            Image(systemName: "alarm.waves.left.and.right.fill")
                .font(.system(size: 20))
                .foregroundColor(.orange)

            if let alarm = model.ringing {
                Text(AlarmViewModel.timeString(hour: alarm.hour, minute: alarm.minute))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            HStack(spacing: 8) {

                Button(action: { model.snooze() }) {
                    Text("Snooze 5 min")
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

            } else {

                ScrollView(.vertical, showsIndicators: false) {

                    VStack(spacing: 3) {

                        ForEach(model.alarms) { alarm in
                            row(for: alarm)
                        }
                    }
                }
            }
        }
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

            } else {

                Text("Click a box and type the time")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
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
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
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
            }
        }
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

    /// False while the notch is collapsed, so the clock isn't ticking for nothing.
    let isActive: Bool

    var body: some View {

        if viewModel.duration > 0 {

            if isActive {

                TimelineView(.periodic(from: Date(), by: 0.5)) { context in
                    bar(at: context.date)
                }

            } else {

                bar(at: Date())
            }
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
                        .fill(Color.white)
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
                            viewModel.scrubPosition = seconds(at: value.location.x, width: geo.size.width)
                        }
                        .onEnded { value in
                            viewModel.finishScrub(to: seconds(at: value.location.x, width: geo.size.width))
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

// MARK: - Notch Container View

struct NotchContainerView: View {

    @ObservedObject private var windowManager = NotchWindowManager.shared

    @StateObject private var viewModel = NotchViewModel()

    @StateObject private var calendarModel = CalendarViewModel()

    @StateObject private var alarmModel = AlarmViewModel()

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

    @ViewBuilder
    private var homeTabContent: some View {

        VStack(spacing: 10) {

            // MARK: Now Playing

            VStack(spacing: 6) {

            HStack(spacing: 10) {

                if let coverArt = viewModel.coverArt {

                    Image(nsImage: coverArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .cornerRadius(6)
                        .clipped()

                } else {

                    Image(systemName: viewModel.isPlaying ? "waveform" : "music.note")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                }

                VStack(alignment: .leading, spacing: 1) {

                    Text(viewModel.currentSong)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(viewModel.currentArtist)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 12) {

                    Button(action: { viewModel.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    Button(action: { viewModel.togglePlayback() }) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: { viewModel.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            SeekBarView(viewModel: viewModel, isActive: isExpandedState)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
            )

            // MARK: File Area

            VStack(spacing: 6) {

                if viewModel.storedFiles.isEmpty {

                    VStack(spacing: 4) {

                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)

                        Text("Hold ^ (control) key while dropping file here to add")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)

                } else {

                    ScrollView(.horizontal, showsIndicators: false) {

                        HStack(spacing: 8) {

                            ForEach(viewModel.storedFiles, id: \.self) { url in

                                HStack(spacing: 5) {

                                    Image(systemName: "doc.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue)

                                    Text(url.lastPathComponent)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    Button(action: {
                                        viewModel.removeFile(url)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(8)
                                .onDrag {
                                    NSItemProvider(object: url as NSURL)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(height: 50)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        windowManager.isFileDragging
                            ? Color.blue.opacity(0.2)
                            : Color.white.opacity(0.08)
                    )
            )
        }

    }

    private func handleSelectedTabChange(_ tab: NotchTab) {

        switch tab {
        case .home:
            break
        case .calendar:
            calendarModel.refresh()
        case .alarms:
            alarmModel.refreshAccess()
        }

        if tab != .alarms {
            alarmModel.cancelEditing()
        }
    }

    private var notchHeader: some View {

        HStack {

            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Text("NotchDrop")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()
            tabBar
            pinButton
        }
        .padding(.top, 10)
    }

    private var tabBar: some View {

        HStack(spacing: 4) {
            ForEach(NotchTab.allCases) { tab in
                Button(action: {
                    switchToTab(tab)
                }) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(viewModel.selectedTab == tab ? .white : .gray)
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(viewModel.selectedTab == tab ? 0.18 : 0.0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(.trailing, 6)
    }

    private var pinButton: some View {

        Button(action: {
            viewModel.isPinned.toggle()
            windowManager.setPinned(viewModel.isPinned)
        }) {
            Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(viewModel.isPinned ? .orange : .gray)
        }
        .buttonStyle(.plain)
        .help(viewModel.isPinned ? "Unpin Notch" : "Pin Notch Open")
    }

    private func switchToTab(_ tab: NotchTab) {
        guard viewModel.selectedTab != tab else { return }

        withAnimation(.easeInOut(duration: 0.24)) {
            viewModel.selectedTab = tab
        }

        windowManager.debugState("tab clicked")
        windowManager.clearManualExpansion()
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        if viewModel.selectedTab == .home {
            homeTabContent
                .transition(.opacity)
        } else if viewModel.selectedTab == .calendar {
            CalendarTabView(model: calendarModel)
                .transition(.opacity)
        } else {
            AlarmTabView(model: alarmModel)
                .transition(.opacity)
        }
    }

    private var mainContent: some View {

        VStack(spacing: 10) {
            notchHeader

            ZStack {
                selectedTabContent
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.24), value: viewModel.selectedTab)
        }
        .frame(width: 320, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .offset(y: isExpandedState ? 0 : -14)
        .opacity(isExpandedState ? 1.0 : 0.0)
        .animation(
            NotchMetrics.expansionSpring,
            value: isExpandedState
        )
        .allowsHitTesting(isExpandedState)
    }

    var body: some View {

        ZStack(alignment: .top) {

            NotchShape(bottomRadius: isExpandedState ? 18 : 10)
                .fill(Color.black)
                .frame(width: visualWidth, alignment: .top)
                .frame(height: visualHeight, alignment: .top)
                .contentShape(NotchShape(bottomRadius: isExpandedState ? 18 : 10))
                .onTapGesture {
                    windowManager.handleNotchTap()
                }
                .animation(
                    NotchMetrics.expansionSpring,
                    value: visualHeight
                )

            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 32, height: 4)
                .padding(.top, 11)
                .offset(y: isExpandedState ? -10 : 0)
                .opacity(isExpandedState ? 0.0 : 1.0)
                .animation(
                    NotchMetrics.expansionSpring,
                    value: isExpandedState
                )
                .allowsHitTesting(false)

            mainContent
        }
        .frame(
            width: NotchMetrics.dragHitboxSize.width,
            height: NotchMetrics.dragHitboxSize.height,
            alignment: .top
        )
        .background(Color.clear)
        .onAppear {
            windowManager.setPinned(viewModel.isPinned)

            if windowManager.isExpanded {
                windowManager.setVisualExpansion(true)
            }
        }
        .onChange(of: viewModel.isPinned) { newValue in
            windowManager.setPinned(newValue)
        }
        .onChange(of: windowManager.clearTrigger) { _ in
            viewModel.storedFiles.removeAll()
        }
        .onChange(of: windowManager.isFileDragging) { dragging in
            if dragging {
                viewModel.selectedTab = .home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropFileReceived)) { _ in
            viewModel.selectedTab = .home
        }
        .onChange(of: viewModel.selectedTab) { tab in
            handleSelectedTabChange(tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchDropAlarmRinging)) { _ in
            viewModel.selectedTab = .alarms
        }
    }
}
