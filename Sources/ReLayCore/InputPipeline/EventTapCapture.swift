import AppKit
import ApplicationServices

// MARK: - Output contract

struct WindowIntent {
    enum Phase { case began, changed, ended, cancelled }
    let dx:       CGFloat
    let dy:       CGFloat
    let phase:    Phase
    let location: CGPoint
}

enum EdgeResizeEvent {
    case began(location: CGPoint)
    case changed
    case ended
}

// MARK: - Delegate

protocol EventTapCaptureDelegate: AnyObject {
    func didReceive(_ intent: WindowIntent)
    /// For `.began`, return true only when a linked-resize session started so
    /// drag/up events can be ignored for ordinary clicks.
    @discardableResult
    func didReceiveEdgeResize(_ event: EdgeResizeEvent) -> Bool
}

// MARK: - Capture
// Title-bar swipes use a global NSEvent scroll monitor. Edge-resize uses
// global mouse monitors. A CGEvent tap is intentionally not used for scroll:
// pairing tap + monitor double-delivered `.began` and reset the reducer mid-gesture.

final class EventTapCapture {
    weak var delegate: EventTapCaptureDelegate?

    private var scrollMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var localMouseMonitor: Any?
    private var isRunning = false
    private var titleBarGestureActive = false
    private var edgeResizeListening = false

    func start() throws {
        guard AXIsProcessTrusted() else {
            Logger.log("input capture: accessibility not granted", subsystem: "input")
            throw CaptureError.accessibilityNotGranted
        }
        installScrollMonitor()
        installMouseMonitors()
        isRunning = true
        Logger.log("input capture started", subsystem: "input")
    }

    func stop() {
        isRunning = false
        titleBarGestureActive = false
        edgeResizeListening = false
        removeScrollMonitor()
        removeMouseMonitors()
        Logger.log("input capture stopped", subsystem: "input")
    }

    // MARK: - Monitors

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollNSEvent(event)
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private func installMouseMonitors() {
        // Global: other apps. Local: ReLay's own windows (global monitors skip those).
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleGlobalMouse(type: .leftMouseDown, event: event)
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleGlobalMouse(type: .leftMouseDragged, event: event)
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleGlobalMouse(type: .leftMouseUp, event: event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.handleGlobalMouse(type: .leftMouseDown, event: event)
            case .leftMouseDragged:
                self.handleGlobalMouse(type: .leftMouseDragged, event: event)
            case .leftMouseUp:
                self.handleGlobalMouse(type: .leftMouseUp, event: event)
            default:
                break
            }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let mouseDragMonitor { NSEvent.removeMonitor(mouseDragMonitor) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseDownMonitor = nil
        mouseDragMonitor = nil
        mouseUpMonitor = nil
        localMouseMonitor = nil
    }

    // MARK: - Event handling

    private func handleGlobalMouse(type: CGEventType, event: NSEvent) {
        let location = axLocation(from: event)
        switch type {
        case .leftMouseDown:
            edgeResizeListening = delegate?.didReceiveEdgeResize(.began(location: location)) == true

        case .leftMouseDragged:
            guard edgeResizeListening else { return }
            _ = delegate?.didReceiveEdgeResize(.changed)

        case .leftMouseUp:
            guard edgeResizeListening else { return }
            edgeResizeListening = false
            _ = delegate?.didReceiveEdgeResize(.ended)

        default:
            break
        }
    }

    private func handleScrollNSEvent(_ nsEvent: NSEvent) {
        guard isRunning, let phase = scrollPhase(from: nsEvent) else { return }

        let location = axLocation(from: nsEvent)

        switch phase {
        case .began:
            // A duplicate began mid-gesture would zero the reducer — ignore it.
            if titleBarGestureActive { return }
            guard TitleBarHitTest.isGestureAllowed(at: location) else {
                Logger.log("scroll began rejected at (\(Int(location.x)),\(Int(location.y)))", subsystem: "input")
                return
            }
            titleBarGestureActive = true
            let ts = ProcessInfo.processInfo.systemUptime
            Logger.log("scroll began allowed at (\(Int(location.x)),\(Int(location.y))) ts=\(String(format: "%.3f", ts))", subsystem: "input")

        case .changed:
            guard titleBarGestureActive else { return }

        case .ended, .cancelled:
            guard titleBarGestureActive else { return }
            titleBarGestureActive = false
            Logger.log("scroll \(phase == .ended ? "ended" : "cancelled")", subsystem: "input")
        }

        delegate?.didReceive(WindowIntent(
            dx: CGFloat(nsEvent.scrollingDeltaX),
            dy: CGFloat(nsEvent.scrollingDeltaY),
            phase: phase,
            location: location
        ))
    }

    /// Map trackpad scroll phases from CGEvent fields, with NSEvent fallback.
    private func scrollPhase(from nsEvent: NSEvent) -> WindowIntent.Phase? {
        if let cg = nsEvent.cgEvent {
            let momentum = cg.getIntegerValueField(.scrollWheelEventMomentumPhase)
            // Momentum start/end ends the finger gesture for our purposes.
            // CGMomentumScrollPhase: none=0, begin=1, continue=2, end=3
            if momentum != 0 {
                if titleBarGestureActive, momentum == 1 || momentum == 3 {
                    return .ended
                }
                return nil
            }

            let raw = cg.getIntegerValueField(.scrollWheelEventScrollPhase)
            // kCGScrollPhase*: Began=1, Changed=2, Ended=4, Cancelled=8, MayBegin=128
            if raw & 1 != 0 { return .began }
            if raw & 2 != 0 { return .changed }
            if raw & 4 != 0 { return .ended }
            if raw & 8 != 0 { return .cancelled }
        }

        let momentum = nsEvent.momentumPhase
        if !momentum.isEmpty {
            if titleBarGestureActive, momentum.contains(.began) || momentum.contains(.ended) {
                return .ended
            }
            return nil
        }

        if let mapped = nsEvent.phase.asWindowIntentPhase {
            return mapped
        }

        // Global monitors sometimes strip phase on intermediate ticks.
        if titleBarGestureActive, nsEvent.hasPreciseScrollingDeltas {
            if abs(nsEvent.scrollingDeltaX) > 0.1 || abs(nsEvent.scrollingDeltaY) > 0.1 {
                return .changed
            }
        }
        return nil
    }

    /// Global display point in AX / top-left space.
    private func axLocation(from event: NSEvent) -> CGPoint {
        if let loc = event.cgEvent?.location {
            return loc
        }
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    enum CaptureError: Error {
        case accessibilityNotGranted
        case tapCreationFailed
    }
}

private extension NSEvent.Phase {
    var asWindowIntentPhase: WindowIntent.Phase? {
        // Phase is an OptionSet — use contains, not exact equality.
        if contains(.began) { return .began }
        if contains(.ended) { return .ended }
        if contains(.cancelled) { return .cancelled }
        if contains(.changed) { return .changed }
        return nil
    }
}
