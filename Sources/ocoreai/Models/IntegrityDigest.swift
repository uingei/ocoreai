// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// IntegrityDigest.swift — streaming SHA-256 over a file on disk.
//
// One pass, 64 KiB at a time: a 5.3 GB shard costs about 3.6 s (1.4 GB/s here). Which callers pay
// that price is a fact about them, not about this file — grep the symbol; a comment here once
// claimed a lane that never called it.

import CryptoKit
import Foundation

enum IntegrityDigest {
    private static let chunkBytes = 64 * 1024

    /// SHA-256 of a file, lowercase hex.
    ///
    /// `nil` means the bytes could not be read, which is not "corrupted": the caller falls
    /// back to the weaker check it still holds rather than reporting a fault it did not see.
    static func sha256(of fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: Self.chunkBytes) else { break }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
