//  Copyright 2019 Denis Arsenault
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
import AVKit
import AVFoundation
import AlienScreenSaverCore


class MainConfiguration: Configuration {
    var primaryColor: NSColor = .orange
    var reverse: Bool = false
    var twentyFourHours: Bool = true
    var twelveHours: Bool = false
    var drawEmptyDigits: Bool = false
}

class AlienView: NSView {
    private var timer: Timer?
    private lazy var Alien = AlienClock(with: MainConfiguration())
    
    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        
        timer = Timer.scheduledTimer(
            timeInterval: 0.16,
            target: self,
            selector: #selector(animationLoopEventHandler),
            userInfo: nil,
            repeats: true
        )
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
            context.fill(dirtyRect)
            // Alien.draw(in: dirtyRect, context: context) // For alien clock
            
            // Play movie in rectangle
            
            //Converted to Swift 5.3 by Swiftify v5.3.29144 - https://swiftify.com/
            guard let path = Bundle.main.path(forResource: "SampleVideo", ofType: "mp4") else {
                return
            }
            let videoURL = NSURL(fileURLWithPath: path)

            //filePath may be from the Bundle or from the Saved file Directory, it is just the path for the video
            let player = AVPlayer(url: videoURL as URL)
            let playerViewController = AVPlayerViewController()
            playerViewController.player = player

            //[playerViewController.player play];//Used to Play On start
            present(playerViewController, animated: true)

            let player = AVPlayer(url: videoURL)
            let vc = self
            vc.player = player

            present(vc, animated: true) {
                vc.player?.play()
            }
//
//            NSURL *videoURL = [NSURL fileURLWithPath:filePath];
//           filePath may be from the Bundle or from the Saved file Directory, it is just the path for the video
//           AVPlayer *player = [AVPlayer playerWithURL:videoURL];
//           AVPlayerViewController *playerViewController = [AVPlayerViewController new];
//           playerViewController.player = player;
//           //[playerViewController.player play];//Used to Play On start
//           [self presentViewController:playerViewController animated:YES completion:nil];
            
        }
    }
    
    //MARK: - Timer
    
    @objc func animationLoopEventHandler() {
        self.setNeedsDisplay(self.bounds)
    }
}
