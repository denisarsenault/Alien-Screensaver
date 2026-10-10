//  CloudSync.swift
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
import CloudKit

/// What one Mac can ask another Mac on the same Apple account to do.
enum RemoteAction: String {
    /// Put the lock up playing AlienMovie.mp4 right away, skipping the desktop loop.
    case lockWithAlienMovie
    /// The passcode was entered on another Mac; take the lock down here too.
    case unlock
}

/// A Mac running this app on the user's Apple account.
struct RemoteDevice: Equatable {
    let id: String
    var name: String
    var lastSeen: Date
    var isLocked: Bool

    var isThisDevice: Bool { id == CloudSync.deviceID }
}

/// A command addressed to this Mac, or broadcast to every Mac.
struct RemoteCommand {
    let recordID: CKRecord.ID
    let targetDeviceID: String
    let action: RemoteAction
    let issuedAt: Date
    let senderName: String
    let senderDeviceID: String?

    var isBroadcast: Bool { targetDeviceID == CloudSync.broadcastTarget }
}

@MainActor
protocol CloudSyncDelegate: AnyObject {
    func cloudSync(_ sync: CloudSync, didReceive command: RemoteCommand)
    /// The device list or status text changed.
    func cloudSyncDidChange(_ sync: CloudSync)
}

/// Keeps the list of Macs on the user's Apple account and delivers commands
/// between them through the private CloudKit database.
///
/// Everything lives in one custom record zone so that every field can use
/// CloudKit's end-to-end encrypted fields (`encryptedValues`); the default zone
/// doesn't support them. Only record names (random UUIDs) and timestamps are
/// visible to the server.
///
/// Devices learn about changes through a silent push subscription on the zone,
/// backed by a periodic poll for Macs that can't receive push.
@MainActor
final class CloudSync {

    static let containerIdentifier = "iCloud.com.mybrightzone.alien"
    /// Target used for commands meant for every Mac on the account.
    nonisolated static let broadcastTarget = "*"

    private static let zoneName = "AlienDevices"
    private static let subscriptionID = "alien-devices-zone-changes"
    private static let deviceRecordType = "Device"
    private static let commandRecordType = "Command"
    nonisolated private static let deviceIDKey = "CloudDeviceID"
    private static let changeTokenKey = "CloudZoneChangeToken"

    /// Commands older than this were sent while this Mac was off; they're discarded.
    private static let commandMaxAge: TimeInterval = 10 * 60
    /// Commands nobody has consumed after this long are cleaned up by whoever sees them.
    private static let commandCleanupAge: TimeInterval = 60 * 60
    private static let pollInterval: TimeInterval = 60
    /// While locked, poll faster so an unlock from another Mac lands quickly
    /// even without push.
    private static let pollIntervalWhileLocked: TimeInterval = 15
    private static let heartbeatInterval: TimeInterval = 5 * 60

