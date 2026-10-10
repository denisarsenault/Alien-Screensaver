//  DesktopRecorder.swift
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
import AVFoundation
import ScreenCaptureKit

/// Records the main display to an MP4 for a fixed duration using ScreenCaptureKit,
/// leaving this app's own windows out of the capture. The result is the "desktop"
/// loop the lock screen plays so the Mac looks like it was never locked.
///
/// `@unchecked Sendable`: state is split between the main queue (`stream`,
/// `stopWorkItem`, `completion`) and the private serial `queue` (writer and
/// frame bookkeeping); ScreenCaptureKit's `@Sendable` callbacks hop to one of
/// those before touching anything.
@available(macOS 12.3, *)
final class DesktopRecorder: NSObject, @unchecked Sendable {

    enum RecorderError: LocalizedError {
        case permissionDenied
        case noDisplay
        case writer(Error?)
        case stream(Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required to record your desktop."
            case .cancelled:
                return "The recording was stopped before it started."
            case .noDisplay:
                return "No display is available to record."
            case .writer(let error):
                return "The recording could not be saved. \(error?.localizedDescription ?? "")"
            case .stream(let error):
                return "Screen capture stopped unexpectedly. \(error.localizedDescription)"
            }
        }
    }

    /// Length of the desktop segment that loops while locked.
    static let defaultDuration: TimeInterval = 2 * 60

    /// The finished recording lives in the app's Application Support folder.
    static var recordingURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "AlienScreenSaver", isDirectory: true)
        return folder.appendingPathComponent("DesktopRecording.mp4")
    }

    static var hasRecording: Bool {
        FileManager.default.fileExists(atPath: recordingURL.path)
    }

    /// True once macOS has granted this app Screen Recording access.
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // Frames arrive and are written on this queue; `stream` is touched on main only.
    private let queue = DispatchQueue(label: "com.mybrightzone.alien.desktop-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var tempURL: URL?
    private var firstFrameTime: CMTime?
    private var firstFrameDate: Date?
    private var lastFrameTime: CMTime?
    private var lastPixelBuffer: CVPixelBuffer?
    private var stopWorkItem: DispatchWorkItem?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var isFinishing = false
    private var isCancelled = false

    /// Records the main display for `duration` seconds. `completion` runs on the
    /// main queue with the URL of the saved movie, or the reason it failed.
    func start(duration: TimeInterval = DesktopRecorder.defaultDuration,
               completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion

        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt; access only takes effect after the app relaunches.
            CGRequestScreenCaptureAccess()
            finish(.failure(RecorderError.permissionDenied))
            return
        }

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try self.beginCapture(content: content, duration: duration)
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    /// Ends the recording early. Whatever was recorded so far is kept.
    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let stream = stream else {
            // Capture hasn't started (or already ended). Still report back so the
            // caller isn't left waiting with the recording panel on screen.
            isCancelled = true
            queue.async { self.finishWriting(streamError: nil) }
            return
        }
        self.stream = nil
        stream.stopCapture { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                self.finishWriting(streamError: error)
            }
        }
    }

    // MARK: - Capture

    @MainActor
    private func beginCapture(content: SCShareableContent, duration: TimeInterval) throws {
        // stop() may have been called while shareable content was being fetched.
        guard !isCancelled else { return }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }

        // Capture at native pixel size so text stays sharp on Retina displays.
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let scale = Int(screen?.backingScaleFactor ?? 2)
        // H.264 needs even dimensions.
        let width = (display.width * scale) / 2 * 2
        let height = (display.height * scale) / 2 * 2

        // Leave our own windows (the recording HUD) out of the capture.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5

        try setUpWriter(width: width, height: height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream

        stream.startCapture { error in
            DispatchQueue.main.async {
                self.captureDidStart(error: error, duration: duration)
            }
        }
    }

    /// Runs on main once the stream has started (or failed to). Arms the timer
    /// that ends the recording after `duration`.
    private func captureDidStart(error: Error?, duration: TimeInterval) {
        if let error = error {
            stream = nil
            queue.async { self.finishWriting(streamError: error) }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func setUpWriter(width: Int, height: Int) throws {
        let folder = DesktopRecorder.recordingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Write to a scratch file first so a failed attempt never clobbers a good recording.
        let tempURL = folder.appendingPathComponent("DesktopRecording-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer(nil) }
        writer.add(input)
        // The adaptor must exist before the writer starts; creating it afterwards
        // raises an NSInvalidArgumentException and no frames are ever written.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw RecorderError.writer(writer.error) }

        self.adaptor = adaptor
        self.writer = writer
        self.input = input
        self.tempURL = tempURL
    }

    // MARK: - Finishing (runs on `queue`)

    private func finishWriting(streamError: Error?) {
        guard !isFinishing else { return }
        isFinishing = true

        guard let writer = writer, let input = input, let tempURL = tempURL else {
            if isCancelled {
                finish(.failure(RecorderError.cancelled))
            } else {
                finish(.failure(streamError.map(RecorderError.stream) ?? RecorderError.writer(nil)))
            }
            return
        }
        guard writer.status == .writing, let firstTime = firstFrameTime, let firstDate = firstFrameDate else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            finish(.failure(streamError.map(RecorderError.stream) ?? RecorderError.writer(writer.error)))
            return
        }

        // ScreenCaptureKit only delivers frames when something on screen changes, so a
        // still desktop would end the movie early. Pad to the real elapsed time by
        // repeating the last frame.
        let elapsed = CMTime(seconds: Date().timeIntervalSince(firstDate), preferredTimescale: firstTime.timescale)
        let endTime = firstTime + elapsed
        if let last = lastPixelBuffer, let lastTime = lastFrameTime, endTime > lastTime, input.isReadyForMoreMediaData {
            adaptor?.append(last, withPresentationTime: endTime)
        }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        writer.finishWriting {
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: tempURL)
                self.finish(.failure(RecorderError.writer(writer.error)))
                return
            }
            do {
                let finalURL = DesktopRecorder.recordingURL
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                self.finish(.success(finalURL))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        DispatchQueue.main.async {
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension DesktopRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !isFinishing,
              let writer = writer, let input = input, let adaptor = adaptor,
              writer.status == .writing else { return }

        // Only complete frames carry new pixels; idle and blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstFrameTime == nil {
            firstFrameTime = time
            firstFrameDate = Date()
            writer.startSession(atSourceTime: time)
        }
        if let last = lastFrameTime, time <= last { return }
        guard input.isReadyForMoreMediaData else { return }

        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastFrameTime = time
            lastPixelBuffer = pixelBuffer
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 12.3, *)
extension DesktopRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.stream = nil
        }
        queue.async { self.finishWriting(streamError: error) }
    }
}
