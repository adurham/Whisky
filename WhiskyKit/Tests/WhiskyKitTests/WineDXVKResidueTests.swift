//
//  WineDXVKResidueTests.swift
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

final class WineDXVKResidueTests: XCTestCase {
    private var tempDir: URL!
    private var prefixRoot: URL!
    private var originalsDXGI: URL!
    private var payloadDXGI: URL!

    /// A markerless (native) PE stub: the 16 bytes at 0x40 are not the
    /// builtin signature, so `Wine.isNativePE` classifies it as native.
    private func nativeFake(_ tag: String) -> Data {
        Data(count: 0x40) + Data(tag.utf8) + Data(count: 16)
    }

    /// A PE stub carrying winebuild's "Wine builtin DLL" signature at 0x40.
    private func builtinFake(_ tag: String) -> Data {
        Data(count: 0x40) + Data("Wine builtin DLL".utf8) + Data(tag.utf8)
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        prefixRoot = tempDir.appending(path: "bottle")
        // An originals path that does not exist unless a test creates it.
        originalsDXGI = tempDir.appending(path: "store/originals/dxgi.dll")
        // The DXMT payload the residue check compares against.
        payloadDXGI = tempDir.appending(path: "payload/x64/dxgi.dll")
        for dir in ["system32", "syswow64"] {
            try FileManager.default.createDirectory(
                at: prefixRoot.appending(path: "drive_c/windows/\(dir)"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: payloadDXGI.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func dxgi(_ dir: String) -> URL {
        prefixRoot.appending(path: "drive_c/windows/\(dir)/dxgi.dll")
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func remove() {
        Wine.removeStaleNativeDXGI(
            prefixRoot: prefixRoot, gptkOriginalsDXGI: originalsDXGI, dxmtPayloadDXGI: payloadDXGI
        )
    }

    /// The regression this guards: a DXMT launch leaves its native dxgi in
    /// both system directories, and the next DXVK launch must clear them.
    func testNativeResidueIsRemovedFromBothArches() throws {
        try nativeFake("dxmt-copy").write(to: payloadDXGI)
        try nativeFake("dxmt-copy").write(to: dxgi("system32"))
        try nativeFake("dxmt-copy").write(to: dxgi("syswow64"))
        let bystander = prefixRoot.appending(path: "drive_c/windows/system32/d3d11.dll")
        try nativeFake("dxvk-d3d11").write(to: bystander)

        remove()

        XCTAssertFalse(exists(dxgi("system32")))
        XCTAssertFalse(exists(dxgi("syswow64")))
        XCTAssertTrue(exists(bystander), "only dxgi.dll may be touched")
    }

    /// The black-Steam bug this fix closes: a native dxgi that is *not* DXMT's
    /// copy — wine's own, marker-stripped, deployed on purpose — must survive.
    /// Deleting it makes `LoadLibrary("dxgi.dll")` fail and Chromium goes black.
    func testNativeDXGIThatIsNotDXMTCopySurvives() throws {
        try nativeFake("dxmt-copy").write(to: payloadDXGI)
        try nativeFake("wine-native-marker-stripped").write(to: dxgi("system32"))
        try nativeFake("wine-native-marker-stripped").write(to: dxgi("syswow64"))

        remove()

        XCTAssertTrue(exists(dxgi("system32")), "only DXMT's own copy may be removed")
        XCTAssertTrue(exists(dxgi("syswow64")))
    }

    /// With no DXMT payload installed there is nothing to compare against, so no
    /// file can be identified as DXMT residue and none is removed.
    func testWithoutAPayloadNothingIsRemoved() throws {
        try nativeFake("wine-native").write(to: dxgi("system32"))

        remove()

        XCTAssertTrue(exists(dxgi("system32")))
    }

    /// Wine's own fake DLL carries the builtin marker and must stay: it is
    /// what redirects the loader to the builtin DXVK pairs with.
    func testBuiltinMarkedDXGIIsKept() throws {
        try builtinFake("wine-fake").write(to: dxgi("system32"))

        remove()

        XCTAssertTrue(exists(dxgi("system32")))
    }

    /// With GPTK originals present the builtin behind `,b` is Apple's
    /// forwarder, so the removal must stand down and leave the prefix to the
    /// originals-aware path.
    func testNativeDXGIIsKeptWhenGPTKOriginalsExist() throws {
        try FileManager.default.createDirectory(
            at: originalsDXGI.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try builtinFake("backed-up-original").write(to: originalsDXGI)
        try nativeFake("dxmt-copy").write(to: payloadDXGI)
        try nativeFake("dxmt-copy").write(to: dxgi("system32"))

        remove()

        XCTAssertTrue(exists(dxgi("system32")))
    }

    /// A prefix that never saw DXMT has no dxgi.dll of its own; the removal
    /// must be a silent no-op.
    func testMissingDXGIIsANoOp() {
        remove()

        XCTAssertFalse(exists(dxgi("system32")))
        XCTAssertFalse(exists(dxgi("syswow64")))
    }

    /// A file too short to hold the marker window is not classified native
    /// (`isNativePE` fails closed), so a truncated stray survives rather than
    /// being mistaken for DXMT residue.
    func testTruncatedFileIsLeftAlone() throws {
        try Data("stub".utf8).write(to: dxgi("system32"))

        remove()

        XCTAssertTrue(exists(dxgi("system32")))
    }
}
