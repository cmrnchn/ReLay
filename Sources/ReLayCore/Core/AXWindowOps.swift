import Cocoa
import ApplicationServices
import Accessibility

// MARK: - AXWindowOps
// Raw AX read/write primitives only.
// No system queries (NSScreen). No UI logic. No animation. No decisions.

enum AXWindowOps {

    // MARK: - Read

    static func frame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute     as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef  as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize,  &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func title(_ window: AXUIElement) -> String {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success,
           let t = ref as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        return "Window"
    }

    static func frontmost() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success {
            let window = (ref as! AXUIElement)
            let title = Self.title(window)
            Logger.log("frontmost() via focusedWindow: \(title)", subsystem: "input")
            return window
        }
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let list = ref as? [AXUIElement], let first = list.first {
            let title = Self.title(first)
            Logger.log("frontmost() via firstWindow: \(title)", subsystem: "input")
            return first
        }
        Logger.log("frontmost() returned nil", subsystem: "input")
        return nil
    }

    /// Topmost *standard* AX window under a global point (Quartz / AX top-left).
    /// Dialogs / floating panels are skipped so gestures and edge-resize never
    /// latch onto menu-bar dropdowns or popups.
    static func window(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success,
        let start = element
        else { return nil }
        let hit = enclosingWindow(startingAt: start)
        if let hit, isStandardWindow(hit) { return hit }
        // Hit landed on a sheet/popover — prefer the app's front standard window.
        if let hit { return standardWindowNear(hit) }
        return nil
    }

    /// Resolve an AX window for a window-server entry (pid + bounds).
    /// Cheaper than `allVisible()` when you already know which window you want.
    static func window(pid: pid_t, matching bounds: CGRect, tolerance: CGFloat = 4) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement]
        else { return nil }
        for win in list where isStandardWindow(win) {
            guard let f = frame(win), WindowServerList.framesMatch(f, bounds, tolerance: tolerance)
            else { continue }
            return win
        }
        return nil
    }

    static func bundleID(for window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    static func allVisible() -> [AXUIElement] {
        var result: [AXUIElement] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let list = ref as? [AXUIElement] else { continue }
            result.append(contentsOf: list.filter(isStandardWindow))
        }
        return result
    }

    private static func enclosingWindow(startingAt start: AXUIElement) -> AXUIElement? {
        var current = start
        for _ in 0..<32 {
            if string(current, kAXRoleAttribute) == (kAXWindowRole as String) {
                return current
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef
            else { return nil }
            current = (parentRef as! AXUIElement)
        }
        return nil
    }

    /// `kAXWindows` also returns things that are not user-movable windows —
    /// most notably Finder's desktop, which is an `AXScrollArea` the size of
    /// the whole display and therefore beats every real window on area.
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) == (kAXWindowRole as String) else { return false }
        let subrole = string(window, kAXSubroleAttribute)
        // Explicitly reject dialogs / floating panels even if some apps mislabel.
        if subrole == (kAXDialogSubrole as String)
            || subrole == (kAXFloatingWindowSubrole as String)
            || subrole == "AXSystemDialog" {
            return false
        }
        guard subrole == (kAXStandardWindowSubrole as String) else { return false }
        return bool(window, kAXMinimizedAttribute) != true
    }

    /// `nil` when AX does not expose the attribute (treat as unknown / allow).
    static func isResizable(_ window: AXUIElement) -> Bool? {
        bool(window, "AXResizable")
    }

    private static func standardWindowNear(_ window: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement]
        else { return nil }
        return list.first(where: isStandardWindow)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? Bool
    }

    // MARK: - Write

    /// Absolute floor for any AX size write. Stacking many companions into one
    /// half previously produced ~180pt strips — refuse anything that small.
    static let minWritableWidth: CGFloat = 320
    static let minWritableHeight: CGFloat = 280

    static func isWritableFrame(_ rect: CGRect) -> Bool {
        rect.width >= minWritableWidth && rect.height >= minWritableHeight
    }

    /// - Parameter prepareApp: When false, skips the EUI disable probe — caller
    ///   must have already called `disableEnhancedUserInterface` for this app
    ///   (e.g. once at the start of a linked-resize session).
    @discardableResult
    static func setFrame(_ window: AXUIElement, _ rect: CGRect, prepareApp: Bool = true) -> Bool {
        guard isWritableFrame(rect) else {
            Logger.log(
                "refusing undersized frame \(Int(rect.width))x\(Int(rect.height))",
                subsystem: "layout"
            )
            return false
        }

        // AXEnhancedUserInterface makes the window server *animate* AX frame
        // writes. The size/position/size sequence below then races its own
        // animation and the window lands somewhere else. Every window manager
        // turns it off before writing; so do we.
        if prepareApp { disableEnhancedUserInterface(owning: window) }

        var pos = rect.origin, size = rect.size
        guard let posV  = AXValueCreate(.cgPoint, &pos),
              let sizeV = AXValueCreate(.cgSize,  &size) else { return false }
        let r1 = AXUIElementSetAttributeValue(window, kAXSizeAttribute     as CFString, sizeV)
        let r2 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posV)
        let r3 = AXUIElementSetAttributeValue(window, kAXSizeAttribute     as CFString, sizeV)
        return r1 == .success && r2 == .success && r3 == .success
    }

    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    static func disableEnhancedUserInterface(owning window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        let axApp = AXUIElementCreateApplication(pid)
        guard bool(axApp, enhancedUserInterfaceAttribute) == true else { return }
        AXUIElementSetAttributeValue(
            axApp,
            enhancedUserInterfaceAttribute as CFString,
            false as CFTypeRef
        )
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let sizeV = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeV) == .success
    }

    @discardableResult
    static func minimize(_ window: AXUIElement) -> Bool {
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef) == .success
    }

    @discardableResult
    static func unminimize(_ window: AXUIElement) -> Bool {
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef) == .success
    }
}
