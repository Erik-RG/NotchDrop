import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let viewModel = NotchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = NotchContentView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: NSScreen.main?.frame.width ?? 1440, height: 120)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: NSScreen.main?.frame.height ?? 900 - 120, width: NSScreen.main?.frame.width ?? 1440, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false

        positionWindowAsNotch()
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.accessory)

        viewModel.startMonitoring()
    }

    private func positionWindowAsNotch() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let notchHeight: CGFloat = 120
        let x: CGFloat = 0
        let y = screenFrame.height - notchHeight

        window.setFrame(NSRect(x: x, y: y, width: screenFrame.width, height: notchHeight), display: true)
    }
}
