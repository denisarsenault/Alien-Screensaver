# Alien Screen Saver

A macOS screen saver that plays `AlienMovie.mp4` fullscreen, plus a standalone **locked screen saver app** that can't be dismissed without a passcode. Based on the original Alien clock screensaver (the clock renderer still lives in `AlienCore`).

## Targets

| Target | Product | Purpose |
| --- | --- | --- |
| `AlienScreenSaver` (scheme: `Alien`) | `AlienScreenSaver.saver` | Standard macOS screen saver bundle. Installs to `~/Library/Screen Savers`. Dismissed by any input, like every macOS screen saver. |
| `AlienScreenSaverApp` (scheme: `AlienSandbox`) | `AlienScreenSaver.app` | Fullscreen kiosk-style screen saver that requires a passcode to exit. |
| `AlienScreenSaverCore` | `AlienScreenSaverCore.framework` | Shared code (`AlienClock`, `Configuration`) used by both. |

## The locked screen saver app

macOS does not let a `.saver` bundle block dismissal — the system stops the saver on any input before the saver's code gets a say. So the passcode lock is implemented as a standalone app (`AlienScreenSaverApp` target) instead.

### Behavior

- On launch the app goes fullscreen at screen-saver window level and loops a **2-minute recording of your own desktop**, so the Mac looks like it was never locked. If no recording exists yet, `AlienMovie.mp4` plays instead.
- The Dock and menu bar are hidden; app switching, force quit (⌘⌥Esc), hiding, log-out, and all ⌘ shortcuts (⌘Q, ⌘H, ⌘W, …) are blocked while locked.
- Additional displays are blacked out so the lock can't be bypassed on a second monitor.
- The desktop loop plays until the **keyboard or mouse is touched**. The first touch launches the countdown video (`AlienMovie.mp4`) and shows the passcode prompt over it.
- The correct passcode takes the lock down and the app stays in the **menu bar** (lock icon) so it can be locked again from that menu or from another Mac; choose *Quit* there to exit. A wrong passcode beeps and clears the field while the countdown keeps running. **Cancel** re-arms the lock: the idle movie resumes and the next touch launches the countdown again.
- The menu bar menu offers **Lock Now** (desktop loop), **Lock with Alien Movie**, and **Devices…**.

### Desktop recording

- **On install (first launch):** right after you set a passcode, the lock UI gets out of the way and the app records the main display for 2 minutes. A small floating *Recording Desktop* panel shows the time remaining with a **Finish Now** button; use your Mac normally in the meantime. The panel and the app's own windows are excluded from the capture.
- **Permission:** macOS asks for Screen Recording access the first time. Grant it under System Settings → Privacy & Security → Screen Recording, then relaunch the app; the recording starts automatically on the next launch. Until then the countdown video plays while locked.
- **Re-recording:** click **Re-record Desktop…** on the unlock prompt and enter the passcode.
- **Storage:** `~/Library/Containers/com.mybrightzone.alien.sandbox/Data/Library/Application Support/com.mybrightzone.alien.sandbox/DesktopRecording.mp4` (H.264, native display resolution, about 10 Mbit/s, so roughly 150 MB for 2 minutes). Delete the file to force a fresh recording on the next launch.
- Requires macOS 12.3 or later (ScreenCaptureKit). On older systems the app skips recording and plays `AlienMovie.mp4` while locked.

### Controlling other Macs (iCloud)

Every Mac signed into the same Apple account and running this app appears in the **Devices** window (menu bar icon → *Devices…*). Select a Mac and click **Play Alien Movie** to launch the lock on it playing `AlienMovie.mp4` directly, skipping the desktop loop. The target Mac must have the app running; it stays in the menu bar after an unlock.

**One passcode unlocks them all.** Entering the correct passcode on any Mac broadcasts an unlock, and every other Mac that is currently locked takes its lock down. A Mac only honours an unlock issued *after* its own lock went up, so an old broadcast can never unlock a Mac that was locked later. While locked, each Mac polls every 15 seconds in case push isn't available.

