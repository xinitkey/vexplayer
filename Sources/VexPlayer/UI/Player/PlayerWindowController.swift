import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class PlayerUIState {
    var isFullScreen = false
    var editingKeymap = false
    var showLocation = false

    /// Opens the key mapping editor on the schemes of the app really in front (see InstanceSession.refreshForeground).
    func openKeymapEditor(_ session: InstanceSession, newScheme: Bool = false) {
        Task {
            await session.refreshForeground()
            if newScheme { session.createScheme(copyingActive: false) }
            editingKeymap = true
        }
    }
    var showLogs = false
}

/// Keeps one player window per instance.
@MainActor
final class PlayerWindows {
    static let shared = PlayerWindows()
    private var controllers: [String: PlayerWindowController] = [:]

    func show(_ session: InstanceSession) {
        if let c = controllers[session.id] {
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = PlayerWindowController(session: session)
        controllers[session.id] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(_ id: String) {
        controllers[id]?.close()
    }

    fileprivate func didClose(_ id: String) {
        controllers[id] = nil
    }

    var activeSession: InstanceSession? {
        controllers.values.first { $0.window?.isKeyWindow == true }?.session
    }

    /// Tiles every player window on the current screen (multi-instance farming layout).
    func arrange() {
        let windows = controllers.values.compactMap(\.window).filter(\.isVisible)
        guard !windows.isEmpty, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let cols = Int(ceil(sqrt(Double(windows.count))))
        let rows = Int(ceil(Double(windows.count) / Double(cols)))
        let cellW = vf.width / CGFloat(cols), cellH = vf.height / CGFloat(rows)
        for (i, w) in windows.enumerated() {
            let col = i % cols, row = i / cols
            let cell = NSRect(x: vf.minX + CGFloat(col) * cellW, y: vf.maxY - CGFloat(row + 1) * cellH, width: cellW, height: cellH)
            (w.windowController as? PlayerWindowController)?.fit(in: cell.insetBy(dx: 4, dy: 4))
        }
    }
}

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    static let sidebarWidth: CGFloat = 52

    let session: InstanceSession
    let screenView: ScreenView
    let ui = PlayerUIState()
    private var shownSize: (Int, Int) = (0, 0)

    init(session: InstanceSession) {
        self.session = session
        screenView = ScreenView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = session.config.name
        super.init(window: window)
        window.delegate = self

        let host = NSHostingView(rootView: PlayerView(session: session, screen: screenView, ui: ui))
        host.sizingOptions = []
        window.contentView = host

        shownSize = (session.geometry.shownWidth, session.geometry.shownHeight)
        if let screen = NSScreen.main { fit(in: screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.06, dy: screen.visibleFrame.height * 0.06)) }
        window.center()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = session.geometry
            _ = session.fps
            _ = session.state
            _ = session.aimLocked
            _ = session.config.name
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
        apply()
    }

    private func apply() {
        guard let window else { return }
        var title = session.config.name
        if let img = session.image { title += " · \(img.androidVersionName)" }
        if session.state == .running, AppSettings.shared.showFPS { title += " · \(Int(session.fps.rounded())) FPS" }
        if session.state != .running { title += " · \(session.state.label)" }
        window.title = title

        let g = session.geometry
        if (g.shownWidth, g.shownHeight) != shownSize {
            let wasLandscape = shownSize.0 > shownSize.1
            shownSize = (g.shownWidth, g.shownHeight)
            if wasLandscape != g.isLandscape, !ui.isFullScreen { refitAfterRotation() }
        }
        screenView.setCursorCaptured(session.aimLocked && window.isKeyWindow)
    }

    // MARK: Sizing

    private var chromeHeight: CGFloat {
        guard let w = window else { return 28 }
        return w.frame.height - w.contentLayoutRect.height
    }

    private var sidebar: CGFloat { ui.isFullScreen ? 0 : Self.sidebarWidth }

    /// Largest window with the picture's aspect ratio that fits inside `rect`.
    func fit(in rect: NSRect) {
        guard let window else { return }
        let aspect = session.geometry.aspect
        var picH = rect.height - chromeHeight
        var picW = picH * aspect
        if picW + sidebar > rect.width {
            picW = rect.width - sidebar
            picH = picW / aspect
        }
        let size = NSSize(width: (picW + sidebar).rounded(), height: (picH + chromeHeight).rounded())
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func refitAfterRotation() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let old = window.frame
        // Keep roughly the same picture area, centred where the window was.
        let area = (old.width - sidebar) * (old.height - chromeHeight)
        let aspect = session.geometry.aspect
        var picH = sqrt(area / aspect), picW = picH * aspect
        let maxH = vf.height - chromeHeight, maxW = vf.width - sidebar
        if picH > maxH { picH = maxH; picW = picH * aspect }
        if picW > maxW { picW = maxW; picH = picW / aspect }
        var frame = NSRect(x: old.midX - (picW + sidebar) / 2, y: old.midY - (picH + chromeHeight) / 2,
                           width: picW + sidebar, height: picH + chromeHeight)
        frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !ui.isFullScreen else { return frameSize }
        let aspect = session.geometry.aspect
        let current = sender.frame.size
        if abs(frameSize.width - current.width) > abs(frameSize.height - current.height) {
            let picW = max(240, frameSize.width - sidebar)
            return NSSize(width: picW + sidebar, height: (picW / aspect + chromeHeight).rounded())
        } else {
            let picH = max(160, frameSize.height - chromeHeight)
            return NSSize(width: (picH * aspect + sidebar).rounded(), height: picH + chromeHeight)
        }
    }

    // MARK: Window events

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        session.setDisplayVisible(window.occlusionState.contains(.visible))
    }

    func windowDidMiniaturize(_ notification: Notification) { session.setMinimized(true) }
    func windowDidDeminiaturize(_ notification: Notification) { session.setMinimized(false) }

    func windowWillEnterFullScreen(_ notification: Notification) { ui.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { ui.isFullScreen = false }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(screenView)
        session.syncHostClipboard()
        apply()
        Task { await session.refreshForeground() }
    }

    func windowDidResignKey(_ notification: Notification) {
        session.input.releaseAll()
        screenView.setCursorCaptured(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if session.state.isAlive, AppSettings.shared.stopOnWindowClose { session.stop() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        screenView.setCursorCaptured(false)
        session.input.releaseAll()
        session.attachRenderer(nil)
        PlayerWindows.shared.didClose(session.id)
    }
}
