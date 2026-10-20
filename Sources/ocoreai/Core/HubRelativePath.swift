// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! HubRelativePath.swift — the one place a hub-supplied relative path becomes a disk path.
//!
//! Two kinds of input reached the filesystem without ever being asked where they live
//! (measured 10-20, `Models/ModelScopeDownloader.swift`):
//!   • the wire's model id, joined straight onto the cache root
//!     (`cacheRoot.appendingPathComponent(id)`);
//!   • the `Path` field of a **remote** repo-manifest response, joined onto the cache dir for a
//!     write, and joined again on the failure paths to delete
//!     (`cacheDir.appendingPathComponent(path)` in `downloadBatch`/`verifyDownloadedFiles`).
//!
//! `URL.appendingPathComponent(_:)` percent-encodes; it does **not** contain. `..` stays literal,
//! so a manifest entry of `../../ anything` walks out of `~/.ocoreai/models`, and the same string
//! on a delete line is an arbitrary-file-delete primitive. The second input is the one that
//! matters for the threat model: the bytes come from whatever answered the hub API, including a
//! mirror or proxy, which is exactly where
//! `MODELSCOPE_ENDPOINT` lets an operator point the client.
//!
//! The rule lives here and nowhere else: **a hub path is a sequence of ordinary relative
//! components, and it lands under its root or nowhere.** Structural rejection, not
//! normalize-and-hope — `standardizingPath` collapses `a/../b` to `b`, which is a legal path
//! that no longer means what the manifest said it meant.
//!
//! Grounding (all read 10-20): ollama `types/model/name.go:262 IsValid()` rejects exactly this
//! shape by enumerating hazards per component; codex #55384 refuses to follow a *replaceable
//! symlink* out of a sandboxed exec lookup, which is why the containment check below compares
//! symlink-resolved paths rather than lexical ones.
//!
//! Residual, stated not hidden: this is a check-then-act sequence, so a symlink swapped into
//! place between validation and the write still lands outside (TOCTOU). Closing that needs
//! `openat`+`O_NOFOLLOW` semantics relative to an opened root fd; the cache dir is
//! user-owned, so the residual is a local-user race, not a remote-input escape.

import Foundation

/// A relative path coming from a model hub (wire id, or a remote manifest entry), validated
/// before it is allowed to touch the filesystem.
enum HubRelativePath {
    /// A path rejected as unsafe.
    ///
    /// `field` names the wire location (`model`, `revision`, `files[].path`) and `value` carries
    /// the string as received, because a refusal that does not name what it refused is not
    /// actionable (AGENTS.md: a bounded knob out of domain is a 400 naming field + range + value
    /// sent — same discipline applies to path domains). Control characters are escaped in the
    /// display form so a refusal can't inject terminal sequences into a log or a client.
    struct Unsafe: Equatable, LocalizedError, CustomStringConvertible {
        /// Why the path was rejected. Raw-valued so the wire message carries it verbatim.
        enum Reason: String, Equatable {
            /// Nothing to resolve.
            case empty
            /// Leading or trailing whitespace — never part of a legitimate id, and the kind of
            /// thing that survives into a filesystem name and makes it unreachable.
            case surroundingWhitespace
            /// A NUL or C0/C1 control character in the string.
            case controlCharacter
            /// Backslash — a path separator on Windows hubs, and a legal-but-surprising byte here.
            case backslash
            /// Absolute path.
            case absolutePath
            /// Home-relative path (`~` / `~/…`).
            case tildeHome
            /// A `.` or `..` component.
            case dotComponent
            /// An empty component: `a//b`, or a trailing `/`.
            case emptyComponent
            /// Lexical or symlink containment failed after component validation.
            case escapedRoot
        }

        let field: String
        let value: String
        let reason: Reason

        var description: String {
            "\(field) is not a safe cache-relative path (\(reason.rawValue)): \(Self.escaped(value))"
        }

        var errorDescription: String? { description }

