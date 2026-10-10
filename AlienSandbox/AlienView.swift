// AlienScreenSaver
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
import AVFoundation

/// Which movie the lock view shows.
enum PlaybackSource {
    case desktop   // the desktop recording (fake "unlocked" screen)
    case countdown // AlienMovie.mp4
}

/// Lets the lock view hand off to whoever owns the windows.
@MainActor
protocol LockViewDelegate: AnyObject {
    /// Hide the lock UI, record the desktop, then call `desktopRecordingDidFinish()`.
    func lockViewWantsDesktopRecording(_ view: AlienView)
    /// The correct passcode was entered; take the lock down.
    func lockViewDidUnlock(_ view: AlienView)
}

// MARK: - Countdown display styling

/// Colours sampled from AlienMovie.mp4, the Nostromo self-destruct countdown: a
/// black screen with glowing amber vector lines that turn red as time runs out.
/// The keypad is drawn as dark keys outlined and lettered in the same amber,
/// with red reserved for destructive keys and errors.
private enum KeypadPalette {
    static let panel = NSColor(calibratedRed: 0.02, green: 0.01, blue: 0.0, alpha: 0.94)
    static let panelEdge = NSColor(calibratedRed: 0.45, green: 0.17, blue: 0.0, alpha: 1)
    static let key = NSColor(calibratedRed: 0.09, green: 0.03, blue: 0.0, alpha: 1)
    static let keyPressed = NSColor(calibratedRed: 0.45, green: 0.17, blue: 0.0, alpha: 1)
    static let keyEdge = NSColor(calibratedRed: 0.73, green: 0.31, blue: 0.0, alpha: 1)
    static let keyInk = NSColor(calibratedRed: 0.92, green: 0.40, blue: 0.02, alpha: 1)
    static let red = NSColor(calibratedRed: 0.90, green: 0.10, blue: 0.0, alpha: 1)
    static let brightAmber = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    static let display = NSColor.black
    static let displayEdge = NSColor(calibratedRed: 0.45, green: 0.17, blue: 0.0, alpha: 1)
    static let displayText = NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.04, alpha: 1)
    static let displayDim = NSColor(calibratedRed: 0.45, green: 0.17, blue: 0.0, alpha: 1)
    static let displayError = NSColor(calibratedRed: 1.0, green: 0.16, blue: 0.04, alpha: 1)
}

/// One dark key outlined in amber: a large glyph, optionally in an accent
/// colour, with a tiny caption underneath like the labels on the Nostromo's keys.
private final class KeypadKeyButton: NSButton {
    static let keySize = NSSize(width: 68, height: 50)

    var glyph: String { didSet { needsDisplay = true } }
    var glyphColor: NSColor { didSet { needsDisplay = true } }
    var caption: String? { didSet { needsDisplay = true; setAccessibilityLabel(caption ?? glyph) } }

    init(glyph: String, glyphColor: NSColor = KeypadPalette.keyInk, caption: String? = nil, target: AnyObject, action: Selector) {
        self.glyph = glyph
        self.glyphColor = glyphColor
        self.caption = caption
        super.init(frame: NSRect(origin: .zero, size: KeypadKeyButton.keySize))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(caption ?? glyph)
    }

    required init?(coder: NSCoder) {
        fatalError("KeypadKeyButton is created in code")
    }

