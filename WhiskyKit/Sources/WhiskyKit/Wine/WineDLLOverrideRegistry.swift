// swiftlint:disable file_length
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

    /// Writes each scope's `WINEDLLOVERRIDES`-syntax overrides into a bottle's
    /// registry: ``syncDLLOverrides(bottle:scopes:)`` outside of tests.
    typealias DLLOverrideWriter = @MainActor (
        _ bottle: Bottle, _ scopes: [(scope: DLLOverrideScope, overrides: String)]
    ) async throws -> Void

    /// Replaces the DLL overrides at each scope, in one import.
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
    /// Besides the bottle scope and the launched executable, every launch in a
    /// bottle with Steam writes Steam's own processes their launcher set, so
    /// `steam.exe` has its entry even when the Steam installer or Windows
    /// autostart starts it rather than Whisky.
    ///
    /// - Parameter applyToDescendants: Whether the overrides describe something
    ///   this process will *spawn*, as on `steam.exe -applaunch`. For a launcher
    ///   they go into the `AppDefaults` entries of `descendantExecutables`, and
    ///   the environment keeps none, so whichever process the launcher starts
    ///   (the client itself, when it was not running, or a game) reads its own
    ///   entry. For anything else the variable stays, since `AppDefaults` cannot
    ///   express overrides for an executable whose name is not known.
    /// - Parameter descendantExecutables: The executable names the overrides
    ///   belong to when they apply to descendants.
    /// - Parameter descendantLaunchers: Launchers the descendants start on their
    ///   own, whose ``LauncherType/chainExecutables`` need entries ahead of time.
    /// - Parameter recommendedBackend: What `.recommended` resolves to for the
    ///   bottle; `nil` asks ``GraphicsBackendResolver``.
    /// - Parameter builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12`
    ///   is D3DMetal's, passed on to every composition written here.
    /// - Parameter writer: What performs the registry write.
    @MainActor
    static func applyDLLOverrides(
        for url: URL,
        bottle: Bottle,
        wineEnvironment: inout [String: String],
        applyToDescendants: Bool,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        writer: DLLOverrideWriter = { try await syncDLLOverrides(bottle: $0, scopes: $1) }
    ) async throws {
        // A bottle whose overrides are managed outside Whisky keeps them: no key
        // is written and nothing is pruned. The flag exists because a
        // configuration can be deliberate without being expressible here.
        guard !bottle.settings.dllOverridesAreUserManaged else {
            dllOverrideLogger.debug("DLL overrides are user-managed for this bottle; not syncing")
            return
        }
        let bottleOverrides = constructWineEnvironment(
            for: bottle, recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
        )["WINEDLLOVERRIDES"] ?? ""
        var scopes = DLLOverrideScopes(bottle: bottleOverrides)
        let launcher = LauncherType.detect(from: url)
        let launcherSet = { (userOverrides: ProgramOverrides?) in
            launcherDLLOverrides(
                bottle: bottle, userOverrides: userOverrides,
                recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
            )
        }

        // The launched executable and its helpers. A launcher's helper is
        // usually Chromium, which probes for an NVIDIA GPU on startup: answering
        // makes it load D3DMetal and take the helper down, and a dead helper is
        // a launcher that draws nothing. Games need nvapi64, because Streamline
        // asks it about the GPU before it will consider DLSS at all, so it is
        // disabled per helper rather than withheld from the bottle.
        //
        // The helpers are written on a Steam game launch too. The sync
        // *replaces* each key it writes, so leaving them out did not merely skip
        // them, it cleared any entry they already had and handed Chromium
        // nvapi64 again. The overrides on such a launch are the game's, so the
        // launcher and its helpers get the launcher's own set instead: the
        // bottle's set is not that (D3DMetal, for a bottle on Recommended), and
        // a helper restarting after a game launch would crash-loop on it (#276).
        var gamePlan: String?
        if applyToDescendants, let launcher {
            gamePlan = wineEnvironment.removeValue(forKey: "WINEDLLOVERRIDES") ?? ""
            let own = launcherSet(Program.persistedOverrides(for: url, bottleURL: bottle.url))
            scopes.add(launcher.helperExecutables, disablingNVAPI(in: own))
            scopes.add([url.lastPathComponent], own)
        } else if !applyToDescendants {
            let own = wineEnvironment.removeValue(forKey: "WINEDLLOVERRIDES") ?? ""
            scopes.add(helperExecutables(for: url), disablingNVAPI(in: own))
            // The launched executable needs its own entry too: AppDefaults is per
            // executable and children do not inherit it.
            scopes.add([url.lastPathComponent], own)
        }

        // Steam's own processes, whatever this launch is. Something other than
        // Whisky may start the client: its installer when it finishes, Windows
        // autostart, or a cold `-applaunch`. Without an entry it would run on the
        // bottle's backend, which over D3DMetal crash-loops its helpers.
        let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url)
        if launcher == .steam || steamRoot != nil {
            let steamExe = steamRoot?.appending(path: "steam.exe")
            let own = launcherSet(steamExe.flatMap { Program.persistedOverrides(for: $0, bottleURL: bottle.url) })
            scopes.add(LauncherType.steam.helperExecutables, disablingNVAPI(in: own))
            scopes.add(["steam.exe"], own)
        }

        // The game's plan, in the entries of the executables it runs as. After
        // Steam's own, which a game executable never displaces.
        if let gamePlan {
            scopes.add(descendantExecutables, gamePlan)
        }

        scopes.add(
            chainExecutables(for: launcher, descendantLaunchers: descendantLaunchers, bottleURL: bottle.url),
            disablingD3D12(in: launcherSet(nil))
        )

        try await writer(bottle, scopes.entries)
    }

    /// The scopes one launch writes, each executable at most once: the first
    /// set given for an executable wins, compared without case as Wine does.
    struct DLLOverrideScopes {
        private(set) var entries: [(scope: DLLOverrideScope, overrides: String)]
        private var taken: Set<String> = []

        init(bottle overrides: String) {
            entries = [(scope: .bottle, overrides: overrides)]
        }

        mutating func add(_ executables: [String], _ overrides: String) {
            for executable in executables where taken.insert(executable.lowercased()).inserted {
                entries.append((scope: .program(executable), overrides: overrides))
            }
        }
    }

    /// The DLL overrides a launcher's own processes run with: the bottle's set
    /// with the DXVK preset on top, and the user's own overrides for the
    /// launcher's executable on top of that.
    ///
    /// The resolver sends every launcher to DXVK (#252), because Chromium cannot
    /// draw on D3DMetal or DXMT. Pinned rather than resolved, so it holds for a
    /// bottle on any backend, and it never goes into the bottle scope: that one
    /// is the games'. A backend the user picked for the launcher's executable
    /// itself is kept, as a launch of it from the Programs tab would.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose set to start from.
    ///   - userOverrides: The user's persisted overrides for the launcher's
    ///     executable (its custom DLL overrides, say), if any.
    ///   - recommendedBackend: What `.recommended` resolves to for the bottle.
    ///   - builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12` is D3DMetal's.
    @MainActor
    static func launcherDLLOverrides(
        bottle: Bottle,
        userOverrides: ProgramOverrides? = nil,
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed()
    ) -> String {
        var pinned = userOverrides ?? ProgramOverrides()
        if pinned.graphicsBackend == nil || pinned.graphicsBackend == .recommended {
            pinned.graphicsBackend = .dxvk
        }
        return constructWineEnvironment(
            for: bottle, programOverrides: pinned,
            recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
        )["WINEDLLOVERRIDES"] ?? ""
    }

    /// The launcher executables a launch should write entries for ahead of
    /// time, because something other than Whisky starts them.
    ///
    /// Rockstar's chain, when the game being launched is a Rockstar title,
    /// whether or not Rockstar's launcher is installed yet: the first run of
    /// one installs the launcher and starts it in the same session. Otherwise
    /// it rides along with Steam and Rockstar launches only once the launcher
    /// is installed in the bottle.
    ///
    /// `AppDefaults` is keyed on the file name alone, so the entry is the same
    /// for any `Launcher.exe` in the bottle. Once Rockstar's launcher is there,
    /// another program by that name gets the Rockstar layout until its own
    /// launch from Whisky writes its own entry (and loses it again at the next
    /// Steam launch). A game's own `Launcher.exe` keeps the game's plan during
    /// that game's Steam launch, since game executables are written first.
    static func chainExecutables(
        for launcher: LauncherType?, descendantLaunchers: [LauncherType] = [], bottleURL: URL
    ) -> [String] {
        let rockstarSession = descendantLaunchers.contains(.rockstar)
            || ((launcher == .steam || launcher == .rockstar) && rockstarInstalled(bottleURL: bottleURL))
        return rockstarSession ? LauncherType.rockstar.chainExecutables : []
    }

    /// Whether the bottle has a `Rockstar Games` folder in either Program Files.
    static func rockstarInstalled(bottleURL: URL) -> Bool {
        let driveC = bottleURL.appending(path: "drive_c")
        return ["Program Files", "Program Files (x86)"].contains { programFiles in
            let folder = driveC.appending(path: programFiles).appending(path: "Rockstar Games")
            return FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        }
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

    /// Adds `nvapi64=`, `nvapi=`, and `nvngx=` to an override string, keeping whatever else it holds.
    ///
    /// - Parameter overrides: A `WINEDLLOVERRIDES`-syntax string, possibly empty.
    /// - Returns: The same string with NVIDIA bridges disabled.
    static func disablingNVAPI(in overrides: String) -> String {
        var parsed = parseDLLOverrides(overrides)
        parsed["nvapi64"] = ""
        parsed["nvapi"] = ""
        parsed["nvngx"] = ""
        return parsed.keys.sorted().map { "\($0)=\(parsed[$0] ?? "")" }.joined(separator: ";")
    }

    /// Adds `d3d12=` to an override string, keeping whatever else it holds.
    ///
    /// - Parameter overrides: A `WINEDLLOVERRIDES`-syntax string, possibly empty.
    /// - Returns: The same string with `d3d12` disabled.
    static func disablingD3D12(in overrides: String) -> String {
        var parsed = parseDLLOverrides(overrides)
        parsed["d3d12"] = ""
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
