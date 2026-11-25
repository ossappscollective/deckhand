import AppKit

/// The thumbnail macOS shows in the bottom-right corner after a screenshot: it slides in, goes away by itself (or when
/// swiped to the right), and can be dragged into any app or folder as the file it is. Click it to open the file;
/// right-click for Save, Show in Finder, Copy and Delete. The file lives in a temporary folder, and is saved to the
/// capture folder only on request. Apple's own screenshot tool has no way to be started with a picture, so this stands in
/// for it.
@MainActor
final class ScreenshotThumbnail {
    static let shared = ScreenshotThumbnail()

    private static let width: CGFloat = 176
    private static let margin: CGFloat = 20
    private static let lifetime: Duration = .seconds(6)

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(path: String) {
        guard let image = NSImage(contentsOfFile: path), let screen = NSScreen.main else { return }
        close(animated: false)

        let ratio = image.size.height / max(image.size.width, 1)
        // a tall phone screenshot stays a small, tall card, a landscape one a wide card
        let size = NSSize(width: Self.width, height: min(max(Self.width * ratio, 90), 260))
        let content = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: image, path: path)
        content.onClose = { [weak self] in self?.close(animated: true) }
        content.onHover = { [weak self] hovering in self?.hover(hovering) }

        let visible = screen.visibleFrame
        let resting = NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: visible.maxX, y: resting.y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: resting, size: size), display: true)
        }
        scheduleDismissal()
    }

    private func hover(_ hovering: Bool) {
        if hovering { dismissal?.cancel() } else { scheduleDismissal() }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.close(animated: true)
        }
    }

    private func close(animated: Bool) {
        dismissal?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated, let screen = panel.screen ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            var gone = panel.frame
            gone.origin.x = screen.visibleFrame.maxX
            panel.animator().setFrame(gone, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let image: NSImage
    private let path: String
    private let closeButton = NSButton()
    private var pressed: NSPoint?
    private var dragging = false
    private var swiped: CGFloat = 0

    init(frame: NSRect, image: NSImage, path: String) {
        self.image = image
        self.path = path
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let background = NSVisualEffectView(frame: bounds)
        background.material = .hudWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        let picture = NSImageView(frame: bounds.insetBy(dx: 6, dy: 6))
        picture.image = image
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.autoresizingMask = [.width, .height]
        addSubview(picture)

        closeButton.frame = NSRect(x: 8, y: bounds.height - 30, width: 22, height: 22)
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = true
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.autoresizingMask = [.minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHover?(false)
    }

    @objc private func close() { onClose?() }

    override func mouseDown(with event: NSEvent) {
        pressed = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = pressed else { return }
        let here = event.locationInWindow
        guard hypot(here.x - start.x, here.y - start.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard !dragging else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        onClose?()
    }

    /// A two-finger swipe to the right sends it away, as the system's thumbnail does.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase != [] || event.momentumPhase != [] else { return }
        if event.phase.contains(.began) { swiped = 0 }
        swiped += event.scrollingDeltaX
        if swiped > 60 {
            swiped = 0
            onClose?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("Open", #selector(open)))
        menu.addItem(item("Save to \((Preferences.captureDirectory as NSString).lastPathComponent)", #selector(save)))
        menu.addItem(item("Show in Finder", #selector(reveal)))
        menu.addItem(item("Copy", #selector(copyImage)))
        menu.addItem(.separator())
        menu.addItem(item("Move to Trash", #selector(trash)))
        menu.addItem(item("Close", #selector(close)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func open() { NSWorkspace.shared.open(URL(fileURLWithPath: path)); onClose?() }
    /// Copies the file to the capture folder, where the plain screenshots go.
    @objc private func save() {
        let target = URL(fileURLWithPath: Preferences.captureDirectory).appendingPathComponent((path as NSString).lastPathComponent)
        try? FileManager.default.copyItem(atPath: path, toPath: target.path)
        NSWorkspace.shared.activateFileViewerSelecting([target])
        onClose?()
    }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); onClose?() }
    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    @objc private func trash() {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        onClose?()
    }

    // The file is copied where it is dropped; it stays where it was saved.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onClose?() }
    }
}
