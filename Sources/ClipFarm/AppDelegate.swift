import AppKit
import SwiftUI
import UserNotifications

/// Runs the app: no dock tile, no window at launch, just the shortcut and the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps stay out of the Dock and the app switcher.
        NSApp.setActivationPolicy(.accessory)

        // Two copies would fight over the shortcut and record the screen twice.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.haelp.clipfarm"
        ).filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            Log.info("ClipFarm is already running, so this copy is stepping aside")
            NSApp.terminate(nil)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: Preferences.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuBar),
            name: ClipCoordinator.statusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuBar),
            name: CaptureEngine.stateChanged,
            object: nil
        )

        // Do this before anything reads the key. An item written by another process
        // makes macOS ask for permission on every read, and rewriting it here hands
        // ownership to ClipFarm.
        KeychainStore.adoptExistingKeyIfNeeded()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        HotkeyManager.shared.start {
            ClipCoordinator.shared.saveClip()
        }

        // A second way in, for a stream deck, a shell script, or a test run:
        //   osascript -e 'do shell script "..."' or any tool that can post this.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(saveClip),
            name: Notification.Name("dev.haelp.clipfarm.saveClip"),
            object: nil
        )

        updateMenuBarPresence()

        Task {
            let granted = await CaptureEngine.shared.requestPermission()
            if granted {
                await CaptureEngine.shared.start()
            } else {
                self.explainMissingPermission()
                self.watchForPermission()
            }
        }

        Log.info("ClipFarm is up, shortcut is \(Preferences.shared.hotkey.displayString)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
    }

    // A click on the app in Finder while it is already running opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func preferencesChanged() {
        updateMenuBarPresence()
    }

    private func updateMenuBarPresence() {
        if Preferences.shared.showMenuBarItem {
            if statusItem == nil { installStatusItem() }
            refreshMenuBar()
        } else if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem!)
            statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "scissors",
            accessibilityDescription: "ClipFarm"
        )
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshMenuBar()
    }

    @objc private func refreshMenuBar() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let status = ClipCoordinator.shared.status
        let statusText: String
        switch status {
        case .idle:
            statusText = CaptureEngine.shared.isRunning
                ? "Holding the last \(durationLabel)"
                : "Not recording"
        case .saving(let stage): statusText = "\(stage)…"
        case .finished(let message): statusText = message
        case .failed(let message): statusText = message
        }
        let statusEntry = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)

        if !CaptureEngine.shared.isRunning {
            menu.addItem(
                withTitle: "Start recording",
                action: #selector(startRecording),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())
        let save = NSMenuItem(
            title: "Save clip  \(Preferences.shared.hotkey.displayString)",
            action: #selector(saveClip),
            keyEquivalent: ""
        )
        save.target = self
        save.isEnabled = CaptureEngine.shared.isRunning
        menu.addItem(save)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClipFarm", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        // A dot on the icon while a clip is being written.
        if case .saving = status {
            statusItem.button?.image = NSImage(
                systemSymbolName: "scissors.circle.fill",
                accessibilityDescription: "ClipFarm is saving"
            )
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "scissors",
                accessibilityDescription: "ClipFarm"
            )
        }
        statusItem.button?.image?.isTemplate = true
    }

    private var durationLabel: String {
        let seconds = Int(Preferences.shared.clipDuration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    @objc func saveClip() {
        ClipCoordinator.shared.saveClip()
    }

    @objc private func startRecording() {
        Task { await CaptureEngine.shared.start() }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "ClipFarm"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Waits for the permission to be switched on in System Settings and starts
    /// recording as soon as it is, so there is no need to relaunch by hand.
    private func watchForPermission() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if CaptureEngine.shared.hasScreenPermission {
                    await CaptureEngine.shared.start()
                    self.refreshMenuBar()
                    return
                }
            }
        }
    }

    private func explainMissingPermission() {
        let alert = NSAlert()
        alert.messageText = "ClipFarm needs permission to record the screen"
        alert.informativeText = """
            Open System Settings, go to Privacy & Security, then Screen & System Audio \
            Recording, and switch on ClipFarm. Clips cannot be captured until you do.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
            NSWorkspace.shared.open(url)
        }
    }
}
