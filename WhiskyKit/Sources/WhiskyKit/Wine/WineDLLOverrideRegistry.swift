//
//  WineDLLOverrideRegistry.swift
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

public extension Wine {
    /// Where a set of DLL overrides lives in the prefix registry.
    enum DLLOverrideScope: Equatable, Sendable {
        /// The prefix default, used by any process without an entry of its own.
        case bottle
        /// This executable only. Children do not inherit it.
        case program(String)

        var registryKey: String {
            switch self {
            case .bottle:
                #"HKCU\Software\Wine\DllOverrides"#
            case let .program(executable):
                // \\#( is a literal backslash then the interpolation; \#( alone
                // would swallow the path separator.
                #"HKCU\Software\Wine\AppDefaults\\#(executable)\DllOverrides"#
            }
        }
    }

    private static let dllOverrideLogger = Logger(
        subsystem: "com.isaacmarovitz.WhiskyKit", category: "dll-overrides"
    )

    /// Merges the DLL overrides at each scope, in one import.
    ///
    /// One import rather than a `reg` call per value: each of those is a whole
    /// wine process, and a launch syncing a bottle plus a launcher and its
    /// helpers spent twenty-odd of them before starting anything.
    ///
    /// A launch writes only the values that differ from what the prefix already
    /// holds, compares them as instructions rather than as strings
    /// (``canonicalMode(_:)``), and removes only names ``DLLOverrideAuthorship``
    /// says it wrote whose value is still exactly what it left. Everything else
    /// — the user's own values, or another tool's — is left as it is, down to
    /// the spelling. A launch that agrees with the registry writes no document
    /// at all and skips the import.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose prefix registry is written.
    ///   - scopes: Each scope and the `WINEDLLOVERRIDES`-syntax string it
    ///     contributes. An empty string contributes nothing to that scope, and a
    ///     scope with no contribution is not touched.
    @MainActor
    static func syncDLLOverrides(
        bottle: Bottle, scopes: [(scope: DLLOverrideScope, overrides: String)]
    ) async throws {
        let planned = scopes.map {
            (key: $0.scope.registryKey, overrides: parseDLLOverrides($0.overrides))
        }
        let authored = DLLOverrideAuthorship.load(fromBottle: bottle.url)
        // What the prefix already holds. One query for the whole subtree rather
        // than one per key, and it is what lets a launch whose overrides already
        // match say nothing at all.
        let held = try await readDLLOverrideKeys(bottle: bottle)

        var writes: [DLLOverrideWrite] = []
        var record = DLLOverrideAuthorship()
        for scope in planned {
            let existing = held[scope.key] ?? [:]
            let renderable = scope.overrides.filter { isRenderable(dll: $0.key, mode: $0.value) }
            // Only what differs. `native,builtin` and `n,b` are one instruction
            // in two spellings, so a value that already resolves as this launch
            // wants it is left exactly as written — including a hand-written
            // spelling.
            let setting = renderable.filter { name, mode in
                guard let current = existing[name] else { return true }
                return canonicalMode(current) != canonicalMode(mode)
            }
            // Only names this app wrote, and only while the value on disk is
            // still the one it left. A name it wrote that the user has since
            // edited is the user's now, and is not taken back.
            let ours = authored.scopes[scope.key] ?? [:]
            let removals = ours
                .filter { name, mode in
                    guard !scope.overrides.keys.contains(name) else { return false }
                    guard let current = existing[name] else { return false }
                    return canonicalMode(current) == canonicalMode(mode)
                }
                .keys.sorted()
            if !setting.isEmpty || !removals.isEmpty {
                writes.append(DLLOverrideWrite(key: scope.key, overrides: setting, remove: removals))
            }
            // The record follows the key: what this launch writes, plus whatever
            // of ours it left standing. Names taken back are released.
            var kept = ours
            for name in removals {
                kept.removeValue(forKey: name)
            }
            for (name, mode) in setting {
                kept[name] = mode
            }
            if !kept.isEmpty {
                record.scopes[scope.key] = kept
            }
        }

        let document = registryDocument(for: writes)
        // Nothing to write and nothing of ours to take back is not an
        // instruction to empty anything: the launch has no opinion about these
        // keys, so the registry is left as it is and no wine process is spent.
        guard !document.isEmpty else {
            dllOverrideLogger.debug("DLL overrides already match; leaving the registry untouched")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "whisky-dll-overrides-\(UUID().uuidString).reg")
        // Wine detects a Unicode .reg by its BOM alone, and `.utf16LittleEndian`
        // writes none — the file parses as ANSI, matches no header, and imports
        // nothing while exiting 0. Written explicitly rather than via `.utf16`,
        // whose BOM follows platform endianness.
        try ("\u{FEFF}" + document).write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        // `reg import`, not `regedit`: regedit has no silent switch, so it puts up
        // the import confirmation and never exits.
        try await runWine(["reg", "import", url.path(percentEncoded: false)], bottle: bottle)
        record.save(toBottle: bottle.url)
        dllOverrideLogger.debug("Synced DLL overrides for \(scopes.count) scope(s) in one import")
    }

