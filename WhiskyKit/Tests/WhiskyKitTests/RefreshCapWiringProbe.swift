//
//  RefreshCapWiringProbe.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

/// Prints the literal resolved environment for a program with a refresh-rate
/// cap set and for one without, through the real `constructWineEnvironment`
/// entry point a launch uses. Not an assertion suite -- it is the raw evidence
/// for the wiring, so the values are the output.
@Suite("Refresh Cap Wiring Probe")
struct RefreshCapWiringProbe {
    @Test("Literal resolved WHISKY_MAX_REFRESH_HZ for a capped and an uncapped program")
    @MainActor func literalResolvedValues() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        bottle.settings.graphicsBackend = .d3dMetal

        var capped = ProgramOverrides()
        capped.refreshRateCap = 60

        let cappedEnv = Wine.constructWineEnvironment(for: bottle, programOverrides: capped)
        let uncappedEnv = Wine.constructWineEnvironment(for: bottle, programOverrides: ProgramOverrides())
        let nilOverridesEnv = Wine.constructWineEnvironment(for: bottle, programOverrides: nil)

        print("PROBE cap=60   -> WHISKY_MAX_REFRESH_HZ=\(cappedEnv["WHISKY_MAX_REFRESH_HZ"] ?? "<absent>")")
        print("PROBE cap=nil  -> WHISKY_MAX_REFRESH_HZ=\(uncappedEnv["WHISKY_MAX_REFRESH_HZ"] ?? "<absent>")")
        print("PROBE no-ovr   -> WHISKY_MAX_REFRESH_HZ=\(nilOverridesEnv["WHISKY_MAX_REFRESH_HZ"] ?? "<absent>")")

        #expect(cappedEnv["WHISKY_MAX_REFRESH_HZ"] == "60")
        #expect(uncappedEnv["WHISKY_MAX_REFRESH_HZ"] == nil)
        #expect(nilOverridesEnv["WHISKY_MAX_REFRESH_HZ"] == nil)
    }
}