- **Where the data lives:** your private CloudKit database, in a custom zone named `AlienDevices`. Each Mac keeps one `Device` record (name, last seen, locked state); commands are `Command` records addressed to a device ID. Nothing is written to the public database.
- **Encryption:** every field is stored with CloudKit's end-to-end encrypted fields (`CKRecord.encryptedValues`), readable only by devices signed into your account. Apple sees only record names (random UUIDs) and timestamps.
- **Delivery:** a silent push wakes the target as soon as a command is saved, with a 60-second poll as a fallback. Commands older than 10 minutes (sent while a Mac was off) are discarded, and each command is deleted once the target has acted on it so it can never run twice.
- **Requirements:** each Mac signed into iCloud (System Settings → Apple ID) with iCloud Keychain enabled so the encryption keys are available, and the app built with the iCloud and Push Notifications capabilities (see Building).

### Passcode

- **First launch:** you're asked to create a passcode (entered twice to confirm), then the desktop recording starts.
- **Changing it:** click **Change Passcode…** on the unlock prompt, verify the current passcode, then enter and confirm the new one.
- **Storage:** only a SHA-256 hash with a random 16-byte salt is saved (in the app's `UserDefaults`); the passcode is never stored in plain text.
- **Forgot it?** From another user account or over SSH, run:

  ```sh
  defaults delete com.mybrightzone.alien.sandbox LockPasscodeHash
  ```

  The app will ask you to set a new passcode on next launch.

### Key files

- `AlienSandbox/AppDelegate.swift` — fullscreen lock window, blocked system UI and shortcuts, multi-display blackout, and the *Recording Desktop* panel shown while the desktop is captured.
- `AlienSandbox/AlienView.swift` — looping playback (desktop recording or countdown video) and the passcode prompt (setup, unlock, change, and re-record flows).
- `AlienSandbox/DesktopRecorder.swift` — ScreenCaptureKit recording of the main display to an MP4, excluding the app's own windows.
- `AlienSandbox/PasscodeManager.swift` — salted-hash passcode storage and verification.
- `AlienSandbox/CloudSync.swift` — CloudKit device registry and encrypted command delivery between Macs.
- `AlienSandbox/DevicesWindowController.swift` — the Devices window.

## Building

Requires Xcode with a macOS 12.0+ SDK.

1. Open `AlienScreenSaver.xcodeproj`.
2. Pick a scheme:
   - **AlienSandbox** — the locked screen saver app. Build and run (⌘R).
   - **Alien** — the `.saver` bundle. Install the built bundle by double-clicking it or copying it to `~/Library/Screen Savers`.

> **Note:** `AlienMovie.mp4` must have Target Membership checked for **AlienScreenSaverApp** (select the file in Xcode, File Inspector → Target Membership). Without it the locked app shows a black screen instead of the movie.

> **Note:** remote control needs two capabilities on the **AlienScreenSaverApp** target under Signing & Capabilities: **iCloud** with *CloudKit* checked and the container `iCloud.com.mybrightzone.alien` (Xcode creates it on your developer account), and **Push Notifications**. The entitlements are already in `AlienSandbox.entitlements`; adding the capabilities in Xcode registers them with your App ID so signing succeeds.

While testing from Xcode, the Stop button still kills the locked app regardless of the passcode.

## Installing the .saver bundle

1. Open **AlienScreenSaver.saver** (double click).
2. If macOS reports it is from an unidentified developer, allow it under System Settings → Privacy & Security → **Open Anyway**.
3. If you were upgrading from a previous version with System Settings open, quit and reopen System Settings — updated Swift screensavers aren't reloaded in an active session.

To uninstall, right-click the screen saver in System Settings and choose delete, or remove it from `~/Library/Screen Savers`.

## Limitations

The locked app blocks normal keyboard/mouse escape routes, but it is not OS-level security: the system login screen, fast user switching, SSH, and a hard power cycle can always get past it. For a password on the *standard* screen saver, use System Settings → Lock Screen instead.

## Author

Denis Arsenault

## License

Available under the Apache 2.0 license. See the [LICENSE](LICENSE) file for more info.