    /// Moves this launch's DLL overrides from the environment into the registry.
    ///
    /// Registry, not `WINEDLLOVERRIDES`: the variable is inherited by every child,
    /// so a launcher's backend became every game's, and wine reads it before the
    /// registry, which left `AppDefaults` entries dead while it was set.
    ///
    /// Only the bottle scope is written for the bottle's backend. The
    /// per-executable scopes below are additive: a hand-written `AppDefaults`
    /// entry for a launcher's exe is exactly the kind of value a launch must
    /// never second-guess.
    ///
    /// - Parameter applyToDescendants: When the overrides describe something this
    ///   process will *spawn*, `AppDefaults` cannot express it — that is keyed on
    ///   an executable whose name is not known here — so the variable stays.
    @MainActor
    static func applyDLLOverrides(
        for url: URL,
        bottle: Bottle,
        wineEnvironment: inout [String: String],
        applyToDescendants: Bool
    ) async throws {
        // A bottle whose overrides are managed outside Whisky keeps them: no key
        // is written and nothing is pruned. The flag exists because a
        // configuration can be deliberate without being expressible here.
        guard !bottle.settings.dllOverridesAreUserManaged else {
            dllOverrideLogger.debug("DLL overrides are user-managed for this bottle; not syncing")
            return
        }

        var scopes: [(scope: DLLOverrideScope, overrides: String)] = [
            (scope: .bottle, overrides: constructWineEnvironment(for: bottle)["WINEDLLOVERRIDES"] ?? "")
        ]

        // The helper entries are written either way. A launcher's helper is
        // usually Chromium, which probes for an NVIDIA GPU on startup: answering
        // makes it load D3DMetal and take the helper down, and a dead helper is
        // a launcher that draws nothing. Games need nvapi64, because Streamline
        // asks it about the GPU before it will consider DLSS at all, so it is
        // disabled per helper rather than withheld from the bottle.
        let helperOverrides = applyToDescendants
            ? (constructWineEnvironment(for: bottle)["WINEDLLOVERRIDES"] ?? "")
            : (wineEnvironment["WINEDLLOVERRIDES"] ?? "")

        // A launcher that cannot render on the bottle's backend gets DXVK on its
        // own executables only. `AppDefaults` is the one override scope wine does
        // not propagate to children, so the games it spawns keep the bottle's
        // backend -- which is the whole point: Steam's Chromium client cannot
        // present on D3DMetal, and the games it starts are what D3DMetal is for.
        //
        // Applied here rather than in the launcher-managed environment layer
        // because that layer feeds the bottle's `WINEDLLOVERRIDES`, which every
        // child inherits.
        // Detected from the launched URL, exactly as `helperExecutables` does.
        // `settings.detectedLauncher` is not it: that is the user-facing
        // launcher-fixes toggle, left nil on bottles that never opted in, while
        // the DLL split has to hold for anyone who presses play on Steam.
        let launcherScopedDXVK = LauncherType.detect(from: url)?.dxvkScope == .launcherProcesses
        let launcherOverrides = launcherScopedDXVK
            ? applying(DLLOverrideResolver.dxvkPreset, to: helperOverrides)
            : helperOverrides

        for executable in helperExecutables(for: url) {
            scopes.append((
                scope: .program(executable),
                overrides: disablingNVAPI(in: launcherOverrides)
            ))
        }

        if !applyToDescendants {
            let programOverrides = wineEnvironment.removeValue(forKey: "WINEDLLOVERRIDES") ?? ""
            // The launched executable needs its own entry too: AppDefaults is per
            // executable and children do not inherit it.
            //
            // For a launcher whose DXVK is scoped to its own processes, this is
            // the entry that carries it: without the preset merged in, the
            // client falls through to the bottle scope -- D3DMetal, and a black
            // window. Games are unaffected; they are launched separately and
            // AppDefaults does not reach them from here.
            scopes.append((
                scope: .program(url.lastPathComponent),
                overrides: launcherScopedDXVK
                    ? applying(DLLOverrideResolver.dxvkPreset, to: programOverrides)
                    : programOverrides
            ))
        }

        try await syncDLLOverrides(bottle: bottle, scopes: scopes)
    }

