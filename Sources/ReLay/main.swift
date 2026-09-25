import Foundation
import AppKit
import ReLayCore

Logger.log("bootstrapping runtime", subsystem: "startup")
Logger.setupCrashHandling()

// Single instance enforcement
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.relay.app"
let runningApps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
if runningApps.count > 1 {
    Logger.log("another instance of ReLay is already running, terminating", subsystem: "startup")
    // Try to activate the other one? No, just quit.
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = WindowRuntime()
    private var statusItem: NSStatusItem?
    private var isInterceptionDisabled = false
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("application did finish launching", subsystem: "startup")

        ReLaySettings.migrateEnableAutoLayoutV4IfNeeded()
        setupMenuBar()
        checkAccessibilityAndStart()
        checkConflicts()
        setupWindowObservers()

        NotificationCenter.default.addObserver(self, selector: #selector(toggleInterception), name: NSNotification.Name("ReLayEmergencyStop"), object: nil)
        NotificationCenter.default.addObserver(forName: ReLaySettings.interceptionToggled, object: nil, queue: .main) { [weak self] note in
            let enabled = note.userInfo?["enabled"] as? Bool ?? true
            if enabled { self?.startRuntime() } else { self?.runtime.stop() }
            self?.updateMenuBarIcon(permitted: true)
        }

        Logger.log("runtime active", subsystem: "startup")
    }

    private func setupWindowObservers() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                let title = window.title
                let ts = ProcessInfo.processInfo.systemUptime
                Logger.log("NSWindow.didBecomeMain: \(title) ts=\(String(format: "%.3f", ts))", subsystem: "input")
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                let title = window.title
                let ts = ProcessInfo.processInfo.systemUptime
                Logger.log("NSWindow.didBecomeKey: \(title) ts=\(String(format: "%.3f", ts))", subsystem: "input")
            }
        }
    }

    private func checkAccessibilityAndStart() {
        if AccessibilityBootstrap.isGranted() {
            updateMenuBarIcon(permitted: true)
            startRuntimeIfInterceptionEnabled()
            return
        }

        // No modal on launch — just register quietly, show a warning icon,
        // and start once the user enables Accessibility in System Settings.
        updateMenuBarIcon(permitted: false)
        AccessibilityBootstrap.registerSilently()
        Logger.log("accessibility not granted — waiting silently", subsystem: "startup")
        AccessibilityBootstrap.startPolling { [weak self] in
            self?.updateMenuBarIcon(permitted: true)
            self?.startRuntimeIfInterceptionEnabled()
        }
    }

    private func startRuntimeIfInterceptionEnabled() {
        guard ReLaySettings.interceptionEnabled else {
            Logger.log("gesture interception paused in settings — not starting capture", subsystem: "startup")
            return
        }
        startRuntime()
    }

    private func startRuntime() {
        do {
            Logger.log("starting window runtime", subsystem: "startup")
            try self.runtime.start()
            Logger.log("window runtime started", subsystem: "startup")
        } catch {
            Logger.log("failed to start window runtime: \(error)", subsystem: "startup")
        }
    }

    private func checkConflicts() {
        let conflicts = AccessibilityBootstrap.checkForConflictingApps()
        if !conflicts.isEmpty {
            Logger.log("conflicting window managers detected: \(conflicts.joined(separator: ", "))", subsystem: "startup")
        }
    }

    // MARK: - Accessibility permission flow

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateMenuBarIcon(permitted: Bool) {
        let symbolName = permitted ? "rectangle.3.group" : "exclamationmark.triangle"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ReLay")
        img?.isTemplate = true
        statusItem?.button?.image = img
        statusItem?.button?.toolTip = permitted
            ? "ReLay — active"
            : "ReLay — accessibility access required"
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.log("application will terminate", subsystem: "startup")
        self.runtime.stop()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "ReLay")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Layout Library", action: #selector(openExpose), keyEquivalent: " "))
        menu.addItem(menuItem(title: "Save Current Layout…", action: #selector(saveCurrentLayout), keyEquivalent: "s"))
        menu.addItem(menuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Grant Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(menuItem(title: "Undo Last Layout", action: #selector(undoLayout), keyEquivalent: "z"))
        menu.addItem(menuItem(title: "Shuffle Layout Windows", action: #selector(shuffleLayout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ReLay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem?.menu = menu
    }

    /// Status-item menus in an accessory app need an explicit target; nil-target
    /// selectors often never reach the AppDelegate.
    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openExpose() {
        LayoutLibrary.shared.present(triggerWindow: getFrontmostWindow())
    }

    @objc private func openPreferences() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func undoLayout() {
        Logger.log("undo layout requested", subsystem: "ui")
    }

    @objc private func shuffleLayout() {
        Logger.log("shuffle layout requested", subsystem: "ui")
    }

    @objc private func saveCurrentLayout() {
        LayoutLibrary.shared.promptSaveCurrentFromMenu()
    }

    private static let recentItemTag = 42

    @objc private func applyRecentLayout(_ sender: NSMenuItem) {
        guard let templateID = sender.representedObject as? String else { return }
        LayoutLibrary.shared.quickApply(templateID: templateID, triggerWindow: getFrontmostWindow())
    }

    @objc private func toggleInterception() {
        isInterceptionDisabled.toggle()
        if isInterceptionDisabled {
            self.runtime.stop()
            Logger.log("interception disabled via kill-switch", subsystem: "startup")
        } else {
            startRuntime()
            Logger.log("interception re-enabled", subsystem: "startup")
        }
    }

    private func getFrontmostWindow() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success {
            return (ref as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let list = ref as? [AXUIElement], !list.isEmpty {
            return list[0]
        }
        return nil
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Remove stale recent-layout items from previous open
        for item in menu.items.filter({ $0.tag == AppDelegate.recentItemTag }) {
            menu.removeItem(item)
        }

        // Inject fresh recent layouts at the top (max 4, de-duped)
        let recents = LayoutLibrary.shared.recentMenuItems()
        for (i, entry) in recents.enumerated() {
            let item = NSMenuItem(title: entry.name,
                                  action: #selector(applyRecentLayout(_:)),
                                  keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.tag = AppDelegate.recentItemTag
            item.representedObject = entry.id
            menu.insertItem(item, at: i)
        }
        if !recents.isEmpty {
            let sep = NSMenuItem.separator()
            sep.tag = AppDelegate.recentItemTag
            menu.insertItem(sep, at: recents.count)
        }

        let needsAccessibility = !AccessibilityBootstrap.isGranted()
        menu.item(withTitle: "Grant Accessibility…")?.isHidden = !needsAccessibility
        menu.item(withTitle: "Undo Last Layout")?.isEnabled = false
        menu.item(withTitle: "Shuffle Layout Windows")?.isEnabled = false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)

Logger.log("starting application loop", subsystem: "startup")

app.run()
