import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Notch Metrics

enum NotchMetrics {

    static let collapsedSize = CGSize(
        width: 200,
        height: 26
    )

    static let collapsedRadius: CGFloat = 10

    static let expandedSize = CGSize(
        width: 350,
        height: 170
    )

    static let dragHitboxSize = CGSize(
        width: 350,
        height: 680
    )

    static let expansionAnimationDuration: TimeInterval = 0.24
}

// MARK: - Notch Shape
// Top corners are ALWAYS square.
// Only the bottom corners are rounded.

struct NotchShape: Shape {

    var bottomRadius: CGFloat = 10

    var animatableData: CGFloat {
        get {
            bottomRadius
        }

        set {
            bottomRadius = newValue
        }
    }

    func path(in rect: CGRect) -> Path {

        var path = Path()

        let radius = min(
            bottomRadius,
            rect.height / 2,
            rect.width / 2
        )

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: rect.maxY - radius
            )
        )

        path.addArc(
            center: CGPoint(
                x: rect.maxX - radius,
                y: rect.maxY - radius
            ),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX + radius,
                y: rect.maxY
            )
        )

        path.addArc(
            center: CGPoint(
                x: rect.minX + radius,
                y: rect.maxY - radius
            ),
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

class MediaController {

    static func postMediaKey(
        _ key: Int32
    ) {

        func sendEvent(
            down: Bool
        ) {

            let flags = NSEvent.ModifierFlags(
                rawValue: down
                ? 0xa00
                : 0xb00
            )

            let data1 = Int(
                (key << 16) |
                (down ? 0xa00 : 0xb00)
            )

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

            event?.cgEvent?.post(
                tap: .cghidEventTap
            )
        }

        sendEvent(down: true)
        sendEvent(down: false)
    }

    private static func performMediaAction(
        command: String,
        fallbackKey: Int32
    ) {

        DispatchQueue.global(
            qos: .userInitiated
        ).async {

            let scriptSource = """
            tell application "System Events"
                if exists (process "Music") then
                    tell application "Music" to \(command)
                    return "ok"
                else if exists (process "Spotify") then
                    tell application "Spotify" to \(command)
                    return "ok"
                end if
            end tell
            return "fallback"
            """

            var error: NSDictionary?

            if let script = NSAppleScript(
                source: scriptSource
            ) {

                let descriptor =
                    script.executeAndReturnError(
                        &error
                    )

                if descriptor.stringValue == "ok" {
                    return
                }
            }

            postMediaKey(fallbackKey)
        }
    }

    static func togglePlayPause() {

        performMediaAction(
            command: "playpause",
            fallbackKey: 16
        )
    }

    static func nextTrack() {

        performMediaAction(
            command: "next track",
            fallbackKey: 17
        )
    }

    static func previousTrack() {

        performMediaAction(
            command: "previous track",
            fallbackKey: 18
        )
    }

    static func fetchCurrentTrack(
        completion: @escaping (
            String,
            String,
            Bool,
            NSImage?
        ) -> Void
    ) {

        DispatchQueue.global(
            qos: .userInitiated
        ).async {

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

                            return (name of current track) & "|||" & (artist of current track) & "|||" & (player state as string) & "|||" & artPath
                        end if
                    end tell

                else if exists (process "Spotify") then
                    tell application "Spotify"
                        if player state is playing or player state is paused then
                            set artUrl to ""

                            try
                                set artUrl to artwork url of current track
                            end try

                            return (name of current track) & "|||" & (artist of current track) & "|||" & (player state as string) & "|||" & artUrl
                        end if
                    end tell
                end if
            end tell

            return "Not Playing|||No Active Media|||stopped|||"
            """

            var error: NSDictionary?

            if let script = NSAppleScript(
                source: scriptSource
            ) {

                let descriptor =
                    script.executeAndReturnError(
                        &error
                    )

                if let string = descriptor.stringValue,
                   !string.isEmpty {

                    let parts =
                        string.components(
                            separatedBy: "|||"
                        )

                    if parts.count >= 3 {

                        let title = parts[0]
                        let artist = parts[1]

                        let isPlaying =
                            parts[2] == "playing"

                        let artSource =
                            parts.count > 3
                            ? parts[3]
                            : ""

                        var coverImage: NSImage?

                        if artSource.hasPrefix("http://") ||
                           artSource.hasPrefix("https://") {

                            if let url = URL(string: artSource),
                               let data = try? Data(contentsOf: url) {

                                coverImage =
                                    NSImage(
                                        data: data
                                    )
                            }

                        } else if
                            !artSource.isEmpty,
                            FileManager.default.fileExists(
                                atPath: artSource
                            ) {

                            if let data =
                                try? Data(
                                    contentsOf:
                                        URL(
                                            fileURLWithPath:
                                                artSource
                                        )
                                ) {

                                coverImage =
                                    NSImage(
                                        data: data
                                    )
                            }
                        }

                        DispatchQueue.main.async {

                            completion(
                                title,
                                artist,
                                isPlaying,
                                coverImage
                            )
                        }

                        return
                    }
                }
            }

            DispatchQueue.main.async {

                completion(
                    "Not Playing",
                    "No Active Media",
                    false,
                    nil
                )
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct NotchDropApp: App {

    @NSApplicationDelegateAdaptor(
        AppDelegate.self
    )
    var appDelegate

    var body: some Scene {

        MenuBarExtra(
            "NotchDrop",
            systemImage:
                "tray.and.arrow.down.fill"
        ) {

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

                NotchWindowManager
                    .shared
                    .togglePanel()
            }

            Button("Clear Stored Files") {

                NotchWindowManager
                    .shared
                    .clearFiles()
            }

            Divider()

            Button("Quit") {

                NSApplication.shared
                    .terminate(nil)
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate:
    NSObject,
    NSApplicationDelegate {

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        NSApp.setActivationPolicy(
            .accessory
        )

        NotchWindowManager
            .shared
            .setupWindow()
    }
}

// MARK: - Notifications

extension Notification.Name {

    static let notchDropFileReceived =
        Notification.Name(
            "NotchDropFileReceived"
        )
}

// MARK: - AppKit Drag Destination

final class NotchPanel:
    NSPanel,
    NSDraggingDestination {

    weak var windowManager:
        NotchWindowManager?

    func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {

        guard sender.draggingPasteboard
            .canReadObject(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly:
                        true
                ]
            )
        else {
            return []
        }

        windowManager?
            .beginFileDragging()

        return .copy
    }

    func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {

        guard sender.draggingPasteboard
            .canReadObject(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly:
                        true
                ]
            )
        else {
            return []
        }

        return .copy
    }

    func draggingExited(
        _ sender: NSDraggingInfo?
    ) {

        windowManager?
            .endFileDragging()
    }

    func draggingEnded(
        _ sender: NSDraggingInfo
    ) {

        windowManager?
            .endFileDragging()
    }

    func prepareForDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {

        sender.draggingPasteboard
            .canReadObject(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly:
                        true
                ]
            )
    }

    func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {

        let pasteboard =
            sender.draggingPasteboard

        guard let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly:
                        true
                ]
            ) as? [URL],

            let url = urls.first
        else {

            windowManager?
                .endFileDragging()

            return false
        }

        windowManager?
            .receiveDroppedFile(url)

        windowManager?
            .endFileDragging()

        return true
    }

    func concludeDragOperation(
        _ sender: NSDraggingInfo?
    ) {

        windowManager?
            .endFileDragging()
    }
}

// MARK: - Precise Hit-Test View

final class NotchInteractionView:
    NSView {

    weak var windowManager:
        NotchWindowManager?

    private let hostingView:
        NSView

    init(
        hostingView: NSView,
        windowManager: NotchWindowManager
    ) {

        self.hostingView =
            hostingView

        self.windowManager =
            windowManager

        super.init(frame: .zero)

        wantsLayer = true

        layer?.backgroundColor =
            NSColor.clear.cgColor

        layer?.isOpaque = false

        hostingView.wantsLayer = true

        hostingView.layer?
            .backgroundColor =
                NSColor.clear.cgColor

        hostingView.layer?
            .isOpaque = false

        addSubview(hostingView)

        layoutHostingView()
    }

    required init?(
        coder: NSCoder
    ) {

        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    override func setFrameSize(
        _ newSize: NSSize
    ) {

        super.setFrameSize(newSize)

        layoutHostingView()
    }

    private func layoutHostingView() {

        let size =
            NotchMetrics.dragHitboxSize

        hostingView.frame =
            NSRect(
                x:
                    (bounds.width - size.width) / 2,

                y:
                    bounds.height - size.height,

                width:
                    size.width,

                height:
                    size.height
            )
    }

    override func hitTest(
        _ point: NSPoint
    ) -> NSView? {

        guard let windowManager
        else {
            return nil
        }

        if windowManager.isHitboxExpanded {
            return super.hitTest(point)
        }

        let notchWidth =
            NotchMetrics.collapsedSize.width

        let notchHeight =
            NotchMetrics.collapsedSize.height

        let originX =
            (bounds.width - notchWidth) / 2

        let originY =
            bounds.height - notchHeight

        let shapePoint =
            CGPoint(
                x:
                    point.x - originX,

                y:
                    notchHeight -
                    (point.y - originY)
            )

        let notchPath =
            NotchShape(
                bottomRadius:
                    NotchMetrics.collapsedRadius
            )
            .path(
                in:
                    CGRect(
                        x: 0,
                        y: 0,
                        width: notchWidth,
                        height: notchHeight
                    )
            )

        guard notchPath.contains(
            shapePoint
        )
        else {
            return nil
        }

        return super.hitTest(point)
    }
}

// MARK: - Window Manager

final class NotchWindowManager:
    ObservableObject {

    static let shared =
        NotchWindowManager()

    private var window:
        NotchPanel?

    @Published var isExpanded =
        false

    @Published var isHitboxExpanded =
        false

    @Published private(set) var
        isFileDragging = false

    @Published var clearTrigger =
        false

    @Published private(set) var
        visualExpanded = false

    @Published private(set) var
        isPinned = false

    private var monitors:
        [Any] = []

    private enum HoverState {

        case armed
        case expanded
        case closing
        case waitingForExit
    }

    private var hoverState:
        HoverState = .armed

    private var cursorWasInsideCollapsedNotch =
        false

    private var contractionGeneration =
        0

    private var contractionWorkItem:
        DispatchWorkItem?

    private var dragSessionActive =
        false

    private var lastDragChangeCount =
        NSPasteboard(
            name: .drag
        ).changeCount

    private var dragWatchdog:
        Timer?

    // MARK: Setup

    func setupWindow() {

        guard let mainScreen =
            NSScreen.main
        else {
            return
        }

        let size =
            NotchMetrics.collapsedSize

        let panel =
            NotchPanel(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: size.width,
                        height: size.height
                    ),
                styleMask: [
                    .borderless,
                    .nonactivatingPanel
                ],
                backing: .buffered,
                defer: false
            )

        panel.windowManager =
            self

        panel.level =
            .popUpMenu

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        panel.backgroundColor =
            NSColor.clear

        panel.isOpaque =
            false

        panel.hasShadow =
            false

        panel.ignoresMouseEvents =
            false

        panel.isMovable =
            false

        panel.hidesOnDeactivate =
            false

        panel.registerForDraggedTypes([
            .fileURL
        ])

        let hostingView =
            NSHostingView(
                rootView:
                    NotchContainerView()
            )

        hostingView.wantsLayer = true

        hostingView.layer?
            .backgroundColor =
                NSColor.clear.cgColor

        hostingView.layer?
            .isOpaque = false

        let interactionView =
            NotchInteractionView(
                hostingView:
                    hostingView,
                windowManager:
                    self
            )

        interactionView.wantsLayer = true

        interactionView.layer?
            .backgroundColor =
                NSColor.clear.cgColor

        interactionView.layer?
            .isOpaque = false

        panel.contentView =
            interactionView

        panel.contentView?
            .wantsLayer = true

        panel.contentView?
            .layer?
            .backgroundColor =
                NSColor.clear.cgColor

        panel.contentView?
            .layer?
            .isOpaque = false

        self.window =
            panel

        let topLeft =
            NSPoint(
                x:
                    mainScreen.frame.midX
                    - size.width / 2,
                y:
                    mainScreen.frame.maxY
            )

        panel.setFrameTopLeftPoint(
            topLeft
        )

        panel.orderFrontRegardless()

        updateCollapsedHoverState()

        startMouseMonitoring()
        startDragMonitoring()
    }

    // MARK: Window Sizing

    private var screenFrame:
        NSRect? {

        (
            window?.screen ??
            NSScreen.main
        )?.frame
    }

    private func applyWindowFrame(
        size: CGSize
    ) {

        guard
            let window,
            let screenFrame
        else {
            return
        }

        var frame =
            window.frame

        frame.size =
            size

        window.setFrame(
            frame,
            display: true
        )

        let topLeft =
            NSPoint(
                x:
                    screenFrame.midX
                    - size.width / 2,
                y:
                    screenFrame.maxY
            )

        window.setFrameTopLeftPoint(
            topLeft
        )
    }

    private func targetWindowSize()
        -> CGSize {

        if isFileDragging {

            return NotchMetrics
                .dragHitboxSize
        }

        if visualExpanded {

            return NotchMetrics
                .expandedSize
        }

        return NotchMetrics
            .collapsedSize
    }

    // MARK: Window Refresh

    private func refreshWindow() {

        isHitboxExpanded =
            visualExpanded ||
            isFileDragging

        let target =
            targetWindowSize()

        guard let window
        else {
            return
        }

        let currentSize =
            window.frame.size

        if target.width >= currentSize.width ||
           target.height >= currentSize.height {

            contractionGeneration += 1

            contractionWorkItem?.cancel()

            contractionWorkItem =
                nil

            applyWindowFrame(
                size:
                    target
            )

            return
        }

        contractionGeneration += 1

        let generation =
            contractionGeneration

        contractionWorkItem?.cancel()

        let item =
            DispatchWorkItem {
                [weak self] in

                guard let self
                else {
                    return
                }

                guard generation ==
                    self.contractionGeneration
                else {
                    return
                }

                let currentTarget =
                    self.targetWindowSize()

                guard currentTarget ==
                    target
                else {

                    self.contractionWorkItem =
                        nil

                    return
                }

                self.applyWindowFrame(
                    size:
                        currentTarget
                )

                self.isHitboxExpanded =
                    self.visualExpanded ||
                    self.isFileDragging

                self.contractionWorkItem =
                    nil

                if currentTarget ==
                    NotchMetrics.collapsedSize,
                   !self.visualExpanded,
                   !self.isFileDragging,
                   !self.isExpanded,
                   !self.isPinned {

                    guard let screenFrame =
                        self.screenFrame
                    else {

                        self.hoverState =
                            .armed

                        self.cursorWasInsideCollapsedNotch =
                            false

                        return
                    }

                    let mouse =
                        NSEvent.mouseLocation

                    let inside =
                        self.mouseIsInsideCollapsedNotch(
                            mouse,
                            screenFrame:
                                screenFrame
                        )

                    self.cursorWasInsideCollapsedNotch =
                        inside

                    if inside {

                        self.hoverState =
                            .waitingForExit

                    } else {

                        self.hoverState =
                            .armed
                    }
                }
            }

        contractionWorkItem =
            item

        DispatchQueue.main.asyncAfter(
            deadline:
                .now()
                +
                NotchMetrics
                    .expansionAnimationDuration,
            execute:
                item
        )
    }

    // MARK: Manual Expansion

    func togglePanel() {

        if isExpanded {

            isExpanded =
                false

            if isPinned {

                setVisualExpansion(
                    true
                )

            } else {

                hoverState =
                    .closing

                cursorWasInsideCollapsedNotch =
                    true

                setVisualExpansion(
                    false
                )
            }

            return
        }

        contractionGeneration += 1

        contractionWorkItem?.cancel()

        contractionWorkItem =
            nil

        isExpanded =
            true

        cursorWasInsideCollapsedNotch =
            false

        hoverState =
            .expanded

        setVisualExpansion(
            true
        )
    }

    func setVisualExpansion(
        _ expanded: Bool
    ) {

        if expanded {

            contractionGeneration += 1

            contractionWorkItem?.cancel()

            contractionWorkItem =
                nil

            if !isFileDragging {

                hoverState =
                    .expanded
            }

        } else {

            if !isExpanded &&
               !isPinned &&
               !isFileDragging {

                hoverState =
                    .closing
            }
        }

        visualExpanded =
            expanded

        refreshWindow()
    }

    // MARK: Pin State

    func setPinned(
        _ pinned: Bool
    ) {

        isPinned =
            pinned

        if pinned {

            contractionGeneration += 1

            contractionWorkItem?.cancel()

            contractionWorkItem =
                nil

            hoverState =
                .expanded

            cursorWasInsideCollapsedNotch =
                false

            setVisualExpansion(
                true
            )

        } else if !isExpanded {

            if visualExpanded {

                hoverState =
                    .expanded

            } else {

                updateCollapsedHoverState()
            }
        }
    }

    // MARK: Hover Expansion

    private func beginHoverExpansion() {

        guard
            hoverState == .armed,
            !isExpanded,
            !isPinned,
            !isFileDragging,
            !visualExpanded
        else {
            return
        }

        hoverState =
            .expanded

        cursorWasInsideCollapsedNotch =
            true

        contractionGeneration += 1

        contractionWorkItem?.cancel()

        contractionWorkItem =
            nil

        setVisualExpansion(
            true
        )
    }

    private func endHoverExpansion() {

        guard
            !isExpanded,
            !isPinned,
            !isFileDragging,
            visualExpanded,
            hoverState == .expanded
        else {
            return
        }

        hoverState =
            .closing

        setVisualExpansion(
            false
        )
    }

    // MARK: Mouse Geometry

    private func mouseIsInsideCollapsedNotch(
        _ mouse: NSPoint,
        screenFrame: NSRect
    ) -> Bool {

        let width =
            NotchMetrics
                .collapsedSize
                .width

        let height =
            NotchMetrics
                .collapsedSize
                .height

        return
            mouse.x >=
                screenFrame.midX -
                width / 2
            &&
            mouse.x <=
                screenFrame.midX +
                width / 2
            &&
            mouse.y >=
                screenFrame.maxY -
                height
            &&
            mouse.y <=
                screenFrame.maxY
    }

    private func mouseIsInsideExpandedPanel(
        _ mouse: NSPoint,
        screenFrame: NSRect
    ) -> Bool {

        let width =
            NotchMetrics
                .expandedSize
                .width

        let height =
            NotchMetrics
                .expandedSize
                .height

        return
            mouse.x >=
                screenFrame.midX -
                width / 2
            &&
            mouse.x <=
                screenFrame.midX +
                width / 2
            &&
            mouse.y >=
                screenFrame.maxY -
                height
            &&
            mouse.y <=
                screenFrame.maxY
    }

    // MARK: Collapsed Hover State

    private func updateCollapsedHoverState() {

        guard let screenFrame
        else {
            return
        }

        let mouse =
            NSEvent.mouseLocation

        let inside =
            mouseIsInsideCollapsedNotch(
                mouse,
                screenFrame:
                    screenFrame
            )

        cursorWasInsideCollapsedNotch =
            inside

        if inside {

            hoverState =
                .waitingForExit

        } else {

            hoverState =
                .armed
        }
    }

    // MARK: Mouse Hover Monitoring

    private func startMouseMonitoring() {

        if let monitor =
            NSEvent.addGlobalMonitorForEvents(
                matching:
                    .mouseMoved,
                handler:
                    { [weak self] _ in

                        self?
                            .handleMouseMoved()
                    }
            ) {

            monitors.append(
                monitor
            )
        }
    }

    private func handleMouseMoved() {

        guard !isFileDragging
        else {
            return
        }

        guard let screenFrame
        else {
            return
        }

        let mouse =
            NSEvent.mouseLocation

        if hoverState == .closing {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(
                    mouse,
                    screenFrame:
                        screenFrame
                )

            cursorWasInsideCollapsedNotch =
                insideCollapsed

            return
        }

        if hoverState == .waitingForExit {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(
                    mouse,
                    screenFrame:
                        screenFrame
                )

            cursorWasInsideCollapsedNotch =
                insideCollapsed

            if !insideCollapsed {

                hoverState =
                    .armed
            }

            return
        }

        if !visualExpanded {

            let insideCollapsed =
                mouseIsInsideCollapsedNotch(
                    mouse,
                    screenFrame:
                        screenFrame
                )

            if !insideCollapsed {

                cursorWasInsideCollapsedNotch =
                    false

                hoverState =
                    .armed

                return
            }

            let entered =
                hoverState == .armed &&
                !cursorWasInsideCollapsedNotch

            cursorWasInsideCollapsedNotch =
                true

            guard entered
            else {
                return
            }

            beginHoverExpansion()

            return
        }

        let insideExpanded =
            mouseIsInsideExpandedPanel(
                mouse,
                screenFrame:
                    screenFrame
            )

        if insideExpanded {
            return
        }

        guard !isExpanded
        else {
            return
        }

        endHoverExpansion()
    }

    // MARK: Drag State

    func beginFileDragging() {

        setFileDragging(
            true
        )
    }

    func endFileDragging() {

        setFileDragging(
            false
        )
    }

    private func setFileDragging(
        _ value: Bool
    ) {

        guard
            isFileDragging != value
        else {
            return
        }

        isFileDragging =
            value

        if value {

            contractionGeneration += 1

            contractionWorkItem?.cancel()

            contractionWorkItem =
                nil

            cursorWasInsideCollapsedNotch =
                false

            hoverState =
                .expanded
        }

        refreshWindow()

        if value {

            startWatchdog()

        } else {

            stopWatchdog()

            if !visualExpanded &&
               !isExpanded &&
               !isPinned {

                updateCollapsedHoverState()
            }
        }
    }

    private func finishDragSession() {

        dragSessionActive =
            false

        setFileDragging(
            false
        )
    }

    // MARK: Global Drag Detection

    private func startDragMonitoring() {

        lastDragChangeCount =
            NSPasteboard(
                name: .drag
            ).changeCount

        if let monitor =
            NSEvent.addGlobalMonitorForEvents(
                matching:
                    .leftMouseDragged,
                handler:
                    { [weak self] _ in

                        self?
                            .handleMouseDragged()
                    }
            ) {

            monitors.append(
                monitor
            )
        }

        if let monitor =
            NSEvent.addLocalMonitorForEvents(
                matching:
                    .leftMouseDragged,
                handler:
                    { [weak self] event in

                        self?
                            .handleMouseDragged()

                        return event
                    }
            ) {

            monitors.append(
                monitor
            )
        }

        if let monitor =
            NSEvent.addGlobalMonitorForEvents(
                matching:
                    .leftMouseUp,
                handler:
                    { [weak self] _ in

                        self?
                            .finishDragSession()
                    }
            ) {

            monitors.append(
                monitor
            )
        }

        if let monitor =
            NSEvent.addLocalMonitorForEvents(
                matching:
                    .leftMouseUp,
                handler:
                    { [weak self] event in

                        self?
                            .finishDragSession()

                        return event
                    }
            ) {

            monitors.append(
                monitor
            )
        }
    }

    private func isCursorInTopCenterZone(
        _ size: CGSize
    ) -> Bool {

        guard let screenFrame
        else {
            return false
        }

        let mouse =
            NSEvent.mouseLocation

        return
            abs(
                mouse.x -
                screenFrame.midX
            ) <= size.width / 2
            &&
            mouse.y >=
                screenFrame.maxY -
                size.height
            &&
            mouse.y <=
                screenFrame.maxY
    }

    private func handleMouseDragged() {

        let pasteboard =
            NSPasteboard(
                name: .drag
            )

        if pasteboard.changeCount !=
            lastDragChangeCount {

            lastDragChangeCount =
                pasteboard.changeCount

            dragSessionActive =
                pasteboard.canReadObject(
                    forClasses:
                        [NSURL.self],
                    options: [
                        .urlReadingFileURLsOnly:
                            true
                    ]
                )
        }

        guard dragSessionActive
        else {
            return
        }

        let inside =
            isCursorInTopCenterZone(
                NotchMetrics
                    .dragHitboxSize
            )

        setFileDragging(
            inside
        )
    }

    // MARK: Watchdog

    private func startWatchdog() {

        stopWatchdog()

        dragWatchdog =
            Timer.scheduledTimer(
                withTimeInterval:
                    0.25,
                repeats:
                    true
            ) { [weak self] _ in

                if NSEvent
                    .pressedMouseButtons & 1 == 0 {

                    self?
                        .finishDragSession()
                }
            }
    }

    private func stopWatchdog() {

        dragWatchdog?.invalidate()

        dragWatchdog =
            nil
    }

    // MARK: Drop / Clear

    func receiveDroppedFile(
        _ url: URL
    ) {

        NotificationCenter.default.post(
            name:
                .notchDropFileReceived,
            object:
                url
        )

        contractionGeneration += 1

        contractionWorkItem?.cancel()

        contractionWorkItem =
            nil

        cursorWasInsideCollapsedNotch =
            false

        hoverState =
            .expanded

        setVisualExpansion(
            true
        )
    }

    func clearFiles() {

        clearTrigger.toggle()
    }
}

// MARK: - Notch View Model

final class NotchViewModel:
    ObservableObject {

    @Published var isPinned =
        false

    @Published var isTopTargeted =
        false

    @Published var isShelfTargeted =
        false

    @Published var storedFiles:
        [URL] = []

    @Published var isPlaying =
        false

    @Published var currentSong =
        "Not Playing"

    @Published var currentArtist =
        "No Active Media"

    @Published var coverArt:
        NSImage?

    private var mediaTimer:
        Timer?

    private var dropObserver:
        NSObjectProtocol?

    init() {

        dropObserver =
            NotificationCenter.default
                .addObserver(
                    forName:
                        .notchDropFileReceived,
                    object:
                        nil,
                    queue:
                        .main
                ) { [weak self] notification in

                    guard let url =
                        notification.object
                        as? URL
                    else {
                        return
                    }

                    self?
                        .storedFiles =
                        [url]
                }

        startMediaMonitoring()
    }

    deinit {

        mediaTimer?.invalidate()

        if let dropObserver {

            NotificationCenter.default
                .removeObserver(
                    dropObserver
                )
        }
    }

    func startMediaMonitoring() {

        refreshMediaInfo()

        mediaTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    1.5,
                repeats:
                    true
            ) { [weak self] _ in

                self?
                    .refreshMediaInfo()
            }
    }

    func refreshMediaInfo() {

        MediaController
            .fetchCurrentTrack {
                [weak self]
                song,
                artist,
                playing,
                art in

                self?
                    .currentSong =
                    song

                self?
                    .currentArtist =
                    artist

                self?
                    .isPlaying =
                    playing

                self?
                    .coverArt =
                    art
            }
    }

    func handleDrop(
        providers:
            [NSItemProvider]
    ) {

        guard let provider =
            providers.first
        else {
            return
        }

        if provider
            .hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier
            ) {

            provider.loadItem(
                forTypeIdentifier:
                    UTType.fileURL.identifier,
                options:
                    nil
            ) { [weak self] item, _ in

                var extractedURL:
                    URL?

                if let url =
                    item as? URL {

                    extractedURL =
                        url

                } else if
                    let data =
                        item as? Data,

                    let url =
                        URL(
                            dataRepresentation:
                                data,
                            relativeTo:
                                nil
                        ) {

                    extractedURL =
                        url

                } else if
                    let path =
                        item as? String,

                    let url =
                        URL(
                            string:
                                path
                        ) {

                    extractedURL =
                        url
                }

                if let fileURL =
                    extractedURL {

                    DispatchQueue.main.async {

                        self?
                            .storedFiles =
                            [fileURL]
                    }
                }
            }
        }
    }

    func removeFile(
        _ url: URL
    ) {

        storedFiles.removeAll {
            $0 == url
        }
    }

    func togglePlayback() {

        MediaController
            .togglePlayPause()

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 0.25
        ) { [weak self] in

            self?
                .refreshMediaInfo()
        }
    }

    func nextTrack() {

        MediaController
            .nextTrack()

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 0.25
        ) { [weak self] in

            self?
                .refreshMediaInfo()
        }
    }

    func previousTrack() {

        MediaController
            .previousTrack()

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 0.25
        ) { [weak self] in

            self?
                .refreshMediaInfo()
        }
    }
}

// MARK: - Notch Container View

struct NotchContainerView:
    View {

    @ObservedObject private var
        windowManager =
            NotchWindowManager.shared

    @StateObject private var
        viewModel =
            NotchViewModel()

    private var isExpandedState:
        Bool {

        windowManager.isExpanded ||
        viewModel.isPinned ||
        windowManager.visualExpanded ||
        windowManager.isFileDragging
    }

    private var visualWidth:
        CGFloat {

        isExpandedState
        ? NotchMetrics.expandedSize.width
        : NotchMetrics.collapsedSize.width
    }

    private var visualHeight:
        CGFloat {

        isExpandedState
        ? NotchMetrics.expandedSize.height
        : NotchMetrics.collapsedSize.height
    }

    var body: some View {

        ZStack(
            alignment: .top
        ) {

            // MARK: Visible Notch

            NotchShape(
                bottomRadius:
                    isExpandedState
                    ? 18
                    : 10
            )
            .fill(
                Color.black
            )
            .frame(
                width:
                    visualWidth,

                height:
                    visualHeight,

                alignment:
                    .top
            )
            .contentShape(
                NotchShape(
                    bottomRadius:
                        isExpandedState
                        ? 18
                        : 10
                )
            )
            .onTapGesture {

                windowManager
                    .togglePanel()
            }
            .animation(
                .easeInOut(
                    duration:
                        NotchMetrics
                            .expansionAnimationDuration
                ),
                value:
                    isExpandedState
            )

            // MARK: Collapsed Handle

            Capsule()
                .fill(
                    Color.white
                        .opacity(0.35)
                )
                .frame(
                    width: 32,
                    height: 4
                )
                .padding(
                    .top,
                    11
                )
                .opacity(
                    isExpandedState
                    ? 0.0
                    : 1.0
                )
                .animation(
                    .easeInOut(
                        duration: 0.18
                    ),
                    value:
                        isExpandedState
                )
                .allowsHitTesting(
                    false
                )

            // MARK: Main Content

            VStack(
                spacing: 10
            ) {

                HStack {

                    HStack(
                        spacing: 6
                    ) {

                        Image(
                            systemName:
                                "tray.and.arrow.down.fill"
                        )
                        .font(
                            .system(
                                size: 13,
                                weight: .bold
                            )
                        )
                        .foregroundColor(
                            .white
                        )

                        Text(
                            "NotchDrop"
                        )
                        .font(
                            .system(
                                size: 13,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundColor(
                            .white
                        )
                    }

                    Spacer()

                    Button(
                        action: {

                            viewModel
                                .isPinned
                                .toggle()

                            windowManager
                                .setPinned(
                                    viewModel
                                        .isPinned
                                )
                        }
                    ) {

                        Image(
                            systemName:
                                viewModel
                                    .isPinned
                                ? "pin.fill"
                                : "pin"
                        )
                        .font(
                            .system(
                                size: 13,
                                weight: .bold
                            )
                        )
                        .foregroundColor(
                            viewModel
                                .isPinned
                            ? .orange
                            : .gray
                        )
                    }
                    .buttonStyle(
                        .plain
                    )
                    .help(
                        viewModel
                            .isPinned
                        ? "Unpin Notch"
                        : "Pin Notch Open"
                    )
                }
                .padding(
                    .top,
                    10
                )

                // MARK: Now Playing

                HStack(
                    spacing: 10
                ) {

                    if let coverArt =
                        viewModel.coverArt {

                        Image(
                            nsImage:
                                coverArt
                        )
                        .resizable()
                        .aspectRatio(
                            contentMode:
                                .fill
                        )
                        .frame(
                            width: 32,
                            height: 32
                        )
                        .cornerRadius(
                            6
                        )
                        .clipped()

                    } else {

                        Image(
                            systemName:
                                viewModel
                                    .isPlaying
                                ? "waveform"
                                : "music.note"
                        )
                        .font(
                            .system(
                                size: 14,
                                weight: .bold
                            )
                        )
                        .foregroundColor(
                            .blue
                        )
                        .frame(
                            width: 32,
                            height: 32
                        )
                        .background(
                            Color.white
                                .opacity(0.1)
                        )
                        .cornerRadius(
                            6
                        )
                    }

                    VStack(
                        alignment: .leading,
                        spacing: 1
                    ) {

                        Text(
                            viewModel
                                .currentSong
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .semibold
                            )
                        )
                        .foregroundColor(
                            .white
                        )
                        .lineLimit(
                            1
                        )

                        Text(
                            viewModel
                                .currentArtist
                        )
                        .font(
                            .system(
                                size: 10
                            )
                        )
                        .foregroundColor(
                            .gray
                        )
                        .lineLimit(
                            1
                        )
                    }

                    Spacer()

                    HStack(
                        spacing: 12
                    ) {

                        Button(
                            action: {
                                viewModel
                                    .previousTrack()
                            }
                        ) {

                            Image(
                                systemName:
                                    "backward.fill"
                            )
                            .font(
                                .system(
                                    size: 11
                                )
                            )
                            .foregroundColor(
                                .white
                                    .opacity(0.8)
                            )
                        }
                        .buttonStyle(
                            .plain
                        )

                        Button(
                            action: {
                                viewModel
                                    .togglePlayback()
                            }
                        ) {

                            Image(
                                systemName:
                                    viewModel
                                        .isPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                            .font(
                                .system(
                                    size: 12,
                                    weight: .bold
                                )
                            )
                            .foregroundColor(
                                .white
                            )
                        }
                        .buttonStyle(
                            .plain
                        )

                        Button(
                            action: {
                                viewModel
                                    .nextTrack()
                            }
                        ) {

                            Image(
                                systemName:
                                    "forward.fill"
                            )
                            .font(
                                .system(
                                    size: 11
                                )
                            )
                            .foregroundColor(
                                .white
                                    .opacity(0.8)
                            )
                        }
                        .buttonStyle(
                            .plain
                        )
                    }
                }
                .padding(
                    .horizontal,
                    10
                )
                .padding(
                    .vertical,
                    8
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: 10
                    )
                    .fill(
                        Color.white
                            .opacity(0.06)
                    )
                )

                // MARK: File Area

                VStack(
                    spacing: 6
                ) {

                    if viewModel
                        .storedFiles
                        .isEmpty {

                        VStack(
                            spacing: 4
                        ) {

                            Image(
                                systemName:
                                    "arrow.down.doc.fill"
                            )
                            .font(
                                .system(
                                    size: 18
                                )
                            )
                            .foregroundColor(
                                .blue
                            )

                            Text(
                                "Drop file here to replace"
                            )
                            .font(
                                .system(
                                    size: 11
                                )
                            )
                            .foregroundColor(
                                .gray
                            )
                        }
                        .frame(
                            maxWidth:
                                .infinity,
                            minHeight:
                                50
                        )

                    } else {

                        ScrollView(
                            .horizontal,
                            showsIndicators:
                                false
                        ) {

                            HStack(
                                spacing: 8
                            ) {

                                ForEach(
                                    viewModel
                                        .storedFiles,
                                    id:
                                        \.self
                                ) { url in

                                    HStack(
                                        spacing: 5
                                    ) {

                                        Image(
                                            systemName:
                                                "doc.fill"
                                        )
                                        .font(
                                            .system(
                                                size: 12
                                            )
                                        )
                                        .foregroundColor(
                                            .blue
                                        )

                                        Text(
                                            url
                                                .lastPathComponent
                                        )
                                        .font(
                                            .system(
                                                size: 11,
                                                weight:
                                                    .medium
                                            )
                                        )
                                        .foregroundColor(
                                            .white
                                        )
                                        .lineLimit(
                                            1
                                        )

                                        Button(
                                            action: {

                                                viewModel
                                                    .removeFile(
                                                        url
                                                    )
                                            }
                                        ) {

                                            Image(
                                                systemName:
                                                    "xmark.circle.fill"
                                            )
                                            .font(
                                                .system(
                                                    size: 11
                                                )
                                            )
                                            .foregroundColor(
                                                .gray
                                            )
                                        }
                                        .buttonStyle(
                                            .plain
                                        )
                                    }
                                    .padding(
                                        .horizontal,
                                        8
                                    )
                                    .padding(
                                        .vertical,
                                        6
                                    )
                                    .background(
                                        Color.white
                                            .opacity(0.12)
                                    )
                                    .cornerRadius(
                                        8
                                    )
                                    .onDrag {

                                        NSItemProvider(
                                            object:
                                                url as NSURL
                                        )
                                    }
                                }
                            }
                            .padding(
                                .horizontal,
                                6
                            )
                        }
                        .frame(
                            height: 50
                        )
                    }
                }
                .frame(
                    maxWidth:
                        .infinity
                )
                .padding(
                    .vertical,
                    2
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: 10
                    )
                    .fill(
                        windowManager
                            .isFileDragging
                        ? Color.blue
                            .opacity(0.2)
                        : Color.white
                            .opacity(0.08)
                    )
                )
            }
            .frame(
                width: 320,
                alignment: .top
            )
            .padding(
                .horizontal,
                14
            )
            .padding(
                .bottom,
                12
            )
            .scaleEffect(
                isExpandedState
                ? 1.0
                : 0.96,
                anchor:
                    .top
            )
            .opacity(
                isExpandedState
                ? 1.0
                : 0.0
            )
            .animation(
                .easeInOut(
                    duration: 0.20
                ),
                value:
                    isExpandedState
            )
            .allowsHitTesting(
                isExpandedState
            )
        }

        .frame(
            width:
                NotchMetrics
                    .dragHitboxSize
                    .width,

            height:
                NotchMetrics
                    .dragHitboxSize
                    .height,

            alignment:
                .top
        )
        .background(
            Color.clear
        )

        .onAppear {

            windowManager
                .setPinned(
                    viewModel.isPinned
                )

            if windowManager.isExpanded {

                windowManager
                    .setVisualExpansion(
                        true
                    )
            }
        }

        .onChange(
            of:
                viewModel.isPinned
        ) { newValue in

            windowManager
                .setPinned(
                    newValue
                )
        }

        .onChange(
            of:
                windowManager.clearTrigger
        ) { _ in

            viewModel
                .storedFiles
                .removeAll()
        }
    }
}