    /// One key's contribution to a sync: values to merge in, and names to remove.
    ///
    /// A named type rather than a tuple: the two lists have different meanings —
    /// one adds, one takes back what a previous launch added.
    struct DLLOverrideWrite: Equatable {
        /// The registry key to write.
        let key: String
        /// DLL name to load-order pairs to merge into the key.
        let overrides: [String: String]
        /// DLL names to remove from the key, by `.reg`'s `"name"=-` form.
        let remove: [String]
    }

    /// Renders a `.reg` that merges `overrides` into each key and removes the
    /// values named in `remove`.
    ///
    /// A `[Key]` block on its own is a **merge** to wine: it writes the values it
    /// names and leaves everything else in the key alone. There is deliberately
    /// no `[-Key]` line in this document. That form deletes the whole key, which
    /// is how a launch used to take a user's own values with it — a bottle whose
    /// backend contributes no overrides rendered an empty key and a delete, and
    /// the delete is what emptied it. Removals are per value instead, via the
    /// `.reg` `"name"=-` form, and only ever for names the caller declares it
    /// owns.
    ///
    /// A scope with nothing to set and nothing to remove contributes no lines at
    /// all, and a document with no such scope is empty. Writing nothing has to
    /// mean "change nothing" — that is what keeps a backend with no overrides of
    /// its own (D3DMetal, wined3d) from emptying a key it has no opinion about.
    static func registryDocument(for scopes: [DLLOverrideWrite]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var wroteAnything = false
        for scope in scopes {
            let renderable = scope.overrides
                .filter { isRenderable(dll: $0.key, mode: $0.value) }
                .sorted { $0.key < $1.key }
            let names = Set(renderable.map(\.key))
            // A removal for a name this document also sets would delete what was
            // just written, so the write wins.
            let removals = scope.remove
                .filter { isRenderable(dll: $0, mode: "") && !names.contains($0) }
                .sorted()
            guard !renderable.isEmpty || !removals.isEmpty else { continue }
            wroteAnything = true
            lines.append("[\(scope.key)]")
            for (dll, mode) in renderable {
                lines.append("\"\(dll)\"=\"\(mode)\"")
            }
            for dll in removals {
                lines.append("\"\(dll)\"=-")
            }
            lines.append("")
        }
        return wroteAnything ? lines.joined(separator: "\r\n") : ""
    }

    /// Whether an override can be rendered without corrupting the document.
    ///
    /// Custom overrides are user-typed, and a quote or backslash in a name would
    /// terminate the value early and take every later scope down with it. A DLL
    /// name is a filename and a mode is a list of known words, so anything
    /// outside these sets could not have loaded regardless — dropping it costs
    /// nothing and contains the blast radius to the one bad entry.
    static func isRenderable(dll: String, mode: String) -> Bool {
        let name = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-+")
        let modes = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz,")
        guard !dll.isEmpty else { return false }
        return dll.lowercased().unicodeScalars.allSatisfy(name.contains)
            && mode.lowercased().unicodeScalars.allSatisfy(modes.contains)
    }

