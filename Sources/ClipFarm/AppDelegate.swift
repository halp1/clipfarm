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
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(toggleRecording),
            name: Notification.Name("dev.haelp.clipfarm.toggleRecording"),
            object: nil
        )

        installMainMenu()
        updateMenuBarPresence()

        // Recording starts off, so nothing is captured until you ask for it. Click the
        // menu bar icon to begin.
        Log.info("Ready, waiting for you to start recording")

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

    /// Gives the app a menu so the usual shortcuts work.
    ///
    /// An accessory app shows no menu bar of its own, but the menu still has to exist
    /// for key equivalents to be found. Without it ⌘W and ⌘Q do nothing in the
    /// settings window.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(
            withTitle: "Quit ClipFarm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard editing shortcuts, so the key and folder fields behave normally.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
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
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            // Ask for both buttons, so a right click can open the menu while a left
            // click toggles recording. A menu assigned to the item would take the
            // click before it ever reaches here.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        refreshMenuBar()
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showStatusMenu()
        } else {
            toggleRecording()
        }
    }

    /// Starts or stops recording, and asks for permission the first time.
    @objc func toggleRecording() {
        if CaptureEngine.shared.isRunning {
            Task { await CaptureEngine.shared.stop() }
            return
        }
        Task {
            guard await CaptureEngine.shared.requestPermission() else {
                self.explainMissingPermission()
                self.watchForPermission()
                return
            }
            await CaptureEngine.shared.start()
        }
    }

    /// Pops the menu open for a right click, then detaches it so the next left click
    /// still reaches the button.
    private func showStatusMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        let menu = buildMenu()
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// Builds the right click menu.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let recording = CaptureEngine.shared.isRunning

        // Only say something when there is something to say. The idle state is already
        // shown by the icon, so a line repeating it is noise.
        switch ClipCoordinator.shared.status {
        case .idle:
            break
        case .saving(let stage):
            let entry = NSMenuItem(title: "\(stage)…", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
            menu.addItem(.separator())
        case .finished(let message), .failed(let message):
            let entry = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(
            title: recording ? "Stop recording" : "Start recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let save = NSMenuItem(
            title: "Save clip  \(Preferences.shared.hotkey.displayString)",
            action: #selector(saveClip),
            keyEquivalent: ""
        )
        save.target = self
        save.isEnabled = recording
        menu.addItem(save)

        menu.addItem(.separator())
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

        return menu
    }

    @objc private func refreshMenuBar() {
        guard let statusItem, let button = statusItem.button else { return }

        let recording = CaptureEngine.shared.isRunning
        let saving: Bool
        if case .saving = ClipCoordinator.shared.status { saving = true } else { saving = false }

        let symbol = saving ? "scissors.circle.fill" : "scissors"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipFarm")

        // Red while recording, so the state is readable at a glance.
        //
        // The colour comes from a palette symbol configuration rather than from
        // contentTintColor. A tint only applies to a template image, and a template
        // image is recoloured by the menu bar itself, so the two settings cancel out
        // and the icon stays black either way. Baking the colour into the image is the
        // part that actually works.
        if recording {
            let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            image = image?.withSymbolConfiguration(red)
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.contentTintColor = nil

        button.toolTip = recording
            ? "Recording. Click to stop, right click for more."
            : "Not recording. Click to start."
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
