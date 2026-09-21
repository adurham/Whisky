//
//  WineDLLOverrideRegistry+Readback.swift
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

public extension Wine {
    /// Reads every `DllOverrides` value in the prefix in one query.
    ///
    /// One `reg query` of the `Wine` subtree rather than one per key: the keys
    /// this sync touches are `HKCU\Software\Wine\DllOverrides` and one
    /// `AppDefaults\<exe>` per helper, and each query is a whole wine process.
    /// Parsing the section headers out of one answer costs nothing by comparison.
    ///
    /// - Parameter bottle: The bottle whose prefix registry is read.
    /// - Returns: Registry key to DLL name to mode, for every `DllOverrides` key
    ///   present. A key with no values is absent.
    static func readDLLOverrideKeys(bottle: Bottle) async throws -> [String: [String: String]] {
        let output = try await runWine(["reg", "query", #"HKCU\Software\Wine"#, "/s"], bottle: bottle)
        return parseDLLOverrideQuery(output)
    }

    /// Parses `reg query /s` output into registry key to DLL name to mode.
    ///
    /// The output is sections of a `HKEY_CURRENT_USER\...` header followed by
    /// indented `name    REG_SZ    value` rows. Only `DllOverrides` keys are
    /// returned: the subtree holds every other Wine setting too. Headers are
    /// normalised to the `HKCU\...` spelling ``DLLOverrideScope/registryKey``
    /// uses, or the two would never compare equal and every launch would rewrite
    /// a registry it already agreed with.
    ///
    /// - Parameter output: The command's stdout.
    /// - Returns: Registry key to DLL name to mode.
    static func parseDLLOverrideQuery(_ output: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var active: String?
        // Splits on any newline, not just `\n`: wine emits CRLF, and splitting
        // on `\n` alone leaves a bare `\r` that survives trimming nowhere it
        // matters but does stop the header test below from matching.
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // A `HKEY_...` line is a section header; anything else under a
            // `DllOverrides` header is one of its values.
            if line.hasPrefix("HKEY_CURRENT_USER\\") {
                active = line.hasSuffix(#"\DllOverrides"#) ? normaliseQueryKey(line) : nil
                continue
            }
            guard let key = active else { continue }
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2, columns[1].hasPrefix("REG_SZ") else { continue }
            let name = String(columns[0])
            // `dll=` is how a DLL is disabled, and the empty value renders as
            // nothing after `REG_SZ`.
            let mode = columns.count > 2 ? String(columns[2]) : ""
            result[key, default: [:]][name] = mode
        }
        return result
    }

    /// A key as `reg query` spells it, as ``DLLOverrideScope/registryKey`` does.
    static func normaliseQueryKey(_ key: String) -> String {
        key.hasPrefix(#"HKEY_CURRENT_USER\"#)
            ? "HKCU\\" + key.dropFirst(#"HKEY_CURRENT_USER\"#.count)
            : key
    }

    /// The mode a value names, in one spelling.
    ///
    /// `native,builtin` and `n,b` are the same instruction — wine accepts both
    /// spellings and treats the parts as a set — so comparing the raw strings
    /// would have a launch rewrite a value for saying exactly what it wants.
    /// A canonical form lets a value already on disk that resolves the way this
    /// launch wants it count as matching, and be left alone.
    ///
    /// - Parameter mode: A `WINEDLLOVERRIDES` mode, in either spelling.
    /// - Returns: The mode with its parts lowercased, deduplicated and sorted.
    static func canonicalMode(_ mode: String) -> String {
        var parts: [String] = []
        for part in mode.lowercased().split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed == "native" { parts.append("n") } else if trimmed == "builtin" {
                parts.append("b")
            } else if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        // `b,n` and `n,b` are not the same instruction; the order inside each
        // comma-separated part is, and so is duplication.
        return parts.joined(separator: ",")
    }
}
