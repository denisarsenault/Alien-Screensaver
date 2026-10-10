//  AlienPreviewView.swift
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
import AlienScreenSaverCore
import MediaPlayer
import AVKit
import AVFoundation

/// Preview shown in the preferences sheet: plays AlienMovie.mp4 on a loop,
/// starting as soon as the view is placed in a window.
final class AlienPreviewView: NSView {
    private lazy var Alien = AlienClock(with: Preferences.shared)

    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
            context.fill(dirtyRect)
            //Alien.draw(in: dirtyRect, context: context)
        }
    }

    // MARK: - Movie playback

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMovie()
        } else {
            startMovie()
        }
    }

    private func startMovie() {
        // The .saver bundle is loaded by a host process, so Bundle.main would be the
        // host app. Look the movie up in this class's own bundle instead.
        guard player == nil,
              let url = Bundle(for: AlienPreviewView.self).url(forResource: "AlienMovie", withExtension: "mp4") else {
            return
        }

        // On macOS there is no AVPlayerViewController; AVPlayerView is the AVKit equivalent.
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView(frame: bounds)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.player = player
        addSubview(playerView)

        // Loop: when the item finishes, rewind and play again.
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        self.player = player
    }

    private func stopMovie() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObserver = nil
        player?.pause()
        player = nil
        subviews.compactMap { $0 as? AVPlayerView }.forEach { $0.removeFromSuperview() }
    }
}
