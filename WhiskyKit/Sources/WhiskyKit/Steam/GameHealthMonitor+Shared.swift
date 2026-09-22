//
//  GameHealthMonitor+Shared.swift
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
import os.log

extension GameHealthMonitor {
    /// The monitor the running app uses.
    ///
    /// Only the app knows which bottles and games exist (that lives in the
    /// view-model layer), so it supplies the game list once at launch. Keeping
    /// a single instance matters: two monitors could disagree about whether a
    /// game is running and fight over the display.
    public static let shared = GameHealthMonitor(
        configuration: .whiskyDefault(gameImageNames: [])
    )

    /// Supplies the game list once the app has enumerated its libraries.
    ///
    /// Called from the app after bottles load.
    public func registerGames(imageNames: Set<String>) {
        let normalised = Set(imageNames.map { $0.lowercased() }
            .filter { $0.hasSuffix(".exe") })
        guard !normalised.isEmpty else { return }
        mergeGameImageNames(normalised)
    }
}

extension GameHealthMonitor.Configuration {
    /// Configuration for the running app: an evidence directory under
    /// Application Support, and a display restore that goes through the same
    /// helper that owns the display mode.
    public static func whiskyDefault(gameImageNames: Set<String>) -> GameHealthMonitor.Configuration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Whisky/GameHealth", isDirectory: true)

        return GameHealthMonitor.Configuration(
            gameImageNames: gameImageNames,
            evidenceDirectory: support,
            restoreDisplay: { modeNumber in
                await Self.restoreDisplay(modeNumber: modeNumber)
            }
        )
    }

    /// Restores the display by running the mode helper, which is the only
    /// thing that can set a scaled HiDPI mode (it is not reachable through
    /// public CoreGraphics).
    ///
    /// Returns whether the helper reported success. Callers should still verify
    /// by re-reading the mode rather than trusting this value alone.
    public static func restoreDisplay(modeNumber: Int32) async -> Bool {
        await Task.detached {
            guard let helper = modeHelperURL() else { return false }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--cgsapply", String(modeNumber)]
            var environment = ProcessInfo.processInfo.environment
            // The helper is a plain CoreGraphics binary; a dyld injection
            // inherited from the calling context would kill it before it runs.
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            environment.removeValue(forKey: "DYLD_FORCE_FLAT_NAMESPACE")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    /// The mode helper lives in the installed engine tree, which an engine
    /// update replaces — so it is looked up on each call rather than cached.
    public static func modeHelperURL() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let helper = support
            .appendingPathComponent("com.franke.Whisky/Libraries/Wine/bin/mode-fixup")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }
}