    override var intrinsicContentSize: NSSize { KeypadKeyButton.keySize }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted ?? false
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (pressed ? KeypadPalette.keyPressed : KeypadPalette.key).setFill()
        path.fill()
        KeypadPalette.keyEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        // When pressed the key lights up amber, so the lettering flips to black.
        let ink: NSColor
        if pressed {
            ink = .black
        } else {
            ink = isEnabled ? glyphColor : glyphColor.withAlphaComponent(0.35)
        }
        let glyphFont = NSFont.monospacedSystemFont(ofSize: caption == nil ? 20 : 16, weight: .bold)
        let glyphAttributes: [NSAttributedString.Key: Any] = [.font: glyphFont, .foregroundColor: ink]
        let glyphSize = (glyph as NSString).size(withAttributes: glyphAttributes)
        var glyphOrigin = NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2)

        if let caption = caption {
            glyphOrigin.y += 5
            let captionInk: NSColor
            if pressed {
                captionInk = .black
            } else {
                captionInk = isEnabled ? KeypadPalette.keyInk : KeypadPalette.keyInk.withAlphaComponent(0.35)
            }
            let captionAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: captionInk
            ]
            let captionSize = (caption as NSString).size(withAttributes: captionAttributes)
            (caption as NSString).draw(
                at: NSPoint(x: rect.midX - captionSize.width / 2, y: rect.minY + 4),
                withAttributes: captionAttributes
            )
        }
        (glyph as NSString).draw(at: glyphOrigin, withAttributes: glyphAttributes)
    }
}

// MARK: - Lock view

/// Fullscreen lock view. While locked it loops whatever `lock(playing:)` asked
/// for (normally the desktop recording, so the Mac looks unlocked) until the
/// keyboard or mouse is touched. The first touch launches the countdown movie
/// (AlienMovie.mp4) and shows the passcode keypad; the countdown runs until the
/// correct passcode is entered or the prompt is cancelled.
final class AlienView: NSView {

    private enum Mode {
        case idle            // unlocked: nothing playing; the owner hides the window
        case locked          // movie playing, prompt hidden
        case unlocking       // prompt visible, enter passcode to unlock
        case settingUp       // first run: choose a passcode
        case verifyingChange // enter current passcode before changing it
        case choosingNew     // enter and confirm the new passcode
        case verifyingRecord // enter passcode before re-recording the desktop
        case recording       // lock UI hidden while the delegate records the desktop
    }

    weak var delegate: LockViewDelegate?

    private var mode: Mode = .idle
    /// What plays while locked and untouched; set by `lock(playing:)`.
    private var idleSource: PlaybackSource = .desktop
    /// What is on screen right now.
    private var source: PlaybackSource = .desktop

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?

    // Keypad panel
    private let promptBox = NSView()
    private let displayBox = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let passcodeField = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private lazy var primaryButton = KeypadKeyButton(glyph: "▶", glyphColor: KeypadPalette.brightAmber, caption: "UNLOCK", target: self, action: #selector(primaryAction))
    private lazy var cancelButton = KeypadKeyButton(glyph: "◀", caption: "CANCEL", target: self, action: #selector(cancelAction))
    private lazy var clearButton = KeypadKeyButton(glyph: "✕", glyphColor: KeypadPalette.red, caption: "CLEAR", target: self, action: #selector(clearAction))
    private lazy var changeButton = KeypadKeyButton(glyph: "◆", glyphColor: KeypadPalette.brightAmber, caption: "PASSCODE", target: self, action: #selector(beginChangePasscode))
    private lazy var recordButton = KeypadKeyButton(glyph: "●", glyphColor: KeypadPalette.red, caption: "RECORD", target: self, action: #selector(beginRerecordDesktop))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        setUp()
    }

    override var acceptsFirstResponder: Bool { true }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        buildPrompt()
        promptBox.isHidden = true
    }

    // MARK: - Locking

    /// Puts the lock up with `newSource` playing until the keyboard or mouse is
    /// touched. On first run the passcode setup is shown instead.
    func lock(playing newSource: PlaybackSource) {
        idleSource = newSource
        play(newSource)
        enter(PasscodeManager.isSet ? .locked : .settingUp)
    }

    private func unlock() {
        enter(.idle)
        if let delegate = delegate {
            delegate.lockViewDidUnlock(self)
        } else {
            NSApp.presentationOptions = []
            NSApp.terminate(nil)
        }
    }

    /// Takes the lock down without a passcode, because another Mac on the
    /// account entered it. Doesn't notify the delegate, so nothing is re-broadcast.
    func dismiss() {
        enter(.idle)
    }

    // MARK: - Desktop recording hand-off

    /// Hides the lock UI and asks the delegate to record the desktop.
    func startDesktopRecording() {
        guard let delegate = delegate else {
            enter(.locked)
            return
        }
        enter(.recording)
        delegate.lockViewWantsDesktopRecording(self)
    }

    /// Called by the delegate once recording ends, successfully or not. Goes back
    /// to the locked state playing whatever desktop recording now exists.
    func desktopRecordingDidFinish() {
        stopMovie()
        idleSource = .desktop
        source = .desktop
        enter(.locked)
    }

    // MARK: - Movie playback

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMovie()
        } else if playsMovie(in: mode) {
            startMovie()
        }
    }

    private func playsMovie(in mode: Mode) -> Bool {
        mode != .idle && mode != .recording
    }

    private var countdownURL: URL? {
        Bundle.main.url(forResource: "AlienMovie", withExtension: "mp4")
    }

    /// The desktop recording when one exists; otherwise fall back to the countdown movie.
    private var desktopURL: URL? {
        if #available(macOS 12.3, *), DesktopRecorder.hasRecording {
            return DesktopRecorder.recordingURL
        }
        return countdownURL
    }

