import AppKit
import QuartzCore

/// The Android screen: a CAMetalLayer-backed view that also turns Mac input into touches and keys.
final class ScreenView: NSView {
    let session: InstanceSession
    private(set) var renderer: ScreenRenderer?
    private var trackingArea: NSTrackingArea?
    private(set) var cursorCaptured = false
    private var markedText = ""
    /// Keys whose keyDown went through the Mac text system; their keyUp must not reach Android.
    private var textRoutedKeys = Set<UInt16>()

    /// An Android text field has focus and VexIME is connected: type with the Mac's input source.
    private var textMode: Bool { session.imeConnected && session.textFieldFocused }

    private var input: InputController { session.input }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(session: InstanceSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        renderer = ScreenRenderer(layer: metalLayer)
        renderer?.setVSync(AppSettings.shared.vsync)
        renderer?.flipY = AppSettings.shared.flipFrames
        session.attachRenderer(renderer)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        renderer?.redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Cursor capture (aim mode)

    func setCursorCaptured(_ on: Bool) {
        guard on != cursorCaptured else { return }
        cursorCaptured = on
        if on {
            if let window {
                let center = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: center.x, y: primaryHeight - center.y))
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    // MARK: Mapping

    private func norm(_ event: NSEvent, clamp: Bool = false) -> (u: Double, v: Double)? {
        let p = convert(event.locationInWindow, from: nil)
        return session.geometry.normalized(p, in: bounds.size, clamp: clamp)
    }

    private var pictureSize: CGSize { session.geometry.fitRect(in: bounds.size).size }
    private var pointScale: Double { 1.0 / max(1, Double(pictureSize.width)) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !input.suspended else { return }
        input.mouseDown(button: 0, at: norm(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !input.suspended else { return }
        if cursorCaptured {
            input.mouseMoved(at: nil, dx: event.deltaX, dy: event.deltaY, scale: pointScale)
        } else if let p = norm(event, clamp: true) {
            input.mouseDragged(at: p)
            input.engine.mouseMoved(u: p.u, v: p.v)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseUp(button: 0, at: norm(event, clamp: true))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseDown(button: 1, at: norm(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseUp(button: 1, at: norm(event, clamp: true))
    }

    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func otherMouseDown(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseDown(button: 2, at: norm(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseUp(button: 2, at: norm(event, clamp: true))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !input.suspended else { return }
        input.mouseMoved(at: norm(event), dx: event.deltaX, dy: event.deltaY, scale: pointScale)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !input.suspended else { return }
        if event.hasPreciseScrollingDeltas {
            // Follow the fingers whatever the "natural scrolling" setting is.
            let s: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            input.scroll(precise: true, phase: event.phase, momentum: event.momentumPhase,
                         dx: event.scrollingDeltaX * s, dy: event.scrollingDeltaY * s,
                         at: norm(event), pictureSize: pictureSize)
        } else {
            let s: Double = event.isDirectionInvertedFromDevice ? -1 : 1
            input.scroll(precise: false, phase: [], momentum: [],
                         dx: event.scrollingDeltaX * s, dy: event.scrollingDeltaY * s,
                         at: norm(event), pictureSize: pictureSize)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard !input.suspended else { return }
        let shortcut = !event.modifierFlags.intersection([.control, .command]).isEmpty
        if textMode && !shortcut {
            // Current Mac layout / input method turns the key into text (insertText) or a command (doCommand).
            textRoutedKeys.insert(event.keyCode)
            interpretKeyEvents([event])
            return
        }
        // Android generates its own auto-repeat for held keys.
        if event.isARepeat { return }
        input.keyDown(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard !input.suspended else { return }
        if textRoutedKeys.remove(event.keyCode) != nil { return }
        input.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !input.suspended else { return }
        let flag: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        case 0x37, 0x36: flag = .command
        case 0x39: flag = .capsLock
        default: return
        }
        input.modifierChanged(event.keyCode, down: event.modifierFlags.contains(flag))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, !input.suspended,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        if textMode, event.charactersIgnoringModifiers?.lowercased() == "v",
           let text = NSPasteboard.general.string(forType: .string) {
            session.ime.commit(text)   // straight into the field, no Android clipboard toast
            return true
        }
        if input.commandShortcut(event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Drag & drop (APK / XAPK install, any other file → Download)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        session.state == .running ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        session.install(urls)
        return true
    }
}

// MARK: - Mac text input → VexIME

extension ScreenView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        session.ime.commit(text)
    }

    /// Return, Backspace, arrows, Tab, Esc… arrive here; Android gets the real key.
    override func doCommand(by selector: Selector) {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
        input.tapKey(event.keyCode)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        session.ime.compose(markedText)
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        session.ime.commit(markedText)
        markedText = ""
    }

    func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the Mac candidate window (Pinyin, Kana…) appears: bottom-left of the picture.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let picture = session.geometry.fitRect(in: bounds.size)
        let local = NSRect(x: picture.minX + 24, y: picture.maxY - 48, width: 1, height: 24)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
