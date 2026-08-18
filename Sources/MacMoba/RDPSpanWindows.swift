// One borderless window per display for a session that spans them.
//
// A spanning session gets ONE framebuffer covering every screen, so it cannot
// be shown by the single view in the tab. Each screen gets a window covering it
// exactly, holding a view configured with that monitor's rectangle — the same
// framebuffer, sliced.
//
// The tab's own view keeps the primary monitor's slice, so leaving the spanning
// mode needs no reconnection: the session never noticed.

import AppKit
import MacMobaCore

@MainActor
final class RDPSpanWindows {
    private var windows: [NSWindow] = []
    private(set) var views: [RDPContainerView] = []
    private var activationObservers: [NSObjectProtocol] = []

    var isShowing: Bool { !windows.isEmpty }

    /// Opens a window on every screen EXCEPT the one the session's own window is
    /// on, each showing that screen's slice of the desktop.
    ///
    /// `hostDisplayID` is that screen. It is not necessarily the primary: the
    /// MacMoba window can be anywhere, and assuming otherwise put a covering
    /// window on top of the full-screen session while leaving another screen
    /// with nothing at all.
    ///
    /// `lastFrame` is pushed into each new view straight away. Without it the
    /// windows stay BLACK until the server happens to send another frame, and a
    /// desktop that is not changing may not send one for a long time — which
    /// looks exactly like the feature not working.
    func show(monitors: [RDPMonitor], hostDisplayID: UInt32, lastFrame: CGImage?,
              onInput: @escaping (RDPInputEvent) -> Void) {
        hide()
        guard monitors.count > 1 else { return }

        // Driven by the screens that are attached NOW, matched to the layout by
        // display ID. Walking the monitor list instead would open a window for
        // a display that has since been unplugged, and index-matching would
        // open it on the wrong one.
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard id != hostDisplayID else { continue }
            guard let monitor = RDPMonitorLayout.monitor(
                in: monitors, displayID: id,
                screenIndex: NSScreen.screens.firstIndex(of: screen) ?? -1) else { continue }

            let view = RDPContainerView()
            view.onInput = onInput
            view.sourceRect = RDPMonitorLayout.framebufferRect(of: monitor, in: monitors)

            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false,
                                  screen: screen)
            window.contentView = view
            window.backgroundColor = .black
            window.isOpaque = true
            // Above the Dock (level 20) and the menu bar (24). `.floating` is
            // only level 3, which left the Dock drawn on top of the remote
            // desktop — and on the screen where the Dock lives that means on
            // top of the Windows taskbar, so neither one is usable.
            //
            // The screen this window covers is showing a full-screen remote
            // desktop, so covering the Mac's own furniture on it is the point.
            // Only the OTHER screens get one of these; the screen the session's
            // own window is on is handled by AppKit's full screen, which hides
            // the Dock and menu bar itself.
            window.level = .screenSaver
            // `.stationary` keeps Mission Control from sliding it around with
            // the Spaces it is deliberately joining all of.
            window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            // Keyboard stays with the tab's own window: one responder for the
            // session, so keystrokes are not split across screens depending on
            // where the pointer happens to be.
            window.ignoresMouseEvents = false

            if let lastFrame { view.setFrame(lastFrame) }

            windows.append(window)
            views.append(view)
        }
        watchActivation()
    }

    /// Covering the Dock and the menu bar is only acceptable while MacMoba is
    /// the app in front. Switch to something else — ⌘-Tab to a browser on the
    /// second screen — and these windows drop back to an ordinary level so the
    /// Mac is usable again; coming back raises them.
    private func watchActivation() {
        guard activationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLevel(.normal) }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLevel(.screenSaver) }
            },
        ]
    }

    private func setLevel(_ level: NSWindow.Level) {
        for window in windows where window.level != level {
            window.level = level
        }
    }

    func hide() {
        for token in activationObservers { NotificationCenter.default.removeObserver(token) }
        activationObservers.removeAll()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
    }

    /// Push a new frame to every auxiliary screen. Each view crops its own part.
    func setFrame(_ image: CGImage) {
        for view in views { view.setFrame(image) }
    }

    deinit {
        // NSWindow teardown has to happen on the main thread; the windows are
        // already closed by `hide()` on every path that ends a session, and
        // this is only a backstop.
        let leftovers = windows
        Task { @MainActor in
            for window in leftovers { window.orderOut(nil) }
        }
    }
}
