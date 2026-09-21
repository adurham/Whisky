//
//  DLLOverrideSyncSafetyTests.swift
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

/// The regression this file exists for: a launch must never destroy DLL
/// overrides it did not write.
///
/// Whisky's model is one graphics backend per bottle, re-asserted at launch. A
/// bottle can be configured deliberately against that model — a launcher on DXVK
/// while the games it starts keep D3DMetal — and the only safe way to re-assert
/// the model is to write what a launch owns and leave everything else alone.
/// The old sync did a destructive replace of the whole key, so a bottle whose
/// backend contributed no overrides (D3DMetal) rendered an empty document and
/// emptied the global key, taking the user's settings with it and leaving
/// Steam's Chromium client on a backend it cannot render.
final class DLLOverrideSyncSafetyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The launch cycle

    /// **The regression test.** A bottle with hand-set global overrides and a
    /// hand-set per-executable `AppDefaults` entry, launched with a backend that
    /// contributes nothing (D3DMetal, exactly the user's case), must still hold
    /// both afterwards.
    ///
    /// The check is on the document the launch would import, because that is the
    /// entire registry side effect of a sync — and the guarantee is structural:
    /// a document that names neither key cannot modify either.
    func testHandSetOverridesSurviveAD3DMetalLaunch() {
        let globalKey = #"HKCU\Software\Wine\DllOverrides"#
        let steamKey = #"HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides"#

        // What a D3DMetal launch contributes: nothing at the bottle scope, and
        // nothing for the user's own AppDefaults entry. Both keys are simply
        // absent from the plan.
        let document = Wine.registryDocument(
            for: [
                Wine.DLLOverrideWrite(
                    key: globalKey,
                    overrides: Wine.parseDLLOverrides(""),
                    remove: []
                )
            ]
        )

        XCTAssertTrue(document.isEmpty, "a backend with no overrides must write nothing at all")
        XCTAssertFalse(document.contains(globalKey), "the global key must not be touched")
        XCTAssertFalse(document.contains(steamKey), "the AppDefaults entry must not be touched")
        XCTAssertFalse(document.contains("[-"), "no delete-key line may ever be emitted")
    }

    /// The other half of the same guarantee: a launch that *does* have overrides
    /// (DXVK on the bottle) merges them in without naming anything else.
    func testADXVKLaunchMergesWithoutNamingTheUsersValues() {
        let document = Wine.registryDocument(
            for: [
                Wine.DLLOverrideWrite(
                    key: #"HKCU\Software\Wine\DllOverrides"#,
                    overrides: Wine.parseDLLOverrides("dxgi=n,b;d3d11=n,b"),
                    remove: []
                )
            ]
        )
        XCTAssertFalse(document.contains("[-"), "a merge, not a replace")
        XCTAssertTrue(document.contains(#""dxgi"="n,b""#))
        // Nothing else may be mentioned: a line for a name the launch does not
        // own would overwrite it.
        XCTAssertEqual(document.components(separatedBy: "\r\n").filter { $0.hasPrefix("\"") }.count, 2)
    }

    /// Hand-set `AppDefaults` entries survive a launcher-scoped launch because a
    /// launch only ever merges its own names in.
    func testHandSetAppDefaultsSurvivesALauncherScopedLaunch() {
        // The launch writes dxgi=n,b to steam.exe, as launcher-scoped DXVK does.
        let document = Wine.registryDocument(
            for: [
                Wine.DLLOverrideWrite(
                    key: #"HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides"#,
                    overrides: Wine.parseDLLOverrides("dxgi=n,b"),
                    remove: []
                )
            ]
        )
        XCTAssertFalse(document.contains("[-"))
        XCTAssertTrue(document.contains(#""dxgi"="n,b""#))
        XCTAssertEqual(
            document.components(separatedBy: "\r\n").filter { $0.hasPrefix("\"") }.count, 1,
            "only dxgi may be named; a hand-set d3d9 or nvapi64 entry must not appear"
        )
    }

    /// A bottle whose overrides are declared user-managed is left alone by the
    /// sync entirely, which is the opt-out for configurations the model cannot
    /// express.
    func testUserManagedOptOutIsOffByDefaultAndSettable() {
        var settings = BottleSettings()
        XCTAssertFalse(settings.dllOverridesAreUserManaged, "managed by Whisky by default")
        settings.dllOverridesAreUserManaged = true
        XCTAssertTrue(settings.dllOverridesAreUserManaged)
    }

    func testUserManagedOptOutRoundTripsThroughTheSettingsFile() throws {
        var settings = BottleSettings()
        settings.dllOverridesAreUserManaged = true
        let url = tempDir.appending(path: "Metadata.plist")
        try settings.encode(to: url)

        let decoded = try BottleSettings.decode(from: url)
        XCTAssertTrue(decoded.dllOverridesAreUserManaged)
    }

    // MARK: - Reading the prefix back

    /// `reg query /s` output must resolve to key to name to mode, and only for
    /// `DllOverrides` keys — the subtree holds every other Wine setting too.
    ///
    /// The header spelling matters: `reg query` prints `HKEY_CURRENT_USER\...`
    /// while the scope keys are `HKCU\...`, so the parser has to normalise or the
    /// lookup silently misses and every launch rewrites a registry it already
    /// agreed with.
    func testQueryOutputIsParsedIntoKeysAndValues() {
        // Raw strings so the backslashes are literal, joined with real CRLF as
        // `reg query` emits them.
        let output = [
            #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#,
            "    d3d10core    REG_SZ    builtin",
            "    dxgi    REG_SZ    builtin",
            "    d3d12    REG_SZ    ",
            "",
            #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\steam.exe\DllOverrides"#,
            "    dxgi    REG_SZ    native,builtin",
            "",
            #"HKEY_CURRENT_USER\Software\Wine\Explorer"#,
            "    Desktop    REG_SZ    Default"
        ].joined(separator: "\r\n")
        let parsed = Wine.parseDLLOverrideQuery(output)
        XCTAssertEqual(parsed.count, 2, "only DllOverrides keys may be returned")
        XCTAssertEqual(
            parsed[Wine.DLLOverrideScope.bottle.registryKey]?["dxgi"], "builtin",
            "the header must be normalised to the scope key's spelling"
        )
        XCTAssertEqual(parsed[Wine.DLLOverrideScope.bottle.registryKey]?["d3d12"], "")
        XCTAssertEqual(
            parsed[Wine.DLLOverrideScope.program("steam.exe").registryKey]?["dxgi"], "native,builtin"
        )
        XCTAssertNil(
            parsed[#"HKCU\Software\Wine\Explorer"#], "a non-DllOverrides key must not be returned"
        )
    }

    /// `native,builtin` and `n,b` are one instruction in two spellings, so a
    /// value already on disk that resolves as the launch wants it must count as
    /// matching and be left exactly as written.
    func testEquivalentSpellingsCompareEqual() {
        XCTAssertEqual(Wine.canonicalMode("native,builtin"), Wine.canonicalMode("n,b"))
        XCTAssertEqual(Wine.canonicalMode("native"), Wine.canonicalMode("n"))
        XCTAssertEqual(Wine.canonicalMode("builtin"), Wine.canonicalMode("b"))
        XCTAssertEqual(Wine.canonicalMode(""), "")
        // Order between the two halves is meaningful and must survive.
        XCTAssertNotEqual(Wine.canonicalMode("n,b"), Wine.canonicalMode("b,n"))
        XCTAssertNotEqual(Wine.canonicalMode("builtin"), Wine.canonicalMode("native"))
    }

    // MARK: - Authorship record

    /// Only what a launch wrote may be taken back, and only while the value on
    /// disk is still the one it left.
    func testAuthorshipRoundTripsOnDisk() throws {
        var record = Wine.DLLOverrideAuthorship()
        record.scopes[#"HKCU\Software\Wine\DllOverrides"#] = ["d3d11": "n,b", "dxgi": "n,b"]
        record.save(toBottle: tempDir)

        let loaded = Wine.DLLOverrideAuthorship.load(fromBottle: tempDir)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.scopes[#"HKCU\Software\Wine\DllOverrides"#]?["dxgi"], "n,b")
    }

    func testEmptyAuthorshipLeavesNoFileBehind() {
        Wine.DLLOverrideAuthorship().save(toBottle: tempDir)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appending(path: Wine.DLLOverrideAuthorship.fileName).path
            )
        )
    }

    /// A bottle no launch has written has nothing recorded, so nothing can be
    /// removed from it — which is what protects a hand-written key.
    func testAuthorlessBottleRecordsNothing() {
        let record = Wine.DLLOverrideAuthorship.load(fromBottle: tempDir)
        XCTAssertTrue(record.scopes.isEmpty)
    }

    /// An unreadable record — an older build's format, or a hand-edited file —
    /// must fail toward removing nothing rather than toward guessing.
    func testCorruptAuthorshipRemovesNothing() throws {
        try Data(#"{"scopes":{"HKCU\\Software\\Wine\\DllOverrides":["dxgi"]}}"#.utf8)
            .write(to: tempDir.appending(path: Wine.DLLOverrideAuthorship.fileName))

        let record = Wine.DLLOverrideAuthorship.load(fromBottle: tempDir)
        XCTAssertTrue(
            record.scopes.isEmpty,
            "an unreadable record must not authorise any removal"
        )
    }
}
