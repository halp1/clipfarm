import AppKit

// ClipFarm has no main window and no storyboard, so the delegate is wired up by hand.
// This runs on the main thread before the run loop starts, which is what the delegate
// expects, so the isolation check here is safe to state outright.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
