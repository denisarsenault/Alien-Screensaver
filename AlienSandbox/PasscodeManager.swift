//  PasscodeManager.swift
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

import Foundation
import Security
import CommonCrypto

/// Stores and verifies the lock passcode as a salted SHA-256 hash in UserDefaults.
enum PasscodeManager {
    private static let saltKey = "LockPasscodeSalt"
    private static let hashKey = "LockPasscodeHash"

    static var isSet: Bool {
        UserDefaults.standard.data(forKey: hashKey) != nil
    }

    static func set(_ passcode: String) {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let saltData = Data(salt)
        UserDefaults.standard.set(saltData, forKey: saltKey)
        UserDefaults.standard.set(hash(passcode, salt: saltData), forKey: hashKey)
    }

    static func verify(_ passcode: String) -> Bool {
        guard let salt = UserDefaults.standard.data(forKey: saltKey),
              let stored = UserDefaults.standard.data(forKey: hashKey) else {
            return false
        }
        return hash(passcode, salt: salt) == stored
    }

    private static func hash(_ passcode: String, salt: Data) -> Data {
        var input = salt
        input.append(Data(passcode.utf8))
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(input.count), &digest)
        }
        return Data(digest)
    }
}
