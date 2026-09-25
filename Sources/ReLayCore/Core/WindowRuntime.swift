import Cocoa
import ApplicationServices

// MARK: - Window Runtime
// Orchestrator: receive intent → resolve window → ask policy → call AX.
// No AX logic. No heuristics. No persistence. No singleton.

public final class WindowRuntime: EventTapCaptureDelegate {

    private let capture: EventTapCapture
    private var state:          State  = State()
    private var activeBundleID: String = ""
    private var config:         Config

    private var snapTargetOverlay: NSWindow?
    private let edgeResize = EdgeResizeCoordinator()
    private var edgeResizeActive = false
    private let dividers = DividerSliderController()
    private let autoLayout = AutoLayoutWatcher()

    /// Peer stashed when entering fullscreen — frame is the pre-minimize geometry.
    private struct StashedPeer {
        let window: AXUIElement
        let frame: CGRect
    }

    /// Windows we minimized when entering fullscreen — restored on the way back down.
    private var minimizedForFullscreen: [StashedPeer] = []

    public init(config: Config = .load()) {
        self.config  = config
        self.capture = EventTapCapture()
        setupPreview()
        capture.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadConfig),
            name: ReLaySettings.settingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutLibraryApplied),
            name: .relayLayoutApplied,
            object: nil
        )
    }

    @objc private func reloadConfig() {
        config = Config.load()
        syncAutoLayout()
    }

    @objc private func handleLayoutLibraryApplied() {
        // Long enough that Stage Manager / panel dismiss flicker can't undo Apply.
        autoLayout.suspend(for: 3.0)
    }

    public func start() throws {
        dividers.hideAll()
        try capture.start()
        syncAutoLayout()
    }

    public func stop() {
        capture.stop()
        autoLayout.stop()
        dividers.hideAll()
    }

    private func syncAutoLayout() {
        autoLayout.stop()
        guard ReLaySettings.autoLayoutEnabled else {
            Logger.log("auto-layout watcher off", subsystem: "layout")
            return
        }
        autoLayout.start(
            onApply: { [weak self] windows, frames, screen in
                self?.applyAutoLayout(windows: windows, frames: frames, screen: screen)
            },
            onSolo: { [weak self] window, screen in
                self?.expandToFullscreen(window, on: screen)
            }
        )
        Logger.log("auto-layout watcher on", subsystem: "layout")
    }

    // MARK: - Capture → Reduce → Policy → Execute

    func didReceive(_ intent: WindowIntent) {
        let window: AXUIElement?
        if intent.phase == .began {
            let ts = ProcessInfo.processInfo.systemUptime
            let hitTestWindow = TitleBarHitTest.windowForGesture(at: intent.location)
            let frontmost = AXWindowOps.frontmost()
            window = hitTestWindow ?? frontmost
            let windowTitle = window.flatMap { AXWindowOps.title($0) } ?? "nil"
            let source = hitTestWindow != nil ? "hitTest" : "frontmost"
            Logger.log("gesture began: got window from \(source), title=\(windowTitle) ts=\(String(format: "%.3f", ts))", subsystem: "input")
        } else {
            window = state.activeWindow
        }
        let startFrame: CGRect
        if intent.phase == .began, let window {
            startFrame = AXWindowOps.frame(window) ?? .zero
        } else {
            startFrame = state.startFrame
        }
        // Screen is stable for the gesture — reuse startFrame; do not re-AX every scroll tick.
        let screen = startFrame == .zero ? .zero : Self.usableScreen(containing: startFrame)

        // Read the layout off the screen instead of remembering what we last
        // did: the window may have been moved by hand, resized by its app, or
        // placed by us as somebody else's companion.
        if intent.phase == .began, let window {
            activeBundleID = AXWindowOps.bundleID(for: window)
            state.layout = LayoutFrameResolver.layout(
                matching: startFrame, in: screen, gap: ReLaySettings.layoutPadding
            )
        }
        let allowCenter = intent.phase == .began
            ? Self.visibleWindowCount(on: screen) <= 1
            : state.allowCenter
        let input  = Input(dx: intent.dx, dy: intent.dy,
                           phase: intent.phase, window: window,
                           screenFrame: screen, startFrame: startFrame,
                           allowCenter: allowCenter)
        let prev = state
        state    = reduce(state, input, config: config)
        apply(prev: prev, curr: state)
    }

    @discardableResult
    func didReceiveEdgeResize(_ event: EdgeResizeEvent) -> Bool {
        switch event {
        case .began(let location):
            edgeResizeActive = edgeResize.begin(at: location)
            if edgeResizeActive {
                // Keep auto-layout from retile-fighting while the user is dragging.
                autoLayout.suspendBriefly()
            }
            return edgeResizeActive
        case .changed:
            guard edgeResizeActive else { return false }
            edgeResize.update()
            autoLayout.suspendBriefly()
            return true
        case .ended:
            guard edgeResizeActive else { return false }
            edgeResizeActive = false
            edgeResize.end()
            autoLayout.suspendBriefly()
            return false
        }
    }

    // MARK: - Apply

    private func apply(prev: State, curr: State) {
        if curr.hasCommitted && !prev.hasCommitted {
            // No window left to act on — drop the gesture rather than keeping a
            // committed state that the next gesture would inherit.
            guard let window = curr.activeWindow else {
                dismissPreview(animated: false)
                resetGestureState(preservingLayout: prev.layout, floatingFrame: curr.floatingFrame)
                return
            }

            // Minimize path — send window to dock, never close the app
            if curr.shouldMinimize {
                dismissPreview(animated: false)
                if WindowMutabilityPolicy.decision(for: activeBundleID) == .allow {
                    let screen = curr.startFrame.isEmpty
                        ? .zero
                        : Self.usableScreen(containing: curr.startFrame)
                    // Capture peers before minimize so CG still lists them.
                    let peers = screen == .zero ? [] : otherWindows(excluding: window, on: screen)
                    AXWindowOps.minimize(window)
                    performSnapHaptic()
                    autoLayout.suspendBriefly()
                    dividers.hideAll()
                    if peers.count == 1 {
                        expandToFullscreen(peers[0], on: screen)
                    }
                }
                resetGestureState(preservingLayout: .floating, floatingFrame: curr.floatingFrame)
                return
            }

            commitPreview(to: curr.targetFrame)
            // Only record the new layout if the window was actually moved.
            var committedLayout = prev.layout
            if WindowMutabilityPolicy.decision(for: activeBundleID) == .allow {
                let screen = Self.usableScreen(containing: curr.targetFrame)
                // Snapshot companions before the primary grows — CG/AX matching
                // is more reliable against the pre-fullscreen geometry.
                let peers = Self.shouldMinimizeOthers(from: prev.layout, to: curr.layout)
                    ? otherWindows(excluding: window, on: screen)
                    : []

                AXWindowOps.setFrame(window, curr.targetFrame)
                committedLayout = curr.layout
                performSnapHaptic()
                autoLayout.suspendBriefly()

                if Self.shouldMinimizeOthers(from: prev.layout, to: curr.layout) {
                    dividers.hideAll()
                    minimizedForFullscreen = peers.map { peer in
                        StashedPeer(window: peer, frame: AXWindowOps.frame(peer) ?? .zero)
                    }
                    for peer in peers {
                        let ok = AXWindowOps.minimize(peer)
                        if !ok {
                            Logger.log("minimize peer failed", subsystem: "layout")
                        }
                    }
                    Logger.log(
                        "fullscreen clear: minimized \(peers.count) peer(s) from \(prev.layout)",
                        subsystem: "layout"
                    )
                } else if Self.shouldRestoreMinimized(from: prev.layout, to: curr.layout) {
                    restoreMinimizedCompanions(primary: window, layout: curr.layout, screen: screen)
                } else {
                    applyCompanionLayouts(primary: window, layout: curr.layout, screen: screen)
                }
            }
            resetGestureState(preservingLayout: committedLayout, floatingFrame: curr.floatingFrame)
            return
        }

        if curr.shouldRevert {
            // The gesture never moved the real window — only the overlay — so a
            // revert is a no-op unless something else moved it meanwhile.
            if let window = curr.activeWindow,
               !curr.startFrame.isEmpty,
               WindowMutabilityPolicy.decision(for: activeBundleID) == .allow,
               let live = AXWindowOps.frame(window), live != curr.startFrame {
                AXWindowOps.setFrame(window, curr.startFrame)
            }
            dismissPreview(animated: true)
            resetGestureState(preservingLayout: curr.layout, floatingFrame: curr.floatingFrame)
            return
        }

        guard curr.activeWindow != nil else { return }

        if curr.progress > 0 {
            updatePreview(from: curr.startFrame, to: curr.targetFrame, progress: curr.progress)
        }
    }

    private func performSnapHaptic() {
        guard ReLaySettings.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// After a half/third snap, fill the leftover region with the best companion window.
    private func applyCompanionLayouts(primary: AXUIElement, layout: WindowLayoutState, screen: CGRect) {
        guard screen != .zero else { return }
        guard let companion = bestCompanion(excluding: primary, on: screen) else { return }
        let frames = LayoutFrameResolver.companionFrames(
            for: layout, count: 1, in: screen, gap: ReLaySettings.layoutPadding
        )
        guard let frame = frames.first else { return }
        let height = NSScreen.screens.first?.frame.height ?? 0
        LayoutMotion.apply(
            windows: [companion],
            frames: [frame],
            duration: max(0.2, config.snapDuration * 0.85),
            animated: ReLaySettings.snapAnimateEnabled,
            screenHeight: height
        )
        let delay = ReLaySettings.snapAnimateEnabled ? max(0.1, config.snapDuration * 0.5) : 0.04
        dividers.showLater(between: primary, and: companion, after: delay)
    }

    /// Any swipe that fills the screen should clear the rest of the desk.
    static func shouldMinimizeOthers(from previous: WindowLayoutState, to next: WindowLayoutState) -> Bool {
        next == .fullscreen && previous != .fullscreen
    }

    /// Leaving fill-screen restores the windows we stashed for that enlarge.
    /// First down step is two-thirds, which leaves a ⅓ slot for the companion.
    static func shouldRestoreMinimized(from previous: WindowLayoutState, to next: WindowLayoutState) -> Bool {
        previous == .fullscreen && next != .fullscreen
    }

    /// Unminimize stashed peers. The frontmost fills the leftover slot (if any);
    /// everyone else returns to their pre-minimize frame. Never N-way stack into
    /// a half — that was crushing windows to ~180pt tall.
    private func restoreMinimizedCompanions(
        primary: AXUIElement,
        layout: WindowLayoutState,
        screen: CGRect
    ) {
        let peers = minimizedForFullscreen
        minimizedForFullscreen = []
        guard !peers.isEmpty else {
            applyCompanionLayouts(primary: primary, layout: layout, screen: screen)
            return
        }

        let leftover = LayoutFrameResolver.companionFrames(
            for: layout, count: 1, in: screen, gap: ReLaySettings.layoutPadding
        ).first
        var restored: [AXUIElement] = []
        var restoredFrames: [CGRect] = []

        for (index, peer) in peers.enumerated() {
            let ok = AXWindowOps.unminimize(peer.window)
            if !ok {
                Logger.log("unminimize peer failed", subsystem: "layout")
            }
            let target: CGRect?
            if index == 0, let leftover, AXWindowOps.isWritableFrame(leftover) {
                target = leftover
            } else if AXWindowOps.isWritableFrame(peer.frame) {
                target = peer.frame
            } else {
                target = nil
            }
            if let target {
                restored.append(peer.window)
                restoredFrames.append(target)
            }
        }

        if !restored.isEmpty {
            let height = NSScreen.screens.first?.frame.height ?? 0
            LayoutMotion.apply(
                windows: restored,
                frames: restoredFrames,
                duration: max(0.22, config.snapDuration),
                animated: ReLaySettings.snapAnimateEnabled,
                screenHeight: height
            )
            let placed = restored[0]
            let delay = ReLaySettings.snapAnimateEnabled ? max(0.12, config.snapDuration * 0.55) : 0.05
            dividers.showLater(between: primary, and: placed, after: delay)
        }
        Logger.log(
            "restored \(peers.count) peer(s) after leaving fullscreen → \(layout) (no micro-stack)",
            subsystem: "layout"
        )
    }

    /// Send every other eligible window on `screen` to the Dock / Stage Manager.
    private func minimizeOtherWindows(excluding primary: AXUIElement, on screen: CGRect) {
        for window in otherWindows(excluding: primary, on: screen) {
            AXWindowOps.minimize(window)
        }
    }

    /// All eligible companions on the current Space (front-to-back), excluding `primary`.
    private func otherWindows(excluding primary: AXUIElement, on screen: CGRect) -> [AXUIElement] {
        var primaryPID: pid_t = 0
        AXUIElementGetPid(primary, &primaryPID)
        let primaryFrame = AXWindowOps.frame(primary)
        let excluded = Bundle.main.bundleIdentifier.map { Set([$0]) } ?? []
        let order = WindowServerList.onScreenOrder()
        var result: [AXUIElement] = []

        func appendUnique(_ win: AXUIElement) {
            if result.contains(where: { CFEqual($0, win) }) { return }
            result.append(win)
        }

        for (z, entry) in order.enumerated() {
            if let primaryFrame,
               entry.pid == primaryPID,
               WindowServerList.framesMatch(entry.bounds, primaryFrame) {
                continue
            }
            guard WindowEligibility.isTileableCGEntry(
                pid: entry.pid, bounds: entry.bounds, on: screen
            ) else { continue }
            let bundleID = NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier ?? ""
            let candidate = CompanionSelector.Candidate(
                id: z, frame: entry.bounds, bundleID: bundleID, zOrder: z
            )
            guard CompanionSelector.isEligible(candidate, on: screen, excludingBundleIDs: excluded)
            else { continue }
            if let win = AXWindowOps.window(pid: entry.pid, matching: entry.bounds)
                    ?? AXWindowOps.window(pid: entry.pid, matching: entry.bounds, tolerance: 24),
               !CFEqual(win, primary),
               WindowEligibility.isTileableWindow(win, on: screen) {
                appendUnique(win)
            }
        }

        // Fallback: AX enumeration when CG→AX matching misses Electron / mismatched frames.
        if result.isEmpty {
            for win in AXWindowOps.allVisible() where !CFEqual(win, primary) {
                guard WindowEligibility.isTileableWindow(win, on: screen) else { continue }
                guard let frame = AXWindowOps.frame(win) else { continue }
                var pid: pid_t = 0
                AXUIElementGetPid(win, &pid)
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                let candidate = CompanionSelector.Candidate(
                    id: result.count, frame: frame, bundleID: bundleID, zOrder: result.count
                )
                guard CompanionSelector.isEligible(candidate, on: screen, excludingBundleIDs: excluded)
                else { continue }
                appendUnique(win)
            }
        }
        return result
    }

    /// Frontmost other window on the current Space.
    /// Walks CGWindowList front-to-back and resolves AX only for the winner.
    private func bestCompanion(excluding primary: AXUIElement, on screen: CGRect) -> AXUIElement? {
        otherWindows(excluding: primary, on: screen).first
    }

    /// Dock / Stage Manager: tile 2 windows into halves, 3 into thirds.
    private func applyAutoLayout(windows: [AXUIElement], frames: [CGRect], screen: CGRect) {
        guard windows.count == frames.count else { return }
        dividers.hideAll()

        let height = NSScreen.screens.first?.frame.height ?? 0
        let duration = max(0.22, config.snapDuration)
        LayoutMotion.apply(
            windows: windows,
            frames: frames,
            duration: duration,
            animated: ReLaySettings.snapAnimateEnabled,
            screenHeight: height
        )

        if windows.count >= 2 {
            // Show the divider after the shared settle so it doesn't pop mid-chaos.
            let delay = ReLaySettings.snapAnimateEnabled ? duration * 0.55 : 0.05
            dividers.showLater(between: windows[0], and: windows[1], after: delay)
        }
        _ = screen
    }

    private func expandToFullscreen(_ window: AXUIElement, on screen: CGRect) {
        guard screen != .zero else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard WindowMutabilityPolicy.decision(for: bid) == .allow else { return }
        let frame = LayoutFrameResolver.frame(
            for: .fullscreen, in: screen, gap: ReLaySettings.layoutPadding
        )
        dividers.hideAll()
        let height = NSScreen.screens.first?.frame.height ?? 0
        LayoutMotion.apply(
            windows: [window],
            frames: [frame],
            duration: max(0.22, config.snapDuration),
            animated: ReLaySettings.snapAnimateEnabled,
            screenHeight: height
        )
        Logger.log("expanded solo window to fullscreen", subsystem: "layout")
    }

    private func resetGestureState(preservingLayout layout: WindowLayoutState, floatingFrame: CGRect) {
        state = State()
        state.layout = layout
        state.floatingFrame = floatingFrame
    }

    // MARK: - Screen resolution (NSScreen — not AX)
    // Static so LayoutLibrary can call the single canonical implementation.

    static func usableScreen(containing frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        if frame.isEmpty || frame == .zero {
            return mainUsableScreen()
        }
        let toAX: (NSScreen) -> CGRect = { s in
            CGRect(x: s.frame.minX, y: primary.frame.height - s.frame.minY - s.frame.height,
                   width: s.frame.width, height: s.frame.height)
        }
        let target = NSScreen.screens.max(by: {
            toAX($0).intersection(frame).area < toAX($1).intersection(frame).area
        }) ?? (NSScreen.main ?? primary)
        let vf = target.visibleFrame
        return CGRect(x: vf.minX, y: primary.frame.height - vf.minY - vf.height,
                      width: vf.width, height: vf.height)
    }

    /// Visible frame of the main screen in AX (top-left) coordinates.
    static func mainUsableScreen() -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let target = NSScreen.main ?? primary
        let vf = target.visibleFrame
        return CGRect(
            x: vf.minX,
            y: primary.frame.height - vf.minY - vf.height,
            width: vf.width,
            height: vf.height
        )
    }

    /// Tileable document windows substantially overlapping `screen` (current Space).
    /// Used to decide whether `.center` is offered as a swipe target.
    /// Menu-bar / popup overlays are ignored so they don't block solo-window center.
    static func visibleWindowCount(on screen: CGRect) -> Int {
        guard !screen.isEmpty else { return 0 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return WindowServerList.onScreenOrder().filter { entry in
            guard entry.pid != ownPID else { return false }
            return WindowEligibility.isTileableCGEntry(
                pid: entry.pid, bounds: entry.bounds, on: screen
            )
        }.count
    }

    // MARK: - Preview (AppKit only — no AX)
    // Optional destination silhouette during a swipe ("where it will land").
    // The old morphing ghost that traveled with the gesture is gone — it felt
    // like a second window. Preview is off by default.

    private func setupPreview() {
        snapTargetOverlay = makeOverlay(material: .hudWindow, borderOpacity: 0.35)
    }

    private func makeOverlay(material: NSVisualEffectView.Material, borderOpacity: CGFloat) -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.level = .popUpMenu
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let vfx = NSVisualEffectView()
        vfx.material = material
        vfx.blendingMode = .withinWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = 14
        vfx.layer?.masksToBounds = true
        vfx.layer?.borderWidth = 1.25
        vfx.layer?.borderColor = NSColor.white.withAlphaComponent(borderOpacity).cgColor

        // Soft tint so the destination reads as a hint, not a second window.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        vfx.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: vfx.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: vfx.trailingAnchor),
            tint.topAnchor.constraint(equalTo: vfx.topAnchor),
            tint.bottomAnchor.constraint(equalTo: vfx.bottomAnchor),
        ])

        win.contentView = vfx
        return win
    }

    private func updatePreview(from current: CGRect, to target: CGRect, progress: CGFloat) {
        _ = current
        guard ReLaySettings.snapPreviewEnabled else {
            if snapTargetOverlay?.isVisible == true {
                dismissPreview(animated: false)
            }
            return
        }
        guard progress > 0, let snap = snapTargetOverlay else { return }

        let tgt = axToAppKit(target)
        let peakAlpha: CGFloat = 0.28

        if !snap.isVisible {
            snap.setFrame(tgt, display: false)
            snap.alphaValue = 0
            snap.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                snap.animator().alphaValue = min(peakAlpha, progress * 0.45)
            }
            return
        }

        // Retarget smoothly when the snap slot changes mid-gesture.
        let frameDelta = abs(snap.frame.minX - tgt.minX)
            + abs(snap.frame.minY - tgt.minY)
            + abs(snap.frame.width - tgt.width)
            + abs(snap.frame.height - tgt.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = frameDelta > 8 ? 0.16 : 0.08
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            snap.animator().setFrame(tgt, display: true)
            snap.animator().alphaValue = min(peakAlpha, 0.12 + progress * 0.2)
        }
    }

    private func commitPreview(to frame: CGRect) {
        guard let snap = snapTargetOverlay else { return }

        if !ReLaySettings.snapPreviewEnabled || !ReLaySettings.snapAnimateEnabled {
            dismissPreview(animated: false)
            return
        }

        let tgt = axToAppKit(frame)
        if !snap.isVisible {
            snap.setFrame(tgt, display: true)
            snap.alphaValue = 0.2
            snap.orderFront(nil)
        } else {
            snap.setFrame(tgt, display: true)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = max(0.16, config.snapDuration * 0.85)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            snap.animator().alphaValue = 0
        }, completionHandler: {
            snap.orderOut(nil)
            snap.alphaValue = 0
        })
    }

    private func dismissPreview(animated: Bool) {
        guard let snap = snapTargetOverlay, snap.isVisible || snap.alphaValue > 0 else { return }
        if animated && ReLaySettings.snapAnimateEnabled {
            let dismissDuration = max(0.1, config.snapDuration * 0.5)
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = dismissDuration
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
                    snap.animator().alphaValue = 0
                },
                completionHandler: {
                    snap.orderOut(nil)
                }
            )
        } else {
            snap.alphaValue = 0
            snap.orderOut(nil)
        }
    }

    // Coordinate flip: AX origin (top-left) → AppKit origin (bottom-left)
    private func axToAppKit(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
// NOTE: WindowLayoutState merged into WindowRuntime
import CoreGraphics

// MARK: - Gesture Direction

enum GestureDirection: Hashable {
    case left, right, up, down

    init?(effectiveX: CGFloat, effectiveY: CGFloat) {
        guard effectiveX != 0 || effectiveY != 0 else { return nil }
        if abs(effectiveX) > abs(effectiveY) {
            self = effectiveX > 0 ? .right : .left
        } else {
            // Trackpad scroll deltas: positive Y = fingers moved down → shrink / minimize
            self = effectiveY > 0 ? .down : .up
        }
    }
}

// MARK: - Semantic Layout State

enum WindowLayoutState: Hashable, CaseIterable {
    // Unmanaged — frame does not match any known state
    case floating

    // Full-screen states
    case fullscreen     // 100% width, 100% height
    case center         // ~72% width, centered, full height

    // Left column
    case leftHalf           // 50% left
    case leftTwoThirds      // 67% left — between half and fullscreen
    case leftThird          // 33% left, full height
    case leftTopSixth       // 33% left, top 50%
    case leftBottomSixth    // 33% left, bottom 50%

    // Right column
    case rightHalf          // 50% right
    case rightTwoThirds     // 67% right — between half and fullscreen
    case rightThird         // 33% right, full height
    case rightTopSixth      // 33% right, top 50%
    case rightBottomSixth   // 33% right, bottom 50%
}

// MARK: - Transition Graph

private struct TransitionKey: Hashable {
    let state: WindowLayoutState
    let direction: GestureDirection
}

/// Declarative lookup table: (WindowLayoutState × GestureDirection) → WindowLayoutState.
/// All entries cover 2-finger gestures only. Multi-finger operations are
/// handled as special cases in the reducer.
class LayoutTransitionGraph {

    private var table: [TransitionKey: WindowLayoutState] = [:]

    init() { buildTable() }

    /// - Parameter allowCenter: When false (other windows share the screen),
    ///   swipe targets never land on `.center` — floating/fullscreen jump
    ///   straight between each other. Center remains reachable only for a
    ///   solo window, and exits from an existing center layout still work.
    func nextState(
        from state: WindowLayoutState,
        moving direction: GestureDirection,
        allowCenter: Bool = true
    ) -> WindowLayoutState? {
        let next = table[TransitionKey(state: state, direction: direction)]
        guard !allowCenter, next == .center else { return next }
        // Skip center when tiling with neighbors.
        switch (state, direction) {
        case (.floating, .up):
            return .fullscreen
        default:
            return nil
        }
    }

    private func buildTable() {
        func add(_ from: WindowLayoutState, _ dir: GestureDirection, _ to: WindowLayoutState) {
            table[TransitionKey(state: from, direction: dir)] = to
        }

        // MARK: Horizontal — navigate columns
        for state in [WindowLayoutState.floating, .fullscreen] {
            add(state, .left,  .leftHalf)
            add(state, .right, .rightHalf)
        }
        // Center navigates out to halves in either mode
        add(.center, .left,  .leftHalf)
        add(.center, .right, .rightHalf)
        // Half → third (push further) or cross-side jump (pull back)
        add(.leftHalf,  .left,  .leftThird)
        add(.leftHalf,  .right, .rightHalf)
        add(.rightHalf, .right, .rightThird)
        add(.rightHalf, .left,  .leftHalf)
        // Third → half (pull back; edge resist in other direction)
        add(.leftThird,  .right, .leftHalf)
        add(.rightThird, .left,  .rightHalf)
        // Two-thirds ↔ half / cross
        add(.leftTwoThirds,  .left,  .leftHalf)
        add(.leftTwoThirds,  .right, .rightHalf)
        add(.rightTwoThirds, .right, .rightHalf)
        add(.rightTwoThirds, .left,  .leftHalf)
        // Cross-column: jump sixths across the screen
        add(.leftTopSixth,    .right, .rightTopSixth)
        add(.leftBottomSixth, .right, .rightBottomSixth)
        add(.rightTopSixth,   .left,  .leftTopSixth)
        add(.rightBottomSixth,.left,  .leftBottomSixth)

        // Vertical — floating → center → fullscreen (and wrap)
        // (never enters native macOS fullscreen; fullscreen here = fills usable screen area)
        add(.floating,    .up, .center)
        add(.center,      .up, .fullscreen)
        add(.fullscreen,  .up, .center)
        // Half grows to two-thirds, then to fullscreen
        add(.leftHalf,       .up, .leftTwoThirds)
        add(.rightHalf,      .up, .rightTwoThirds)
        add(.leftTwoThirds,  .up, .fullscreen)
        add(.rightTwoThirds, .up, .fullscreen)
        // Other column/sixth states still jump to fullscreen
        for state in [WindowLayoutState.leftThird, .rightThird,
                      .leftTopSixth, .leftBottomSixth,
                      .rightTopSixth, .rightBottomSixth] {
            add(state, .up, .fullscreen)
        }

        // Vertical — swipe down only ever shrinks, never grows
        // fullscreen → two-thirds → half → third → minimize
        add(.fullscreen,     .down, .leftTwoThirds)
        add(.leftTwoThirds,  .down, .leftHalf)
        add(.rightTwoThirds, .down, .rightHalf)
        add(.center,         .down, .floating)
        add(.leftHalf,       .down, .leftThird)
        add(.rightHalf,      .down, .rightThird)
        // leftThird/rightThird → minimize (handled in reducer, no table entry needed)
        // Sixths collapse to floating
        for state in [WindowLayoutState.leftTopSixth, .leftBottomSixth,
                      .rightTopSixth, .rightBottomSixth] {
            add(state, .down, .floating)
        }
    }
}
