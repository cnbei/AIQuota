import AppKit
import SwiftUI

@MainActor
final class PinnedQuotaPanelController: NSObject, NSWindowDelegate {
    static let shared = PinnedQuotaPanelController()

    private var panel: NSPanel?
    private weak var appState: AppState?

    func show(appState: AppState) {
        self.appState = appState
        appState.isQuotaPinned = true
        let panel = ensurePanel(appState: appState)
        panel.contentView = NSHostingView(
            rootView: PopoverPanelView()
                .environmentObject(appState)
        )
        if panel.frame.origin == .zero {
            panel.center()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        appState?.isQuotaPinned = false
    }

    private func ensurePanel(appState: AppState) -> NSPanel {
        if let panel {
            return panel
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L("订阅额度")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        appState?.isQuotaPinned = false
    }
}
