//
//  GameHealthMonitor+Display.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import CoreGraphics
import os.log

extension GameHealthMonitor {
    // MARK: - Display inspection

    nonisolated func currentModeNumber() -> Int32? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSGetCurrentDisplayMode") else { return nil }
        typealias GetMode = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
        let getMode = unsafeBitCast(symbol, to: GetMode.self)
        var mode: Int32 = -1
        _ = getMode(CGMainDisplayID(), &mode)
        return mode >= 0 ? mode : nil
    }

    /// Density is read from the mode description. A density of 2.0 means a
    /// scaled HiDPI mode, which is what the desktop runs.
    ///
    /// The offset is VERIFIED, not assumed: on this machine the description
    /// for the live scaled mode carries 2.0 at 0xD0. Reading 0xD8 instead
    /// (four bytes past it) returned 0.0, which made this check call the
    /// healthy desktop "non-HiDPI" and fire a false fault seconds after
    /// launch — and because it never passed its own test, no healthy mode was
    /// ever recorded, so the repair had nothing to restore to either.
    /// Layout: mode, flags, width, height, depth, 170 reserved, freq,
    /// 16 more, then the density float at 0xD0.
    nonisolated func isHiDPIMode(_ modeNumber: Int32) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSGetDisplayModeDescriptionOfLength") else { return false }
        typealias GetDesc = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
        let getDesc = unsafeBitCast(symbol, to: GetDesc.self)

        var storage = [UInt8](repeating: 0, count: 0xDC)
        let result = storage.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return getDesc(CGMainDisplayID(), modeNumber, base, 0xDC)
        }
        guard result == 0 else { return false }
        let density = storage.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xD0, as: Float.self) }
        return density >= 1.9
    }

}
