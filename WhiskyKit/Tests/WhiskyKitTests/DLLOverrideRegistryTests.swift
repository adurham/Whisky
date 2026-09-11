//
//  DLLOverrideRegistryTests.swift
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

@testable import WhiskyKit
import XCTest

final class DLLOverrideRegistryTests: XCTestCase {
    // MARK: - Scope keys

    func testBottleScopeUsesPrefixDefaultKey() {
        XCTAssertEqual(
            Wine.DLLOverrideScope.bottle.registryKey,
            #"HKCU\Software\Wine\DllOverrides"#
        )
    }

    func testProgramScopeIsKeyedOnTheExecutable() {
        XCTAssertEqual(
            Wine.DLLOverrideScope.program("steam.exe").registryKey,
            #"HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides"#
        )
    }

    /// Two executables must land in different keys, which is the whole point:
    /// an environment variable could not separate a launcher from the games it
    /// spawns.
    func testProgramScopesDoNotCollide() {
        XCTAssertNotEqual(
            Wine.DLLOverrideScope.program("steam.exe").registryKey,
            Wine.DLLOverrideScope.program("steamwebhelper.exe").registryKey
        )
    }

    // MARK: - Parsing

    func testParsesDXVKPreset() {
        let parsed = Wine.parseDLLOverrides("d3d10core=n,b;d3d11=n,b;d3d9=n,b;dxgi=n,b")
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed["d3d11"], "n,b")
        XCTAssertEqual(parsed["dxgi"], "n,b")
    }

    func testParsesBuiltinOnlyModes() {
        let parsed = Wine.parseDLLOverrides("dxgi=b;winemetal=b")
        XCTAssertEqual(parsed["dxgi"], "b")
        XCTAssertEqual(parsed["winemetal"], "b")
    }

    /// `dll=` with no value is how a DLL is disabled, in both the variable and
    /// the registry, so it has to survive the round trip rather than be dropped.
    func testKeepsDisabledOverrides() {
        let parsed = Wine.parseDLLOverrides("mscoree=;mshtml=")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["mscoree"], "")
    }

    func testEmptyStringYieldsNoOverrides() {
        XCTAssertTrue(Wine.parseDLLOverrides("").isEmpty)
    }

    func testIgnoresEmptyClausesAndWhitespace() {
        let parsed = Wine.parseDLLOverrides(" d3d11=n,b ;; dxgi=b ;")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["d3d11"], "n,b")
        XCTAssertEqual(parsed["dxgi"], "b")
    }

    func testLastClauseWinsForARepeatedDLL() {
        let parsed = Wine.parseDLLOverrides("d3d11=n,b;d3d11=b")
        XCTAssertEqual(parsed["d3d11"], "b")
    }

    // MARK: - Launcher helpers

    /// The reason this exists: steam draws its whole client in the webhelper,
    /// and AppDefaults is per executable with no inheritance, so an override on
    /// steam.exe alone leaves the window blank.
    func testSteamCarriesItsHelpersAlong() {
        let helpers = Wine.helperExecutables(for: URL(filePath: "/B/Steam/steam.exe"))
        XCTAssertTrue(helpers.contains("steamwebhelper.exe"))
    }

    func testAGameIsNotALauncherAndCarriesNothing() {
        let url = URL(filePath: "/B/Steam/steamapps/common/Some Game/game.exe")
        XCTAssertTrue(Wine.helperExecutables(for: url).isEmpty)
    }

    func testUnknownExecutableCarriesNothing() {
        XCTAssertTrue(Wine.helperExecutables(for: URL(filePath: "/B/thing.exe")).isEmpty)
    }

    /// A helper must never be listed as its own helper, or a launch would write
    /// the same scope twice.
    func testNoLauncherListsItself() {
        for launcher in LauncherType.allCases {
            XCTAssertFalse(
                launcher.helperExecutables.contains { $0.lowercased().contains("steam.exe") },
                "\(launcher) lists a launcher executable as a helper"
            )
        }
    }

    // MARK: - Registry document

    func testDocumentReplacesEachKey() {
        let doc = Wine.registryDocument(for: [
            (key: #"HKCU\Software\Wine\DllOverrides"#, overrides: ["d3d11": "n,b"])
        ])
        XCTAssertTrue(doc.hasPrefix("Windows Registry Editor Version 5.00"))
        // the delete has to come before the write, or it removes what it just wrote
        let deleteAt = doc.range(of: #"[-HKCU\Software\Wine\DllOverrides]"#)
        let writeAt = doc.range(of: #"[HKCU\Software\Wine\DllOverrides]"#)
        XCTAssertNotNil(deleteAt)
        XCTAssertNotNil(writeAt)
        if let deleteAt, let writeAt {
            XCTAssertLessThan(deleteAt.lowerBound, writeAt.lowerBound)
        }
        XCTAssertTrue(doc.contains(#""d3d11"="n,b""#))
    }

    /// An empty scope must still be deleted, since clearing a backend has to
    /// remove what the previous one wrote.
    func testEmptyScopeDeletesWithoutRewriting() {
        let doc = Wine.registryDocument(for: [(key: #"HKCU\X"#, overrides: [:])])
        XCTAssertTrue(doc.contains(#"[-HKCU\X]"#))
        XCTAssertFalse(doc.contains("\r\n[HKCU\\X]"))
    }

    func testAllScopesLandInOneDocument() {
        let doc = Wine.registryDocument(for: [
            (key: #"HKCU\A"#, overrides: ["d3d11": "n,b"]),
            (key: #"HKCU\B"#, overrides: ["dxgi": "b"])
        ])
        XCTAssertTrue(doc.contains(#"[HKCU\A]"#))
        XCTAssertTrue(doc.contains(#"[HKCU\B]"#))
        XCTAssertTrue(doc.contains(#""dxgi"="b""#))
    }

    func testValuesAreOrderedDeterministically() {
        let doc = Wine.registryDocument(for: [
            (key: #"HKCU\A"#, overrides: ["dxgi": "b", "d3d11": "n,b", "d3d9": "n,b"])
        ])
        guard let d3d11 = doc.range(of: #""d3d11""#)?.lowerBound,
              let d3d9 = doc.range(of: #""d3d9""#)?.lowerBound,
              let dxgi = doc.range(of: #""dxgi""#)?.lowerBound
        else { return XCTFail("document is missing one of the overrides") }
        XCTAssertLessThan(d3d11, d3d9)
        XCTAssertLessThan(d3d9, dxgi)
    }

    func testDocumentUsesCRLF() {
        let doc = Wine.registryDocument(for: [(key: #"HKCU\A"#, overrides: ["d3d11": "n,b"])])
        XCTAssertTrue(doc.contains("\r\n"))
    }

    // MARK: - Encoding

    func testWrittenDocumentStartsWithAUTF16LEBOM() throws {
        // Wine detects a Unicode .reg by its BOM alone. Without one the file parses
        // as ANSI, matches no header, and the import silently does nothing.
        let doc = Wine.registryDocument(for: [(key: #"HKCU\A"#, overrides: ["d3d11": "n,b"])])
        let url = FileManager.default.temporaryDirectory.appending(path: "bom-\(UUID().uuidString).reg")
        try ("\u{FEFF}" + doc).write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        let head = try Data(contentsOf: url).prefix(2)
        XCTAssertEqual(Array(head), [0xFF, 0xFE], "expected a little-endian BOM")
    }

    func testWrittenDocumentRoundTripsThroughAUTF16Reader() throws {
        let doc = Wine.registryDocument(for: [(key: #"HKCU\A"#, overrides: ["d3d11": "n,b"])])
        let url = FileManager.default.temporaryDirectory.appending(path: "rt-\(UUID().uuidString).reg")
        try ("\u{FEFF}" + doc).write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        // Reading without naming an encoding is what a BOM is for.
        let read = try String(contentsOf: url)
        XCTAssertTrue(read.hasPrefix("\u{FEFF}Windows Registry Editor Version 5.00"))
        XCTAssertTrue(read.contains(#""d3d11"="n,b""#))
    }

    // MARK: - Rendering safety

    func testAcceptsRealDLLNamesAndModes() {
        for dll in ["d3d11", "d3d10core", "dxgi", "nvapi64", "api-ms-win-crt-runtime-l1-1-0", "d3dx9_43"] {
            XCTAssertTrue(Wine.isRenderable(dll: dll, mode: "native,builtin"), dll)
        }
        for mode in ["native", "builtin", "native,builtin", "builtin,native", ""] {
            XCTAssertTrue(Wine.isRenderable(dll: "d3d11", mode: mode), mode)
        }
    }

    func testRejectsNamesThatWouldBreakOutOfTheValue() {
        // A quote or backslash terminates the value early and corrupts every
        // later scope in the same document.
        for dll in [#"d3d11""#, #"d3d11\"#, "d3d11]\n[HKCU\\Evil", "", "d3d 11", "d3d11;dxgi"] {
            XCTAssertFalse(Wine.isRenderable(dll: dll, mode: "native"), dll.debugDescription)
        }
        for mode in [#"native""#, #"n\b"#, "native]"] {
            XCTAssertFalse(Wine.isRenderable(dll: "d3d11", mode: mode), mode.debugDescription)
        }
    }

    func testOneBadOverrideDoesNotTakeTheDocumentDown() {
        let doc = Wine.registryDocument(for: [
            (key: #"HKCU\A"#, overrides: [#"bad"name"#: "native", "d3d11": "native,builtin"])
        ])
        XCTAssertTrue(doc.contains(#""d3d11"="native,builtin""#), "the good override must survive")
        XCTAssertFalse(doc.contains("bad"), "the unrenderable one must be dropped")
        // Exactly one value line, so nothing was left half-written.
        XCTAssertEqual(doc.components(separatedBy: "\r\n").filter { $0.hasPrefix("\"") }.count, 1)
    }

    func testScopeWhoseOverridesAreAllUnrenderableIsStillPruned() {
        let doc = Wine.registryDocument(for: [(key: #"HKCU\A"#, overrides: [#"bad"name"#: "native"])])
        XCTAssertTrue(doc.contains(#"[-HKCU\A]"#), "the prune must still be emitted")
        XCTAssertFalse(doc.contains(#"[HKCU\A]"#), "no empty key should be recreated")
    }

    // MARK: - Launcher-scoped DXVK

    /// Steam's client cannot present on D3DMetal, so it needs DXVK -- but only
    /// on its own processes, or the games it spawns lose D3DMetal too.
    func testSteamScopesDXVKToItsOwnProcesses() {
        XCTAssertEqual(LauncherType.steam.dxvkScope, .launcherProcesses)
    }

    /// Rockstar has always taken DXVK bottle-wide. Narrowing it would change
    /// which backend its games run on, which is not this change.
    func testRockstarKeepsBottleWideDXVK() {
        XCTAssertEqual(LauncherType.rockstar.dxvkScope, .bottle)
    }

    /// `requiresDXVK` gates the prefix DLL copy in `runProgram`, so it has to
    /// stay true for both scopes or Steam gets overrides pointing at DLLs that
    /// were never deployed.
    func testRequiresDXVKCoversBothScopes() {
        XCTAssertTrue(LauncherType.steam.requiresDXVK)
        XCTAssertTrue(LauncherType.rockstar.requiresDXVK)
        XCTAssertFalse(LauncherType.epicGames.requiresDXVK)
    }

    func testApplyingMergesPresetOverExistingOverrides() {
        let merged = Wine.applying(DLLOverrideResolver.dxvkPreset, to: "dxgi=b;nvapi64=")
        let parsed = Wine.parseDLLOverrides(merged)
        // The preset wins on the DLLs it names.
        XCTAssertEqual(parsed["dxgi"], "n,b")
        XCTAssertEqual(parsed["d3d11"], "n,b")
        // d3d12 is disabled by the preset, which is an empty value, not absence.
        XCTAssertEqual(parsed["d3d12"], "")
        // Anything the preset does not name survives.
        XCTAssertEqual(parsed["nvapi64"], "")
    }

    func testApplyingLeavesUnrelatedOverridesAlone() {
        let merged = Wine.applying(DLLOverrideResolver.dxvkPreset, to: "winemenubuilder=")
        XCTAssertEqual(Wine.parseDLLOverrides(merged)["winemenubuilder"], "")
    }

    /// The bug this change fixes: with the preset merged only into the bottle
    /// scope, every child inherits it and games lose D3DMetal. The launcher's
    /// DXVK has to live in `AppDefaults`, which wine does not propagate.
    func testLauncherScopedDXVKDoesNotLandInTheBottleScope() {
        var builder = EnvironmentBuilder()
        var settings = BottleSettings()
        settings.autoEnableDXVK = true
        settings.launcherCompatibilityMode = true
        settings.detectedLauncher = .steam

        let overrides = settings.populateLauncherManagedLayer(builder: &builder)

        XCTAssertFalse(
            overrides.contains { $0.entry.dllName == "dxgi" },
            "Steam's DXVK must not reach the bottle-wide overrides"
        )
    }

    /// The same path for Rockstar must keep filling the bottle scope.
    func testBottleScopedLauncherStillPopulatesTheBottleOverrides() {
        var builder = EnvironmentBuilder()
        var settings = BottleSettings()
        settings.autoEnableDXVK = true
        settings.launcherCompatibilityMode = true
        settings.detectedLauncher = .rockstar

        let overrides = settings.populateLauncherManagedLayer(builder: &builder)

        XCTAssertTrue(
            overrides.contains { $0.entry.dllName == "dxgi" },
            "Rockstar's DXVK must still apply bottle-wide"
        )
    }

    /// The scope has to be reachable from the launched URL alone. Reading it
    /// from `settings.detectedLauncher` silently did nothing: that field tracks
    /// the launcher-fixes opt-in and is nil on bottles that never enabled it,
    /// so Steam's client kept falling through to the bottle backend and drew a
    /// black window.
    func testLauncherScopeIsDetectableFromTheLaunchedURL() {
        let steamURL = URL(filePath: "/Program Files (x86)/Steam/steam.exe")
        XCTAssertEqual(LauncherType.detect(from: steamURL)?.dxvkScope, .launcherProcesses)

        // A game under steamapps must NOT be treated as the launcher, or it
        // would be handed DXVK and lose D3DMetal -- the exact regression this
        // whole change exists to prevent.
        let gameURL = URL(filePath: "/Program Files (x86)/Steam/steamapps/common/DS3/game.exe")
        XCTAssertNil(LauncherType.detect(from: gameURL)?.dxvkScope)
    }
}
