// Crumb: a tiny clipboard history for macOS. Press ⇧⌘C anywhere to see everything you copied.

import AppKit
import Carbon
import ServiceManagement

enum Defaults {
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let historySize = "historySize"
    static let checkForUpdates = "checkForUpdates"
    static let launchedBefore = "launchedBefore"
    static let launchAtLogin = "launchAtLogin"
}

private func dataDirectory() -> String {
    if let custom = ProcessInfo.processInfo.environment["CRUMB_DATA"], !custom.isEmpty { return custom }
    let support = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
    return support + "/Crumb"
}

private func installedInApplications() -> Bool {
    let path = Bundle.main.bundlePath
    return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var clipboard: Clipboard?
    @objc private(set) var popup: Popup?
    private var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Defaults.hotKeyCode: kVK_ANSI_C,
            Defaults.hotKeyModifiers: cmdKey | shiftKey,
            Defaults.historySize: 100,
            Defaults.checkForUpdates: true,
            Defaults.launchAtLogin: true,
        ])

        let store = Store(directory: dataDirectory())
        store.setLimit(max(1, defaults.integer(forKey: Defaults.historySize)))
        store.load()
        let clipboard = Clipboard(store: store)
        let popup = Popup(store: store, clipboard: clipboard)
        let updater = Updater(popup: popup)
        popup.updater = updater
        (self.store, self.clipboard, self.popup, self.updater) = (store, clipboard, popup, updater)

        clipboard.onChange = { [weak popup] in popup?.reload() }
        popup.onLimit = { limit in store.setLimit(limit) }
        HotKey.action = { [weak popup] in popup?.toggle() }
        HotKey.register(keyCode: HotKey.saved.keyCode, modifiers: HotKey.saved.modifiers)

        clipboard.start()
        updater.start()

        // Launch at login is on unless it was turned off in Crumb's settings. A new version can lose its login item
        // (macOS ties it to the app's signature), so Crumb asks for it again whenever it is wanted but missing.
        if installedInApplications(), defaults.bool(forKey: Defaults.launchAtLogin), SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
        if !defaults.bool(forKey: Defaults.launchedBefore) {
            defaults.set(true, forKey: Defaults.launchedBefore)
            popup.showSettings()  // there is no menu bar icon, so say hello once
        }
    }

    // Quitting waits (up to ten seconds) for copies that are still being saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard clipboard?.busy == true else { return .terminateNow }
        finishSaving(since: CACurrentMediaTime())
        return .terminateLater
    }

    private func finishSaving(since start: CFTimeInterval) {
        if clipboard?.busy != true || CACurrentMediaTime() - start > 10 {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            MainActor.assumeIsolated { self?.finishSaving(since: start) }
        }
    }

    // Opening Crumb again (from Finder or Spotlight) shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popup?.showSettings()
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
