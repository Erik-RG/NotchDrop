import Cocoa
import SwiftUI
import MediaPlayer

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let viewModel = NotchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = NotchContentView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 90)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = hostingView
        window.isReleasedWhenClosed = false

        positionWindowAtTopEdge()
        window.makeKeyAndOrderFront(nil)

        viewModel.startMonitoring()
    }

    private func positionWindowAtTopEdge() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let width: CGFloat = 420
        let height: CGFloat = 90
        let x = screenFrame.midX - (width / 2)
        let y = screenFrame.maxY - height - 20

        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}