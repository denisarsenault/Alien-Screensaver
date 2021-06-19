//
//  Configuration.swift
//  AlienCore
//
//  Created by Denis Arsenault on 21/05/2019.
//  Copyright © 2019 Denis Arsenault. All rights reserved.
//

import Foundation
import AppKit

public protocol Configuration {
    var primaryColor: NSColor { get }
    var reverse: Bool { get }
    var twentyFourHours: Bool { get }
    var twelveHours: Bool { get }
    var drawEmptyDigits: Bool { get }
}
