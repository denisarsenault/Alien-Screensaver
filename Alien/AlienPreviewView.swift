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
import AlienScreenSaverCore
import MediaPlayer
import AVKit
import AVFoundation

final class AlienPreviewView: NSView {
    private lazy var Alien = AlienClock(with: Preferences.shared)
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
            context.fill(dirtyRect)
            //Alien.draw(in: dirtyRect, context: context)
            
            
        }
    }
    
//    func PlayMovie() -> Bool {
//        guard let path = Bundle.main.path(forResource: "AlienMovie", ofType: "mp4") else
//        { return false }
//
//        let pathURL = NSURL.fileURL(withPath: path)
//
//        let myPlayer =Ap
//        //let myPlayer = MPMoviePlayerViewController(contentURL: pathURL) myPlayer.moviePlayer.repeatMode = .None
//
//        presentMoviePlayerViewControllerAnimated(myPlayer)
//
//    }
    private func playVideo()
    {
        guard let path = Bundle.main.path(forResource: "AlienMovie", ofType: "mp4") else {
            return
        }
        let videoURL = NSURL(fileURLWithPath: path)

        // Create an AVPlayer, passing it the local video url path
        let player = AVPlayer(url: videoURL as URL)
        let controller = AlienPreviewView()
        controller.player = player
        present(controller, animated: true)
        {
            player.play()
        }
//        guard let path = Bundle.main.path(forResource: "AlienMovie", ofType: "mp4") else
//        {
//                return
//        }
//
//        let videoURL = NSURL(fileURLWithPath: path)
//
//        // Create an AVPlayer, passing it the local video url path
//        let player = AVPlayer(url: videoURL as URL)
//        //let controller = AVPlayerViewController()
//        let controller = AVPlayerViewController()
//        controller.player = player
//        present(controller, animated: true)
//        {
//            player.play()
//        }
    }

}
