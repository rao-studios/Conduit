//
//  PrivateFile.swift
//  RaoStack
//
//  WHAT: The few filesystem moves ~/.rao needs to be safe with several apps
//        and servers touching it at once: private directories, atomic writes,
//        publish-if-absent, change detection and advisory locks.
//  IN:   RaoHome provisioning, ProviderKeyStore, the run records and leases.
//  OUT:  Files a reader never sees half-written; secrets that are never
//        overwritten once published.
//  PIN:  POSIX only (Darwin and Glibc/Musl), because Sewn and Thread build on
//        Linux too. Every write lands in a temporary file in the same
//        directory and is renamed (or linked) into place; a crash leaves the
//        old file or a stray temp, never a torn one.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum PrivateFileError: Error, Equatable, CustomStringConvertible {
    case notOwned(String)
    case tooOpen(String, mode: UInt16)
    case notADirectory(String)
    case io(String, String)

    public var description: String {
        switch self {
        case .notOwned(let path): return "\(path) belongs to another user"
        case .tooOpen(let path, let mode): return "\(path) is readable or writable by others (mode \(String(mode, radix: 8)))"
        case .notADirectory(let path): return "\(path) is not a directory"
        case .io(let path, let reason): return "\(path): \(reason)"
        }
    }
}

/// What identifies one version of a file cheaply: when any of these change,
/// the contents may have.
public struct FileIdentity: Equatable, Sendable {
    public let inode: UInt64
    public let size: Int64
    public let modifiedNanoseconds: Int64
}

public enum PrivateFile {

    // MARK: - Paths

    /// The path a syscall wants: no percent-encoding (a space stays a space),
    /// no trailing slash (so two spellings of one directory compare equal).
    public static func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Inspection

    /// Owner uid and permission bits, or nil when nothing is there.
    public static func ownerAndMode(_ url: URL) -> (uid: uid_t, mode: UInt16, isDirectory: Bool)? {
        var info = stat()
        guard lstat(path(url), &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        return (info.st_uid, UInt16(info.st_mode & 0o7777), isDirectory)
    }

    public static func exists(_ url: URL) -> Bool { ownerAndMode(url) != nil }

    /// Throws unless `url` belongs to this user and nobody else may read or
    /// write it.
    public static func verifyPrivate(_ url: URL) throws {
        guard let found = ownerAndMode(url) else {
            throw PrivateFileError.io(path(url), "missing")
        }
        guard found.uid == geteuid() else { throw PrivateFileError.notOwned(path(url)) }
        guard found.mode & 0o077 == 0 else { throw PrivateFileError.tooOpen(path(url), mode: found.mode) }
    }

    public static func identity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(path(url), &info) == 0 else { return nil }
        #if canImport(Darwin)
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanos = Int64(info.st_mtimespec.tv_nsec)
        #else
        let seconds = Int64(info.st_mtim.tv_sec)
        let nanos = Int64(info.st_mtim.tv_nsec)
        #endif
        return FileIdentity(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                            modifiedNanoseconds: seconds * 1_000_000_000 + nanos)
    }

    // MARK: - Directories

    /// `mkdir -p` with `mode` for every directory it creates. An existing
    /// directory of this user's that is more open than `mode` is tightened;
    /// one owned by someone else is refused.
    public static func ensureDirectory(_ url: URL, mode: mode_t = 0o700) throws {
        let target = url.standardizedFileURL
        if let found = ownerAndMode(target) {
            guard found.isDirectory else { throw PrivateFileError.notADirectory(path(target)) }
            guard found.uid == geteuid() else { throw PrivateFileError.notOwned(path(target)) }
            if found.mode & ~UInt16(mode) & 0o777 != 0 {
                guard chmod(path(target), mode) == 0 else {
                    throw PrivateFileError.io(path(target), "chmod: \(errnoText())")
                }
            }
            return
        }
        let parent = target.deletingLastPathComponent()
        if parent.path(percentEncoded: false) != target.path(percentEncoded: false), !exists(parent) {
            try ensureDirectory(parent, mode: mode)
        }
        if mkdir(path(target), mode) != 0 && errno != EEXIST {
            throw PrivateFileError.io(path(target), "mkdir: \(errnoText())")
        }
        // mkdir honours the umask; make the mode exact.
        _ = chmod(path(target), mode)
    }

    // MARK: - Writing

    /// Writes `data` to `url` so a reader sees the old file or the new one,
    /// never a mix: a temporary file beside it, fsync, rename.
    public static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let temp = try writeTemporary(data, beside: url, mode: mode)
        guard rename(path(temp), path(url)) == 0 else {
            let reason = errnoText()
            unlink(path(temp))
            throw PrivateFileError.io(path(url), "rename: \(reason)")
        }
    }

    /// Publishes `data` at `url` only if nothing is there yet, atomically:
    /// the full contents are written to a temporary file first and hard-linked
    /// into place, so a reader never sees an empty or partial file and two
    /// racing writers can't both win. Returns false when `url` already existed.
    @discardableResult
    public static func publishIfAbsent(_ data: Data, to url: URL, mode: mode_t = 0o600) throws -> Bool {
        let temp = try writeTemporary(data, beside: url, mode: mode)
        defer { unlink(path(temp)) }
        if link(path(temp), path(url)) == 0 { return true }
        if errno == EEXIST { return false }
        throw PrivateFileError.io(path(url), "link: \(errnoText())")
    }

    private static func writeTemporary(_ data: Data, beside url: URL, mode: mode_t) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: .min ... .max)).tmp")
        let fd = open(path(temp), O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw PrivateFileError.io(path(temp), "open: \(errnoText())") }
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = "write: \(errnoText())"
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = "fsync: \(errnoText())" }
        _ = fchmod(fd, mode)
        close(fd)
        if let failure {
            unlink(path(temp))
            throw PrivateFileError.io(path(temp), failure)
        }
        return temp
    }

    // MARK: - Locks

    /// Runs `body` holding an exclusive advisory lock on `lockFile` (created
    /// 0600 if missing). Blocks until the lock is free; keep `body` short.
    public static func withExclusiveLock<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T {
        let lock = try FileLock(lockFile)
        try lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func errnoText() -> String { String(cString: strerror(errno)) }
}

/// An advisory `flock` on a file, for the moments two processes must not both
/// act: installing Sewn, starting Sewn, rewriting the shared keys.
public final class FileLock: @unchecked Sendable {
    private let fd: Int32
    public let url: URL

    public init(_ url: URL) throws {
        self.url = url
        let fd = open(PrivateFile.path(url), O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw PrivateFileError.io(PrivateFile.path(url), "open: \(PrivateFile.errnoText())") }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Blocks until held.
    public func lock() throws {
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw PrivateFileError.io(PrivateFile.path(url), "flock: \(PrivateFile.errnoText())")
        }
    }

    /// True when the lock was free and is now held.
    public func tryLock() -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    public func unlock() {
        _ = flock(fd, LOCK_UN)
    }
}
