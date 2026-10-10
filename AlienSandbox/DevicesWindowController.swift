//  DevicesWindowController.swift
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

/// Settings window listing every Mac on the Apple account that runs this app,
/// with a button to launch the Alien movie lock on the selected one.
@MainActor
final class DevicesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private enum Column: String {
        case name, lastSeen, state

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    private let cloudSync: CloudSync
    private var devices: [RemoteDevice] = []

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var playButton = NSButton(title: "Play Alien Movie", target: self, action: #selector(playAlienMovie))
    private lazy var refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(cloudSync: CloudSync) {
        self.cloudSync = cloudSync
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Devices"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 240)
        window.center()
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("DevicesWindowController is created in code")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
        cloudSync.refresh()
    }

    /// Re-reads the device list and status from the sync layer.
    func reload() {
        let selectedID = selectedDevice?.id
        devices = cloudSync.devices
        tableView.reloadData()
        if let selectedID = selectedID, let row = devices.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if !isShowingTransientStatus {
            statusLabel.stringValue = cloudSync.status
        }
        updateButtons()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        for (column, title, width) in [
            (Column.name, "Mac", CGFloat(240)),
            (Column.lastSeen, "Last Seen", CGFloat(120)),
            (Column.state, "State", CGFloat(100))
        ] {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = title
            tableColumn.width = width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(playAlienMovie)
        tableView.target = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"
        refreshButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [statusLabel, refreshButton, playButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private var selectedDevice: RemoteDevice? {
        let row = tableView.selectedRow
        guard row >= 0, row < devices.count else { return nil }
        return devices[row]
    }

    private func updateButtons() {
        playButton.isEnabled = cloudSync.isReady && selectedDevice != nil && !isSending
        refreshButton.isEnabled = cloudSync.isReady
    }

    // MARK: - Actions

    private var isSending = false
    private var isShowingTransientStatus = false

    @objc private func refresh() {
        cloudSync.refresh()
    }

    @objc private func playAlienMovie() {
        guard let device = selectedDevice, !isSending else { return }
        isSending = true
        showTransientStatus("Sending to “\(device.name)”…")
        updateButtons()
        Task {
            do {
                try await cloudSync.send(.lockWithAlienMovie, to: device)
                showTransientStatus(device.isThisDevice
                    ? "Locked this Mac."
                    : "Sent. “\(device.name)” plays the Alien movie as soon as it picks up the command.")
            } catch {
                showTransientStatus("Couldn’t send to “\(device.name)”: \(error.localizedDescription)")
            }
            isSending = false
            updateButtons()
        }
    }

    /// Shows `text` for a few seconds, then goes back to the sync status.
    private func showTransientStatus(_ text: String) {
        statusLabel.stringValue = text
        isShowingTransientStatus = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            isShowingTransientStatus = false
            statusLabel.stringValue = cloudSync.status
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        devices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue),
              row < devices.count else { return nil }
        let device = devices[row]

        let text: String
        switch column {
        case .name:
            text = device.isThisDevice ? "\(device.name) (this Mac)" : device.name
        case .lastSeen:
            text = relativeFormatter.localizedString(for: device.lastSeen, relativeTo: Date())
        case .state:
            text = device.isLocked ? "Locked" : "Unlocked"
        }

        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: column.identifier)
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