    /// Stable identity for this Mac, created on first use.
    nonisolated static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey) {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIDKey)
        return created
    }

    nonisolated static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    weak var delegate: CloudSyncDelegate?

    /// This Mac first, then the others by name.
    private(set) var devices: [RemoteDevice] = []
    private(set) var status = "Connecting to iCloud…"
    private(set) var isReady = false

    private let container = CKContainer(identifier: CloudSync.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    private var isLocked = false
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    private var isFetching = false
    private var fetchRequestedWhileBusy = false
    /// Broadcast commands stay in the zone until they age out, so remember the
    /// ones already acted on in case the change token is ever reset.
    private var handledBroadcastIDs = Set<String>()

    // MARK: - Public API

    func start() {
        Task { await bootstrap() }
    }

    /// Fetches any changes now (used by push notifications and the Devices window).
    func refresh() {
        Task { await fetchChanges() }
    }

    /// Publishes whether this Mac is currently locked.
    func reportLockState(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        guard isReady else { return }
        startTimers()
        Task { try? await publishThisDevice() }
    }

    /// Sends `action` to every other Mac on the account.
    func broadcast(_ action: RemoteAction) async throws {
        try await save(action: action, target: Self.broadcastTarget)
    }

    func handleRemoteNotification(_ userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.notificationType == .recordZone else { return }
        refresh()
    }

    /// Sends `action` to `device`. Commands to this Mac are delivered directly.
    func send(_ action: RemoteAction, to device: RemoteDevice) async throws {
        if device.isThisDevice {
            let command = RemoteCommand(
                recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID),
                targetDeviceID: device.id,
                action: action,
                issuedAt: Date(),
                senderName: Self.deviceName,
                senderDeviceID: Self.deviceID
            )
            delegate?.cloudSync(self, didReceive: command)
            return
        }
        try await save(action: action, target: device.id)
    }

    private func save(action: RemoteAction, target: String) async throws {
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.commandRecordType, recordID: recordID)
        record.encryptedValues["target"] = target
        record.encryptedValues["action"] = action.rawValue
        record.encryptedValues["issuedAt"] = Date()
        record.encryptedValues["sender"] = Self.deviceName
        record.encryptedValues["senderID"] = Self.deviceID
        _ = try await database.save(record)
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                setStatus(Self.message(for: account))
                return
            }
            // Saving an existing zone or subscription is a harmless no-op.
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            await ensureSubscription()
            try await publishThisDevice()
            isReady = true
            setStatus("Connected to iCloud as “\(Self.deviceName)”")
            await fetchChanges()
            startTimers()
        } catch {
            setStatus("iCloud error: \(error.localizedDescription)")
        }
    }

    private static func message(for account: CKAccountStatus) -> String {
        switch account {
        case .noAccount:
            return "Sign in to iCloud in System Settings to control other Macs."
        case .restricted:
            return "iCloud access is restricted on this Mac."
        case .couldNotDetermine:
            return "Couldn’t determine the iCloud account status."
        case .available:
            return "Connected to iCloud"
        default:
            return "iCloud is temporarily unavailable."
        }
    }

    private func ensureSubscription() async {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
        } catch {
            // Push is a nicety; the poll timer still delivers commands.
            NSLog("CloudSync: zone subscription failed: \(error.localizedDescription)")
        }
    }

    private func startTimers() {
        pollTimer?.invalidate()
        let interval = isLocked ? Self.pollIntervalWhileLocked : Self.pollInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in try? await self?.publishThisDevice() }
        }
    }

    // MARK: - This device's record

    private func publishThisDevice() async throws {
        let recordID = CKRecord.ID(recordName: Self.deviceID, zoneID: zoneID)
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: Self.deviceRecordType, recordID: recordID)
        }
        let now = Date()
        record.encryptedValues["name"] = Self.deviceName
        record.encryptedValues["lastSeen"] = now
        record.encryptedValues["isLocked"] = isLocked ? 1 : 0
        _ = try await database.save(record)

        upsert(RemoteDevice(id: Self.deviceID, name: Self.deviceName, lastSeen: now, isLocked: isLocked))
        notify()
    }

    // MARK: - Zone changes

    private func fetchChanges() async {
        guard isReady else { return }
        if isFetching {
            fetchRequestedWhileBusy = true
            return
        }
        isFetching = true

        var token = loadChangeToken()
        var moreComing = true
        do {
            while moreComing {
                do {
                    let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                    for (_, result) in changes.modificationResultsByID {
                        if case .success(let modification) = result {
                            await process(modification.record)
                        }
                    }
                    for deletion in changes.deletions where deletion.recordType == Self.deviceRecordType {
                        devices.removeAll { $0.id == deletion.recordID.recordName }
                    }
                    token = changes.changeToken
                    moreComing = changes.moreComing
                    saveChangeToken(token)
                } catch let error as CKError where error.code == .changeTokenExpired {
                    // Start over from the beginning of the zone.
                    token = nil
                    saveChangeToken(nil)
                }
            }
            notify()
        } catch {
            setStatus("iCloud sync error: \(error.localizedDescription)")
        }

        isFetching = false
        if fetchRequestedWhileBusy {
            fetchRequestedWhileBusy = false
            await fetchChanges()
        }
    }

    private func process(_ record: CKRecord) async {
        switch record.recordType {
        case Self.deviceRecordType:
            guard let name = record.encryptedValues["name"] as? String else { return }
            let lastSeen = record.encryptedValues["lastSeen"] as? Date ?? record.modificationDate ?? Date()
            let locked = (record.encryptedValues["isLocked"] as? Int ?? 0) != 0
            upsert(RemoteDevice(id: record.recordID.recordName, name: name, lastSeen: lastSeen, isLocked: locked))

        case Self.commandRecordType:
            let issuedAt = record.encryptedValues["issuedAt"] as? Date ?? record.creationDate ?? Date()
            let age = Date().timeIntervalSince(issuedAt)
            let target = record.encryptedValues["target"] as? String ?? ""
            let senderID = record.encryptedValues["senderID"] as? String
            let isBroadcast = target == Self.broadcastTarget
            let isForThisMac = target == Self.deviceID || (isBroadcast && senderID != Self.deviceID)

            guard isForThisMac else {
                // Not for this Mac (or our own broadcast). Tidy up once it's old.
                if age > Self.commandCleanupAge {
                    _ = try? await database.deleteRecord(withID: record.recordID)
                }
                return
            }

            if isBroadcast {
                // Every Mac needs to see a broadcast, so it isn't deleted on receipt;
                // de-duplicate locally and let it age out instead.
                let name = record.recordID.recordName
                guard !handledBroadcastIDs.contains(name) else { return }
                handledBroadcastIDs.insert(name)
                if age > Self.commandCleanupAge {
                    _ = try? await database.deleteRecord(withID: record.recordID)
                    return
                }
            } else {
                // Consume a targeted command first so it can never run twice.
                _ = try? await database.deleteRecord(withID: record.recordID)
            }

            guard age < Self.commandMaxAge,
                  let action = RemoteAction(rawValue: record.encryptedValues["action"] as? String ?? "") else { return }
            let command = RemoteCommand(
                recordID: record.recordID,
                targetDeviceID: target,
                action: action,
                issuedAt: issuedAt,
                senderName: record.encryptedValues["sender"] as? String ?? "another Mac",
                senderDeviceID: senderID
            )
            delegate?.cloudSync(self, didReceive: command)

        default:
            break
        }
    }

    // MARK: - Helpers

    private func upsert(_ device: RemoteDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { lhs, rhs in
            if lhs.isThisDevice != rhs.isThisDevice {
                return lhs.isThisDevice
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func setStatus(_ text: String) {
        status = text
        notify()
    }

    private func notify() {
        delegate?.cloudSyncDidChange(self)
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.changeTokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken?) {
        guard let token = token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            UserDefaults.standard.removeObject(forKey: Self.changeTokenKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.changeTokenKey)
    }
}
