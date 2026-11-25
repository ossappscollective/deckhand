import AppKit
import DeckhandCore
import SwiftUI

/// Keeps the Deckhand window the shape of the picture it shows, in the two cases where that is wanted:
///
///  * `resizeWidth(by:)`: once, when a panel is shown or hidden. The height stays, the left and top edges stay, and the
///    width follows, so the picture keeps its size and no black bars appear beside it.
///  * `lockedAspect`: while only a portrait picture is in the window, dragging an edge or a corner keeps the picture's
///    shape. It is a delegate method that only adjusts the size AppKit is about to apply (`windowWillResize`), so nothing
///    sets the frame during a drag.
///
/// Everything else (a landscape picture, panels open) is left to the window's own resizing.
@MainActor
final class WindowFit {
    /// The detail column of the window, as measured by the view.
    var detailSize: CGSize = .zero
    /// Height of the strip under the picture, when there is one.
    var barHeight: CGFloat = 0
    /// Width over height of the picture while resizing should keep it; nil when resizing is free.
    var lockedAspect: CGFloat?

    private weak var window: NSWindow?
    private var proxy: FitDelegate?
    private var observer: NSObjectProtocol?
    /// What the window has besides the picture, taken when a resize starts.
    private var chrome = CGSize.zero

    func attach(_ window: NSWindow?) {
        guard let window else { return }
        if self.window !== window {
            self.window = window
            proxy = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureChrome() }
            }
        }
        installDelegate(on: window)
    }

    /// Wraps the window's delegate (SwiftUI's) so that it still gets everything it had.
    func installDelegate(on window: NSWindow) {
        if window.delegate === proxy, proxy != nil { return }
        let proxy = FitDelegate(original: window.delegate, fit: self)
        self.proxy = proxy
        window.delegate = proxy
    }

    private func captureChrome() {
        guard let window else { return }
        chrome = CGSize(width: window.frame.width - detailSize.width,
                        height: window.frame.height - (detailSize.height - barHeight))
    }

    /// Changes the width of the window by `delta`, animated, with the top-left corner where it is, and keeps it on the screen.
    func resizeWidth(by delta: CGFloat) {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = max(min(frame.width + delta, visible.width), window.minSize.width)
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        guard abs(frame.width - window.frame.width) > 1 else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    /// The size the window should take instead of `proposed`, so that the picture keeps its shape.
    fileprivate func constrained(_ proposed: NSSize, in window: NSWindow) -> NSSize {
        guard let aspect = lockedAspect, aspect > 0 else { return proposed }
        return WindowSizing.constrained(proposed: proposed, current: window.frame.size, chrome: chrome, bar: barHeight,
                                        aspect: aspect, minimum: window.minSize)
    }
}

/// The window's delegate with one method added; every other message goes to the delegate SwiftUI installed.
@MainActor
private final class FitDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private unowned let fit: WindowFit

    init(original: (any NSWindowDelegate)?, fit: WindowFit) {
        self.original = original
        self.fit = fit
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original as AnyObject?)?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original = original as AnyObject?, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = original?.windowWillResize?(sender, to: frameSize) ?? frameSize
        return fit.constrained(proposed, in: sender)
    }
}

/// Hands the window a view is in to `onWindow`.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowView)?.onWindow = onWindow
        // SwiftUI may have put its own delegate back
        DispatchQueue.main.async { onWindow(view.window) }
    }

    private final class WindowView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }
    }
}