    private func url(for source: PlaybackSource) -> URL? {
        source == .desktop ? desktopURL : countdownURL
    }

    private func startMovie() {
        guard player == nil, let url = url(for: source) else {
            return
        }
        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.videoGravity = .resizeAspectFill
        layer?.insertSublayer(playerLayer, at: 0)

        // Loop whichever item is current; the item changes when the source does.
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let player = self?.player,
                  let item = notification.object as? AVPlayerItem,
                  item === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        self.player = player
        self.playerLayer = playerLayer
    }

    private func stopMovie() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObserver = nil
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    /// Makes `newSource` the movie on screen. If nothing is playing yet, the
    /// next `startMovie()` picks it up.
    private func play(_ newSource: PlaybackSource) {
        let changed = newSource != source
        source = newSource
        guard changed, let player = player, let url = url(for: newSource) else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    // MARK: - Keypad UI

    private func buildPrompt() {
        promptBox.wantsLayer = true
        promptBox.layer?.backgroundColor = KeypadPalette.panel.cgColor
        promptBox.layer?.cornerRadius = 12
        promptBox.layer?.borderWidth = 1
        promptBox.layer?.borderColor = KeypadPalette.panelEdge.cgColor
        promptBox.translatesAutoresizingMaskIntoConstraints = false

        // Display strip: message, passcode entry and errors in countdown amber.
        displayBox.wantsLayer = true
        displayBox.layer?.backgroundColor = KeypadPalette.display.cgColor
        displayBox.layer?.cornerRadius = 6
        displayBox.layer?.borderWidth = 1
        displayBox.layer?.borderColor = KeypadPalette.displayEdge.cgColor
        displayBox.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        messageLabel.textColor = KeypadPalette.displayText
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        errorLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        errorLabel.textColor = KeypadPalette.displayError
        errorLabel.alignment = .center

        styleDisplayField(passcodeField, placeholder: "PASSCODE")
        styleDisplayField(confirmField, placeholder: "CONFIRM")

        let displayStack = NSStackView(views: [messageLabel, passcodeField, confirmField, errorLabel])
        displayStack.orientation = .vertical
        displayStack.alignment = .centerX
        displayStack.spacing = 6
        displayStack.translatesAutoresizingMaskIntoConstraints = false
        displayBox.addSubview(displayStack)

        // Keypad: digits with the function keys down the right-hand column.
        primaryButton.keyEquivalent = "\r"
        func digit(_ value: String) -> KeypadKeyButton {
            KeypadKeyButton(glyph: value, target: self, action: #selector(keypadDigitPressed(_:)))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let keypad = NSGridView(views: [
            [digit("1"), digit("2"), digit("3"), cancelButton],
            [digit("4"), digit("5"), digit("6"), clearButton],
            [digit("7"), digit("8"), digit("9"), primaryButton],
            [changeButton, digit("0"), recordButton, spacer]
        ])
        keypad.rowSpacing = 8
        keypad.columnSpacing = 8
        keypad.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [displayBox, keypad])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        promptBox.addSubview(stack)
        addSubview(promptBox)

        let keypadWidth = KeypadKeyButton.keySize.width * 4 + keypad.columnSpacing * 3
        NSLayoutConstraint.activate([
            promptBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            promptBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: promptBox.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: promptBox.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: promptBox.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: promptBox.trailingAnchor, constant: -18),
            displayBox.widthAnchor.constraint(equalToConstant: keypadWidth),
            spacer.widthAnchor.constraint(equalToConstant: KeypadKeyButton.keySize.width),
            spacer.heightAnchor.constraint(equalToConstant: KeypadKeyButton.keySize.height),
            displayStack.topAnchor.constraint(equalTo: displayBox.topAnchor, constant: 10),
            displayStack.bottomAnchor.constraint(equalTo: displayBox.bottomAnchor, constant: -10),
            displayStack.leadingAnchor.constraint(equalTo: displayBox.leadingAnchor, constant: 12),
            displayStack.trailingAnchor.constraint(equalTo: displayBox.trailingAnchor, constant: -12),
            messageLabel.widthAnchor.constraint(equalTo: displayStack.widthAnchor),
            passcodeField.widthAnchor.constraint(equalTo: displayStack.widthAnchor),
            confirmField.widthAnchor.constraint(equalTo: displayStack.widthAnchor)
        ])
    }

    private func styleDisplayField(_ field: NSSecureTextField, placeholder: String) {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        field.textColor = KeypadPalette.displayText
        field.alignment = .center
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: KeypadPalette.displayDim,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            ]
        )
        field.target = self
        field.action = #selector(primaryAction)
        field.delegate = self
    }

    /// The field keypad presses go into: the confirm field when it's visible and
    /// being edited, otherwise the passcode field.
    private var activeField: NSSecureTextField {
        if !confirmField.isHidden, confirmField.currentEditor() != nil {
            return confirmField
        }
        return passcodeField
    }

    private func setMessage(_ text: String) {
        messageLabel.stringValue = text.uppercased()
    }

    private func enter(_ newMode: Mode) {
        mode = newMode
        passcodeField.stringValue = ""
        confirmField.stringValue = ""
        errorLabel.stringValue = ""

        if playsMovie(in: newMode) {
            if window != nil {
                startMovie()
            }
        } else {
            stopMovie()
        }

        switch newMode {
        case .idle, .recording:
            promptBox.isHidden = true
        case .locked:
            promptBox.isHidden = true
            window?.makeFirstResponder(self)
        case .unlocking:
            promptBox.isHidden = false
            setMessage("Enter passcode")
            confirmField.isHidden = true
            primaryButton.caption = "UNLOCK"
            cancelButton.isHidden = false
            changeButton.isHidden = false
            recordButton.isHidden = false
            focusPasscodeField()
        case .settingUp:
            promptBox.isHidden = false
            setMessage("Set a passcode for this screen saver")
            confirmField.isHidden = false
            primaryButton.caption = "SET"
            cancelButton.isHidden = true
            changeButton.isHidden = true
            recordButton.isHidden = true
            focusPasscodeField()
        case .verifyingChange:
            promptBox.isHidden = false
            setMessage("Enter current passcode")
            confirmField.isHidden = true
            primaryButton.caption = "CONTINUE"
            cancelButton.isHidden = false
            changeButton.isHidden = true
            recordButton.isHidden = true
            focusPasscodeField()
        case .choosingNew:
            promptBox.isHidden = false
            setMessage("Enter a new passcode")
            confirmField.isHidden = false
            primaryButton.caption = "SAVE"
            cancelButton.isHidden = false
            changeButton.isHidden = true
            recordButton.isHidden = true
            focusPasscodeField()
        case .verifyingRecord:
            promptBox.isHidden = false
            setMessage("Enter passcode to re-record desktop")
            confirmField.isHidden = true
            primaryButton.caption = "CONTINUE"
            cancelButton.isHidden = false
            changeButton.isHidden = true
            recordButton.isHidden = true
            focusPasscodeField()
        }
    }

    private func focusPasscodeField() {
        window?.makeFirstResponder(passcodeField)
    }

    // MARK: - Keypad actions

    @objc private func keypadDigitPressed(_ sender: NSButton) {
        guard let key = sender as? KeypadKeyButton else { return }
        let field = activeField
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText(key.glyph, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            field.stringValue += key.glyph
            window?.makeFirstResponder(field)
        }
    }

    @objc private func clearAction() {
        let field = activeField
        if let editor = field.currentEditor() {
            editor.string = ""
        }
        field.stringValue = ""
        errorLabel.stringValue = ""
    }

    @objc private func primaryAction() {
        let entered = passcodeField.stringValue
        switch mode {
        case .idle, .locked, .recording:
            break
        case .unlocking:
            if PasscodeManager.verify(entered) {
                unlock()
            } else {
                rejectPasscode()
            }
        case .settingUp:
            // Enter on the first field moves to the confirmation before validating.
            if !entered.isEmpty, confirmField.stringValue.isEmpty, activeField === passcodeField {
                window?.makeFirstResponder(confirmField)
                return
            }
            guard let passcode = validatedNewPasscode(entered) else { return }
            PasscodeManager.set(passcode)
            // Part of first-run setup: capture the desktop that will play while locked.
            startDesktopRecording()
        case .choosingNew:
            if !entered.isEmpty, confirmField.stringValue.isEmpty, activeField === passcodeField {
                window?.makeFirstResponder(confirmField)
                return
            }
            guard let passcode = validatedNewPasscode(entered) else { return }
            PasscodeManager.set(passcode)
            enter(.locked)
        case .verifyingChange:
            if PasscodeManager.verify(entered) {
                enter(.choosingNew)
            } else {
                rejectPasscode()
            }
        case .verifyingRecord:
            if PasscodeManager.verify(entered) {
                startDesktopRecording()
            } else {
                rejectPasscode()
            }
        }
    }

    /// Returns the passcode when both fields agree and it isn't empty; otherwise
    /// shows the problem and returns nil.
    private func validatedNewPasscode(_ entered: String) -> String? {
        guard !entered.isEmpty else {
            fail("Passcode can’t be empty")
            return nil
        }
        guard entered == confirmField.stringValue else {
            fail("Passcodes don’t match")
            return nil
        }
        return entered
    }

    /// Cancelling the prompt re-arms the lock: the idle movie resumes and the
    /// next touch launches the countdown again.
    @objc private func cancelAction() {
        play(idleSource)
        enter(.locked)
    }

    @objc private func beginChangePasscode() {
        enter(.verifyingChange)
    }

    @objc private func beginRerecordDesktop() {
        enter(.verifyingRecord)
    }

    private func rejectPasscode() {
        fail("Incorrect passcode")
        play(.countdown)
    }

    private func fail(_ message: String) {
        errorLabel.stringValue = message.uppercased()
        passcodeField.stringValue = ""
        confirmField.stringValue = ""
        focusPasscodeField()
        NSSound.beep()
    }

    // MARK: - Input while locked

    // The first key press or click launches the countdown and brings up the
    // keypad. Events are never passed to super, so nothing can dismiss the view.
    override func keyDown(with event: NSEvent) {
        touched()
    }

    override func mouseDown(with event: NSEvent) {
        touched()
    }

    private func touched() {
        guard mode == .locked else { return }
        play(.countdown)
        enter(.unlocking)
    }
}

// MARK: - Field editor styling

extension AlienView: NSTextFieldDelegate {
    /// The field editor is created by AppKit; give its caret the amber display
    /// colour so it's visible against the black strip.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        editor.insertionPointColor = KeypadPalette.displayText
    }
}