    /// The launcher helpers that must share `url`'s DLL overrides.
    ///
    /// Detected from the executable, not the bottle's recorded launcher: they
    /// need the entry because of how wine resolves `AppDefaults`, not because
    /// the user enabled launcher fixes.
    static func helperExecutables(for url: URL) -> [String] {
        LauncherType.detect(from: url)?.helperExecutables ?? []
    }

    /// Adds `nvapi64=` to an override string, keeping whatever else it holds.
    ///
    /// - Parameter overrides: A `WINEDLLOVERRIDES`-syntax string, possibly empty.
    /// - Returns: The same string with nvapi64 disabled.
    static func disablingNVAPI(in overrides: String) -> String {
        var parsed = parseDLLOverrides(overrides)
        parsed["nvapi64"] = ""
        return parsed.keys.sorted().map { "\($0)=\(parsed[$0] ?? "")" }.joined(separator: ";")
    }

    /// Merges override entries into an override string, entries winning.
    ///
    /// Used to put a launcher's DXVK preset on its own executables while the
    /// bottle keeps a different backend. Whatever else the string carries is
    /// preserved; only the named DLLs are replaced.
    ///
    /// - Parameters:
    ///   - entries: The overrides to apply.
    ///   - overrides: A `WINEDLLOVERRIDES`-syntax string, possibly empty.
    /// - Returns: The merged string in the same syntax.
    static func applying(_ entries: [DLLOverrideEntry], to overrides: String) -> String {
        var parsed = parseDLLOverrides(overrides)
        for entry in entries {
            parsed[entry.dllName] = entry.mode.rawValue
        }
        return parsed.keys.sorted().map { "\($0)=\(parsed[$0] ?? "")" }.joined(separator: ";")
    }

    /// Parses a `WINEDLLOVERRIDES` string into DLL name to load-order pairs.
    ///
    /// The registry takes the same syntax, so values pass through unchanged.
    /// `dll=` is kept: an empty value is how a DLL is disabled in both forms.
    static func parseDLLOverrides(_ overrides: String) -> [String: String] {
        var result: [String: String] = [:]
        for clause in overrides.split(separator: ";") {
            let parts = clause.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let dll = name.trimmingCharacters(in: .whitespaces)
            guard !dll.isEmpty else { continue }
            result[dll] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        return result
    }

    /// Which `DllOverrides` values this app wrote, per registry key.
    ///
    /// A launch writes overrides and, when the backend changes, has to take back
    /// the ones its previous launch wrote — clearing a key wholesale was how a
    /// launch used to destroy values it did not own, and reading the key back
    /// cannot tell an old Whisky value from a user's. This record can: it names
    /// exactly what was written and with which mode, so only those names are
    /// ever removable, and only while the value on disk is still the one that
    /// was left. A value the user has since edited is theirs.
    ///
    /// Kept beside the bottle's other metadata rather than in the prefix, so it
    /// is per bottle and survives a prefix reset. Absent means a bottle no
    /// launch of this build has written — older bottles, or one whose overrides
    /// are hand-managed — and nothing is then removable, which is the safe
    /// answer.
    struct DLLOverrideAuthorship: Codable, Equatable {
        /// Registry key to the DLL name and mode last written there by a launch.
        var scopes: [String: [String: String]] = [:]

        /// The file this record lives in, inside the bottle folder.
        static let fileName = "DLLOverrideAuthorship.json"

        /// Reads the record for a bottle, or an empty one when there is none.
        static func load(fromBottle bottleURL: URL) -> DLLOverrideAuthorship {
            let url = bottleURL.appending(path: fileName)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(DLLOverrideAuthorship.self, from: data)
            else { return DLLOverrideAuthorship() }
            return record
        }

        /// Writes the record, or removes it when it holds nothing.
        func save(toBottle bottleURL: URL) {
            let url = bottleURL.appending(path: Self.fileName)
            guard !scopes.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