        /// The value with control characters escaped, quoted — safe to embed in a response body
        /// or a log line.
        static func escaped(_ raw: String) -> String {
            var out = "\""
            for scalar in raw.unicodeScalars {
                switch scalar.value {
                case 0x22: out += "\\\""
                case 0x5c: out += "\\\\"
                case let v where v < 0x20 || v == 0x7f: out += String(format: "\\u{%02X}", v)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
    }

    /// The path split into validated components, or ``Unsafe`` explaining which hazard it hit.
    ///
    /// Every hazard is checked structurally before any filesystem call, so the answer does not
    /// depend on what happens to exist on disk right now.
    static func components(_ raw: String, field: String) throws -> [String] {
        guard !raw.isEmpty else {
            throw Unsafe(field: field, value: raw, reason: .empty)
        }
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Unsafe(field: field, value: raw, reason: .surroundingWhitespace)
        }
        for scalar in raw.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7f {
            throw Unsafe(field: field, value: raw, reason: .controlCharacter)
        }
        guard !raw.contains("\\") else {
            throw Unsafe(field: field, value: raw, reason: .backslash)
        }
        guard !raw.hasPrefix("/") else {
            throw Unsafe(field: field, value: raw, reason: .absolutePath)
        }
        guard !raw.hasPrefix("~") else {
            throw Unsafe(field: field, value: raw, reason: .tildeHome)
        }
        // `omittingEmptySubsequences: false` is the point: `a//b` and `a/` are rejections, not
        // things to silently repair.
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty {
                throw Unsafe(field: field, value: raw, reason: .emptyComponent)
            }
            if part == "." || part == ".." {
                throw Unsafe(field: field, value: raw, reason: .dotComponent)
            }
        }
        return parts
    }

    /// Resolve `raw` under `root`, or throw. The returned URL is lexical (never symlink-resolved),
    /// so callers keep writing to the path they were configured with.
    ///
    /// Containment is checked twice: lexically on the standardized candidate, and again after
    /// resolving symlinks through the deepest existing ancestor of both sides. The second check is
    /// what refuses `cacheDir/link -> /tmp` (write through an existing symlink) and
    /// `cacheDir/link` where `link` is dangling, both of which pass a purely lexical test.
    static func resolve(
        under root: URL,
        _ raw: String,
        field: String,
        fileManager: FileManager = .default,
    ) throws -> URL {
        let parts = try components(raw, field: field)
        var candidate = root.standardizedFileURL
        for part in parts { candidate.appendPathComponent(part) }

        let rootPath = realPath(of: root, fileManager: fileManager).path
        let candidatePath = realPath(of: candidate, fileManager: fileManager).path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw Unsafe(field: field, value: raw, reason: .escapedRoot)
        }
        return candidate
    }

    /// Deepest existing ancestor, symlink-resolved, with the non-existent tail re-appended.
    ///
    /// Foundation is never handed a path whose tail is missing: `resolvingSymlinksInPath()` drops
    /// the last component when that component is a dangling symlink, which would silently change
    /// *which* path is being judged. Walking to the last existing parent and appending the rest
    /// keeps the comparison about the path that was named.
    private static func realPath(of url: URL, fileManager: FileManager) -> URL {
        var tail: [String] = []
        var cursor = url.standardizedFileURL
        while !fileManager.fileExists(atPath: cursor.path) {
            let name = cursor.lastPathComponent
            if name.isEmpty || name == "/" { break }
            tail.append(name)
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath()
        for name in tail.reversed() { resolved.appendPathComponent(name) }
        return resolved
    }
}

extension AppError {
    /// Wire shape for a rejected hub path: the 400 names the field, the value as sent, and the
    /// reason — the same three things ``AppError/invalidParameter(param:message:value:)`` exists
    /// to carry for numeric knobs.
    init(hubPathRejected rejection: HubRelativePath.Unsafe) {
        self = .invalidParameter(
            param: rejection.field,
            message: rejection.description,
            value: rejection.value)
    }
}
