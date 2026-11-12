import AppKit
import SwiftUI

/// Where the panel hangs from: the notch of a built-in display, or the top center of the main screen
/// on a display without one (the same-sized zone in the menu bar acts as the notch).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// The hover zone, in screen coordinates.
    var zone: CGRect
    var hasNotch: Bool

    static func current() -> NotchGeometry? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
            let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        {
            let frame = screen.frame
            let height = screen.safeAreaInsets.top
            let zone = CGRect(
                x: frame.minX + left.width, y: frame.maxY - height,
                width: frame.width - left.width - right.width, height: height)
            return NotchGeometry(screenFrame: frame, zone: zone, hasNotch: true)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let frame = screen.frame
        let height = max(NSStatusBar.system.thickness, frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 200
        return NotchGeometry(
            screenFrame: frame, zone: CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
            hasNotch: false)
    }
}

/// Borderless panels above the menu bar: they never take focus from the app you're in.
private final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
}

/// An invisible view over the notch that reports the cursor entering it.
private final class HoverView: NSView {
    var onEnter: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
}

/// The AppKit host of the notch: two borderless panels above the menu bar (the hover zone and the panel itself),
/// the cursor tracking that opens and closes it, and the panel window following `NotchStore`.
/// All state lives in the store; this only turns it into windows.
@MainActor
final class NotchController {
    private let trigger = NotchPanel()
    private let panel = NotchPanel()
    private let store: NotchStore
    private var geometry: NotchGeometry?
    private var hoverTask: Task<Void, Never>?
    private var watchTimer: Timer?
    private var outsideSince: Date?

    /// How long the cursor rests on the notch before the panel opens, and how long it may be away before it closes.
    private static let openDelay: Duration = .milliseconds(150)
    private static let closeDelay: TimeInterval = 0.35
    static let panelWidth: CGFloat = 440

    /// `content` is the panel's SwiftUI view with its environment already set; its size sizes the window.
    init<Content: View>(store: NotchStore, content: (_ onSize: @escaping (CGSize) -> Void) -> Content) {
        self.store = store
        let hover = HoverView()
        hover.onEnter = { [weak self] in self?.cursorEnteredZone() }
        trigger.contentView = hover
        trigger.ignoresMouseEvents = false

        panel.contentView = NSHostingView(rootView: content { [weak self] size in self?.resizePanel(to: size) })
        store.onOpenRequest = { [weak self] in self?.cursorEnteredZone() }

        layout()
        followVisibility()
        let screensChanged = NSApplication.didChangeScreenParametersNotification
        NotificationCenter.default.addObserver(forName: screensChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    /// Closes the panel right away, e.g. before the main window opens.
    func dismiss() {
        if store.expanded { close() }
    }

    private func layout() {
        geometry = NotchGeometry.current()
        guard let geometry else {
            trigger.orderOut(nil)
            return
        }
        // A few points wider than the notch, so the cursor finds it easily.
        trigger.setFrame(geometry.zone.insetBy(dx: -12, dy: 0), display: false)
        trigger.orderFrontRegardless()
        store.notchWidth = geometry.zone.width
        store.notchHeight = geometry.zone.height
        store.hasNotch = geometry.hasNotch
        // Until SwiftUI has laid the panel out once it reports no size; start it at the notch's,
        // so the first open shows a real window that then grows to the content.
        resizePanel(to: panel.frame.size == .zero ? geometry.zone.size : panel.frame.size)
    }

    /// Shows the panel window while the store has something to draw, and takes it down a moment after
    /// (so the collapse animation can finish).
    private func followVisibility() {
        withObservationTracking {
            _ = store.isVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.store.isVisible {
                    self.panel.orderFrontRegardless()
                } else {
                    try? await Task.sleep(for: .milliseconds(220))
                    if !self.store.isVisible { self.panel.orderOut(nil) }
                }
                self.followVisibility()
            }
        }
    }

    private func cursorEnteredZone() {
        guard !store.expanded else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            guard let self, !Task.isCancelled, let geometry = self.geometry else { return }
            let mouse = NSEvent.mouseLocation
            // The alert pill is wider than the notch; resting on it opens the panel too.
            let onPill = self.store.alert != nil && self.panel.isVisible && self.panel.frame.contains(mouse)
            if geometry.zone.insetBy(dx: -12, dy: -2).contains(mouse) || onPill { self.open() }
        }
    }

    private func open() {
        store.expand()
        startWatching()
    }

    private func close() {
        watchTimer?.invalidate()
        watchTimer = nil
        outsideSince = nil
        store.collapse()
    }

    /// Polls the cursor while open. The timer runs in the default run loop mode only, so it pauses while a menu
    /// from the panel (the account picker) is open and the panel never closes under it.
    private func startWatching() {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCursor() }
        }
        RunLoop.main.add(timer, forMode: .default)
        watchTimer = timer
    }

    private func checkCursor() {
        // Collapsed from inside (a session row, "Open"): stop watching.
        guard store.expanded else { return close() }
        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) || trigger.frame.contains(mouse)
        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > Self.closeDelay { close() }
        } else {
            outsideSince = Date()
        }
    }

    /// Keeps the panel's top edge on the screen's top edge, centered on the notch.
    private func resizePanel(to size: CGSize) {
        guard let geometry, size.width > 0, size.height > 0 else { return }
        let frame = CGRect(
            x: geometry.zone.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
            width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}
