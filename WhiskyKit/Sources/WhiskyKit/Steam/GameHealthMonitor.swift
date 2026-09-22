//
//  GameHealthMonitor.swift
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
import AppKit
import os.log

/// Watches for the two faults that leave a game's session in a bad state, and
/// repairs what it can.
///
/// This lives in the app rather than in an external agent on purpose: the app
/// is the only thing that is always running when a game is launched from
/// Whisky's GUI, so a monitor here cannot be forgotten, un-armed, or run from
/// a different context than the one that matters.
///
/// **Fault 1 — the display is left on the game's mode.** A game exits; the
/// display is still at the game's resolution, the desktop squeezed into part
/// of the panel. Observed after quitting Dark Souls III.
///
/// **Fault 2 — the game process outlives its window.** The process is still
/// alive with no window: it keeps Steam thinking the game is running, and it
/// keeps whatever display hold is in place. Note the process may be *spinning*
/// (measured at 105% CPU) or parked (0% CPU), so a CPU-based trigger cannot
/// detect this — the test has to be "alive but has no window".
///
/// The monitor never kills anything and never changes a display mode it did
/// not set. What it does is (a) record enough evidence to diagnose the fault,
/// and (b) for the display fault, ask the same helper that owns the mode to
/// restore it.
public actor GameHealthMonitor {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// How often to check.
        public var pollInterval: TimeInterval = 3
        /// Executable names treated as games (lowercased, with extension).
        /// Mutable so the app can widen the watch list once its libraries load.
        public var gameImageNames: Set<String>
        /// Where evidence is written.
        public var evidenceDirectory: URL
        /// Repairs the display by invoking the mode helper. Injected so this
        /// type stays testable and so a caller can disable repair entirely.
        public var restoreDisplay: @Sendable (Int32) async -> Bool

        public init(
            gameImageNames: Set<String>,
            evidenceDirectory: URL,
            restoreDisplay: @escaping @Sendable (Int32) async -> Bool
        ) {
            self.gameImageNames = gameImageNames
            self.evidenceDirectory = evidenceDirectory
            self.restoreDisplay = restoreDisplay
        }
    }

    // MARK: - State

    private var config: Configuration
    private let logger = Logger(subsystem: "com.whisky.GameHealthMonitor", category: "health")

    /// Consecutive polls a condition must hold before it is believed. Keeps a
    /// transient (a game mid-launch, a window mid-resize) from being treated
    /// as a fault.
    private let confirmSamples = 4

    private var displayFaultSamples = 0
    private var orphanSamples = 0
    private var handledOrphanPIDs: Set<Int32> = []
    private var handledDisplayRestoreForSession = false
    private var pollTask: Task<Void, Never>?

    /// The mode the display was on when everything last looked healthy. Only
    /// ever recorded while no game is running, so it cannot accidentally latch
    /// onto a game's mode — that mistake made an earlier version of this work
    /// defend the very mode it existed to correct.
    private var healthyDesktopModeNumber: Int32?

    public init(configuration: Configuration) {
        self.config = configuration
    }

    // MARK: - Lifecycle

    /// Starts polling. Safe to call more than once; a second call is ignored
    /// while a poll loop is already running.
    public func start() {
        guard pollTask == nil else { return }
        try? FileManager.default.createDirectory(
            at: config.evidenceDirectory, withIntermediateDirectories: true)
        logger.notice("game health monitor started")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = await self?.config.pollInterval ?? 3
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        logger.notice("game health monitor stopped")
    }

    /// Merges additional game image names into the watch list.
    ///
    /// The app supplies these once its Steam libraries have been enumerated —
    /// only the app layer knows which bottles and games exist.
    func mergeGameImageNames(_ names: Set<String>) {
        config.gameImageNames.formUnion(names)
        logger.notice("watching \(self.config.gameImageNames.count) game executables")
    }

    // MARK: - Polling

    private func pollOnce() async {
        let running = await runningGameProcesses()

        // While a game runs, a game-sized display mode and a bottle-owned
        // window are both correct. Track the healthy baseline only when idle.
        guard running.isEmpty else {
            displayFaultSamples = 0
            orphanSamples = 0
            handledDisplayRestoreForSession = false
            return
        }

        await checkDisplayRestored()
        await checkForOrphanedGameProcesses()
    }

    // MARK: - Fault 1: display not restored

    private func checkDisplayRestored() async {
        guard let modeNumber = currentModeNumber() else { return }

        // A density-2.0 mode is the scaled HiDPI desktop. Checking density
        // alone is NOT sufficient — two different mode numbers can both be
        // density 2.0 — so remember the specific number seen while healthy and
        // compare against that.
        if let known = healthyDesktopModeNumber, modeNumber == known {
            displayFaultSamples = 0
            handledDisplayRestoreForSession = false
            return
        }

        if isHiDPIMode(modeNumber) {
            // Looks like a desktop mode we simply have not recorded yet.
            if healthyDesktopModeNumber == nil {
                healthyDesktopModeNumber = modeNumber
                logger.notice("healthy desktop mode recorded as \(modeNumber)")
            }
            displayFaultSamples = 0
            return
        }

        // Not a HiDPI mode and no game running: this is the fault.
        displayFaultSamples += 1
        guard displayFaultSamples >= confirmSamples, !handledDisplayRestoreForSession else { return }
        handledDisplayRestoreForSession = true

        await captureEvidence(
            tag: "display",
            reason: "display left on non-HiDPI mode \(modeNumber) with no game running")

        guard let target = healthyDesktopModeNumber else {
            logger.error("cannot repair display: no healthy desktop mode was ever recorded")
            return
        }
        logger.notice("restoring display to mode \(target)")
        let ok = await config.restoreDisplay(target)
        logger.notice("display restore \(ok ? "succeeded" : "FAILED", privacy: .public)")

        // Verify by re-reading rather than trusting the call's return value.
        try? await Task.sleep(for: .seconds(2))
        if let after = currentModeNumber(), after == target {
            logger.notice("display verified back on mode \(after)")
        } else {
            await captureEvidence(tag: "display-failed",
                                  reason: "display restore did not take: still not on mode \(target)")
        }
    }

    // MARK: - Fault 2: game process outlived its window

    private func checkForOrphanedGameProcesses() async {
        let orphaned = await gameProcessesWithoutWindows()
            .filter { !handledOrphanPIDs.contains($0) }

        guard !orphaned.isEmpty else {
            orphanSamples = 0
            return
        }

        orphanSamples += 1
        guard orphanSamples >= confirmSamples else { return }

        for pid in orphaned {
            handledOrphanPIDs.insert(pid)
            await captureEvidence(
                tag: "orphan-pid\(pid)",
                reason: "game process \(pid) is alive with no window (Steam will still show it as running)")
        }
    }

    // MARK: - Process inspection

    /// Lowercased image names of the configured games currently running.
    private func runningGameProcesses() async -> Set<String> {
        let games = config.gameImageNames
        return await Task.detached {
            var found: Set<String> = []
            for name in games where self.processExists(named: name) {
                found.insert(name)
            }
            return found
        }.value
    }

    /// Game processes that are alive but own no onscreen window.
    private func gameProcessesWithoutWindows() async -> [Int32] {
        let games = config.gameImageNames
        return await Task.detached {
            var result: [Int32] = []
            for name in games {
                for pid in self.pids(named: name) where !self.pidOwnsOnscreenWindow(pid) {
                    result.append(pid)
                }
            }
            return result
        }.value
    }

    private nonisolated func pids(named image: String) -> [Int32] {
        // Games are launched through Steam, so their argv carries a Windows
        // path; match the image name as a path component rather than a bare
        // substring, and never match this process.
        guard let out = Self.run("/bin/ps", ["-axo", "pid=,command="]) else { return [] }
        var pids: [Int32] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...]).lowercased()
            guard command.contains("\\" + image) || command.contains("/" + image) else { continue }
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            pids.append(pid)
        }
        return pids
    }

    private nonisolated func processExists(named image: String) -> Bool {
        !pids(named: image).isEmpty
    }

    /// Does this pid own a window that is on screen and large enough to be a
    /// game window? Uses the window list rather than the process table,
    /// because "has a window" is the thing that actually distinguishes a
    /// running game from an orphan.
    private nonisolated func pidOwnsOnscreenWindow(_ pid: Int32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let width = bounds["Width"], let height = bounds["Height"],
               width >= 320, height >= 240 {
                return true
            }
        }
        return false
    }

    // MARK: - Display inspection

    private nonisolated func currentModeNumber() -> Int32? {
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
    private nonisolated func isHiDPIMode(_ modeNumber: Int32) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSGetDisplayModeDescriptionOfLength") else { return false }
        typealias GetDesc = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
        let getDesc = unsafeBitCast(symbol, to: GetDesc.self)

        // Layout: mode, flags, width, height, depth, 170 reserved, freq,
        // 16 more, density (float). Only density and the mode number are used.
        var storage = [UInt8](repeating: 0, count: 0xDC)
        let rc = storage.withUnsafeMutableBytes { buffer in
            getDesc(CGMainDisplayID(), modeNumber, buffer.baseAddress!, 0xDC)
        }
        guard rc == 0 else { return false }
        let density = storage.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xD8, as: Float.self) }
        return density >= 1.9
    }

    // MARK: - Evidence

    private func captureEvidence(tag: String, reason: String) async {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = config.evidenceDirectory.appendingPathComponent("\(tag)-\(stamp)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var report = "WHY: \(reason)\nAT: \(stamp)\n\n"

        report += "=== display ===\n"
        report += "mode number: \(currentModeNumber().map(String.init) ?? "unknown")\n"
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] {
            let wineWindows = list.filter { window in
                (window[kCGWindowOwnerName as String] as? String).map {
                    $0.lowercased().contains("wine") || $0.lowercased().contains("whisky")
                } ?? false
            }
            report += "bottle-owned onscreen windows: \(wineWindows.count)\n"
            for window in wineWindows.prefix(10) {
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let width = bounds["Width"].map { String(format: "%.0f", $0) } ?? "?"
                let height = bounds["Height"].map { String(format: "%.0f", $0) } ?? "?"
                let originX = bounds["X"].map { String(format: "%.0f", $0) } ?? "?"
                let originY = bounds["Y"].map { String(format: "%.0f", $0) } ?? "?"
                report += "  \(owner) at (\(originX),\(originY)) \(width)x\(height)\n"
            }
        }

        report += "\n=== processes ===\n"
        report += Self.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,state=,command="])?
            .split(separator: "\n")
            .filter { line in
                let lowered = line.lowercased()
                return lowered.contains("darksouls") || lowered.contains("steam")
                    || lowered.contains("wine") || lowered.contains("whisky")
            }
            .joined(separator: "\n") ?? "(none)"

        try? report.write(to: directory.appendingPathComponent("snapshot.txt"),
                          atomically: true, encoding: .utf8)
        logger.notice("evidence written to \(directory.path, privacy: .public)")
    }

    // MARK: - Helpers

    nonisolated static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
