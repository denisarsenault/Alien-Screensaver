//  AppDelegate.swift
//
//  Created by Denis Arsenault on 21/05/2019.
//  Copyright © 2019 Denis Arsenault. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import Cocoa

/// Borderless windows refuse key status by default; the lock window must be
/// key so the passcode field can receive input.
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@NSApplicationMain
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet weak var window: NSWindow!

    private var lockWindow: LockWindow?
    private var lockView: AlienView?
    private var blackoutWindows = [NSWindow]()
    private var commandKeyMonitor: Any?
    private var isLocked = false
    /// When the current lock went up; remote unlocks issued before this are stale.
    private var lockedSince: Date?

    // Menu bar agent and iCloud device control.
    private var statusItem: NSStatusItem?
    private let cloudSync: CloudSync
    private var devicesWindowController: DevicesWindowController?

    override init() {
        // Created here rather than inline: stored-property default values aren't
        // main-actor isolated, and CloudSync is.
        cloudSync = CloudSync()
        super.init()
    }

    // Desktop recording. The recorder is stored untyped because DesktopRecorder
    // needs macOS 12.3 while the app still runs on 12.0.
    private var recorder: Any?
    private var recordingPanel: NSPanel?
    private var recordingTimer: Timer?
    private var recordingDeadline: Date?
    private let countdownLabel = NSTextField(labelWithString: "")

    /// Hides the Dock and menu bar and blocks app switching, force quit, hiding
    /// and log-out while the lock is up.
    private let lockedPresentationOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication
    ]

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The xib window is unused; the lock screen is built in code below. Replace
        // its content view too, so nothing loaded from the nib can play unseen.
        window?.contentView = NSView()
        window?.orderOut(nil)

        installStatusItem()

        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let lockScreenWindow = LockWindow(
            contentRect: mainScreen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        lockScreenWindow.level = .screenSaver
        lockScreenWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        lockScreenWindow.backgroundColor = .black
        let view = AlienView(frame: mainScreen.frame)
        view.delegate = self
        lockScreenWindow.contentView = view
        lockWindow = lockScreenWindow
        lockView = view

        // Black out any other displays so the lock can't be bypassed there.
        for screen in NSScreen.screens where screen != mainScreen {
            let blackout = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            blackout.level = .screenSaver
            blackout.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            blackout.backgroundColor = .black
            blackoutWindows.append(blackout)
        }

        // Swallow every ⌘ shortcut (⌘Q, ⌘H, ⌘W, …) while locked.
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Event monitors run on the main thread but aren't statically isolated.
            let locked = MainActor.assumeIsolated { self?.isLocked == true }
            return (locked && event.modifierFlags.contains(.command)) ? nil : event
        }

        cloudSync.delegate = self
        cloudSync.start()
        NSApp.registerForRemoteNotifications()

        // Launching locks right away, as it always has.
        lock(playing: .desktop)

        // A passcode without a desktop recording means an earlier attempt didn't
        // finish, usually because Screen Recording access was granted afterwards.
        // Record now that we can.
        if #available(macOS 12.3, *),
           PasscodeManager.isSet,
           !DesktopRecorder.hasRecording,
           DesktopRecorder.hasPermission {
            view.startDesktopRecording()
        }
    }

    /// The app lives in the menu bar between locks; closing windows never quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Remote notifications (silent CloudKit pushes)

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        cloudSync.handleRemoteNotification(userInfo)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Push is optional; CloudSync polls as a fallback.
        NSLog("Remote notifications unavailable: \(error.localizedDescription)")
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "lock.desktopcomputer", accessibilityDescription: "Alien Screen Saver")
            ?? NSImage(systemSymbolName: "lock", accessibilityDescription: "Alien Screen Saver")
        item.button?.toolTip = "Alien Screen Saver"

        let menu = NSMenu()
        menu.addItem(makeMenuItem("Lock Now", action: #selector(lockNow)))
        menu.addItem(makeMenuItem("Lock with Alien Movie", action: #selector(lockNowWithAlienMovie)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Devices…", action: #selector(showDevices)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alien Screen Saver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func lockNow() {
        lock(playing: .desktop)
    }

    @objc private func lockNowWithAlienMovie() {
        lock(playing: .countdown)
    }

    @objc private func showDevices() {
        if devicesWindowController == nil {
            devicesWindowController = DevicesWindowController(cloudSync: cloudSync)
        }
        NSApp.activate(ignoringOtherApps: true)
        devicesWindowController?.showWindow(nil)
    }

    // MARK: - Lock window visibility

    /// Puts the lock up with `source` playing until the keyboard or mouse is touched.
    private func lock(playing source: PlaybackSource) {
        // Never interrupt a desktop recording in progress.
        guard recorder == nil, let view = lockView else { return }
        showLock()
        view.lock(playing: source)
    }

    private func showLock() {
        if !isLocked {
            lockedSince = Date()
        }
        isLocked = true
        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = lockedPresentationOptions
        lockWindow?.makeKeyAndOrderFront(nil)
        blackoutWindows.forEach { $0.orderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        cloudSync.reportLockState(true)
    }

    /// Takes the lock down so the desktop can be used (and recorded) normally.
    private func hideLock() {
        isLocked = false
        lockedSince = nil
        NSApp.presentationOptions = []
        lockWindow?.orderOut(nil)
        blackoutWindows.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
        cloudSync.reportLockState(false)
    }
}

// MARK: - Lock view delegate

extension AppDelegate: LockViewDelegate {
    func lockViewDidUnlock(_ view: AlienView) {
        hideLock()
        // The passcode entered here unlocks every other Mac on the account too.
        Task { try? await cloudSync.broadcast(.unlock) }
    }

    func lockViewWantsDesktopRecording(_ view: AlienView) {
        guard #available(macOS 12.3, *) else {
            view.desktopRecordingDidFinish()
            return
        }

        hideLock()
        let duration = DesktopRecorder.defaultDuration
        let recorder = DesktopRecorder()
        self.recorder = recorder
        showRecordingPanel(duration: duration)

        // The recorder calls back on the main queue.
        recorder.start(duration: duration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.recorder = nil
                self.closeRecordingPanel()
                if case .failure(let error) = result {
                    // Finish Now before capture began isn't a problem worth an alert.
                    if case DesktopRecorder.RecorderError.cancelled = error {
                        // Nothing to report.
                    } else {
                        self.presentRecordingFailure(error)
                    }
                }
                self.showLock()
                view.desktopRecordingDidFinish()
            }
        }
    }
}

// MARK: - iCloud device control

extension AppDelegate: CloudSyncDelegate {
    func cloudSync(_ sync: CloudSync, didReceive command: RemoteCommand) {
        switch command.action {
        case .lockWithAlienMovie:
            lock(playing: .countdown)
        case .unlock:
            // Only honour an unlock issued after this lock went up, so an old
            // broadcast can't unlock a Mac that was locked later.
            guard isLocked, recorder == nil,
                  let since = lockedSince, command.issuedAt > since else { return }
            lockView?.dismiss()
            hideLock()
        }
    }

    func cloudSyncDidChange(_ sync: CloudSync) {
        devicesWindowController?.reload()
    }
}

// MARK: - Desktop recording HUD

extension AppDelegate {
    /// Small floating HUD so the user knows the desktop is being recorded. Our own
    /// windows are excluded from the capture, so it never shows up in the movie.
    private func showRecordingPanel(duration: TimeInterval) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
            styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Desktop"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let message = NSTextField(wrappingLabelWithString:
            "Use your Mac normally. This recording plays while the screen saver is locked.")
        message.font = .systemFont(ofSize: 12)
        message.alignment = .center

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        countdownLabel.alignment = .center

        let finishButton = NSButton(title: "Finish Now", target: self, action: #selector(finishRecordingEarly))
        finishButton.bezelStyle = .rounded

        let stack = NSStackView(views: [message, countdownLabel, finishButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            message.widthAnchor.constraint(equalToConstant: 280)
        ])
        panel.contentView = content

        // Tuck it into the top-right corner of the main screen.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        }

        recordingDeadline = Date().addingTimeInterval(duration)
        updateCountdown()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCountdown() }
        }

        panel.orderFront(nil)
        recordingPanel = panel
    }

    private func updateCountdown() {
        let remaining = max(0, Int((recordingDeadline?.timeIntervalSinceNow ?? 0).rounded(.up)))
        countdownLabel.stringValue = String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func closeRecordingPanel() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDeadline = nil
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
    }

    @objc private func finishRecordingEarly() {
        if #available(macOS 12.3, *) {
            (recorder as? DesktopRecorder)?.stop()
        }
    }

    private func presentRecordingFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Desktop recording didn’t finish"

        let needsPermission = !CGPreflightScreenCaptureAccess()
        if needsPermission {
            alert.informativeText = """
                Allow AlienScreenSaver under System Settings → Privacy & Security → Screen Recording, \
                then relaunch the app. The desktop is recorded automatically on the next launch. \
                Until then the countdown movie plays while locked.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Continue")
        } else {
            alert.informativeText = """
                \(error.localizedDescription)

                The countdown movie plays while locked. Choose Re-record Desktop… on the unlock prompt to try again.
                """
            alert.addButton(withTitle: "Continue")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if needsPermission, response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
