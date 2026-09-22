//
//  FileDigest.swift
//  RaoStack
//
//  WHAT: SHA-256 of a file, read in chunks: what install.json records for the
//        Sewn in RAO_HOME/sewn/bin and what a launcher checks it against.
//

import Crypto
import Foundation

public enum FileDigest {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return StackSecret.hex(Array(hasher.finalize()))
    }
}
