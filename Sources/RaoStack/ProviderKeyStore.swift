//
//  ProviderKeyStore.swift
//  RaoStack
//
//  WHAT: The provider keys (Mistral today) every Rao app's stack shares:
//        RAO_HOME/keys/providers.json, one record per key naming its value,
//        where it came from and which app wrote it.
//  IN:   Writes: the app the user typed the key into (Ambient's Settings
//        projects its Keychain here). Reads: Sewn and every Thread, on every
//        call to a provider.
//  OUT:  `value(for:)` — the file's value when it has one, else the process
//        environment (a dev checkout's .env, a hosted deployment's secrets).
//  PIN:  Read per call and cached by the file's identity (inode, size, mtime),
//        so a key saved in Ambient reaches a shared Sewn and every Thread on
//        their next request, with nothing restarted. The file is 0600 and
//        written atomically under a lock, so apps writing different keys at
//        once both survive. A server only reads the file when its launcher set
//        RAO_HOME (`process`), so hosted deployments are unchanged.
//

import Foundation

public struct ProviderKeyRecord: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The user typed it into an app.
        case typed
        /// The user's account handed it over (Sewn's /v1/account/keys).
        case account
    }

    public var value: String
    public var source: Source
    public var writtenBy: RaoApp
    public var updatedAt: Date

    public init(value: String, source: Source, writtenBy: RaoApp, updatedAt: Date) {
        self.value = value
        self.source = source
        self.writtenBy = writtenBy
        self.updatedAt = updatedAt
    }
}

public final class ProviderKeyStore: @unchecked Sendable {
    public static let mistralAPIKey = "MISTRAL_API_KEY"
    public static let tinkerAPIKey = "TINKER_API_KEY"

    /// A server's store: backed by RAO_HOME's file when its launcher set
    /// RAO_HOME, otherwise the environment alone.
    public static let process = ProviderKeyStore(home: try? RaoHome.fromEnvironment())

    public let file: URL?
    private let lockFile: URL?
    private let environment: @Sendable () -> [String: String]

    private let lock = NSLock()
    private var cachedIdentity: FileIdentity?
    private var cachedRecords: [String: ProviderKeyRecord] = [:]

    public init(
        file: URL?,
        lockFile: URL? = nil,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.file = file
        self.lockFile = lockFile ?? file.map { $0.deletingLastPathComponent().appendingPathComponent(".providers.lock") }
        self.environment = environment
    }

    public convenience init(
        home: RaoHome?,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.init(file: home?.providersFile, lockFile: home?.providersLockFile, environment: environment)
    }

    public var isFileBacked: Bool { file != nil }

    // MARK: - Reading

    /// The key to use now: the shared file's non-empty value, else the
    /// environment's non-empty value, else nil.
    public func value(for name: String) -> String? {
        if let record = record(for: name), !record.value.isEmpty { return record.value }
        if let value = environment()[name], !value.isEmpty { return value }
        return nil
    }

    public func record(for name: String) -> ProviderKeyRecord? {
        records()[name]
    }

    /// Every record in the shared file (empty without one).
    public func records() -> [String: ProviderKeyRecord] {
        guard let file else { return [:] }
        let identity = PrivateFile.identity(file)
        return lock.withLock {
            if identity == cachedIdentity { return cachedRecords }
            cachedIdentity = identity
            cachedRecords = identity == nil ? [:] : Self.decode(file)
            return cachedRecords
        }
    }

    // MARK: - Writing

    /// Sets `name`, keeping every other key as it is.
    public func write(_ name: String, value: String, source: ProviderKeyRecord.Source, writtenBy: RaoApp, now: Date = Date()) throws {
        try update { records in
            records[name] = ProviderKeyRecord(value: value, source: source, writtenBy: writtenBy, updatedAt: now)
        }
    }

    /// Removes `name`, keeping every other key as it is.
    public func remove(_ name: String) throws {
        try update { records in records[name] = nil }
    }

    /// Read-modify-write under the lock: the change applies to whatever the
    /// file holds at that moment, not to what this process last read.
    public func update(_ change: (inout [String: ProviderKeyRecord]) -> Void) throws {
        guard let file, let lockFile else { return }
        try PrivateFile.ensureDirectory(file.deletingLastPathComponent())
        try PrivateFile.withExclusiveLock(lockFile) {
            var records = Self.decode(file)
            let before = records
            change(&records)
            guard records != before else { return }
            try PrivateFile.writeAtomically(try RaoHome.encoder.encode(records), to: file, mode: 0o600)
        }
        lock.withLock { cachedIdentity = nil }
    }

    private static func decode(_ file: URL) -> [String: ProviderKeyRecord] {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)), !data.isEmpty else { return [:] }
        return (try? RaoHome.decoder.decode([String: ProviderKeyRecord].self, from: data)) ?? [:]
    }
}
