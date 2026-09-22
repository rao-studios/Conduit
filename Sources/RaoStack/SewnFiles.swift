//
//  SewnFiles.swift
//  RaoStack
//
//  WHAT: The small files that describe the shared Sewn and who is using it:
//        its optional config, its install record, its environment file, the
//        run records launchers leave for each server, and the leases apps
//        hold while they need Sewn.
//  IN:   Launchers (write), Sewn (reads sewn.env), every app (reads).
//  OUT:  Agreement between apps on where Sewn listens, what is installed, who
//        started what, and whether anyone else still needs Sewn.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - config.json

/// Optional overrides for the shared Sewn. Nothing writes this by default;
/// a missing or unreadable file means the contract's defaults.
public struct SewnConfig: Codable, Sendable, Equatable {
    public var httpPort: Int?
    public var grpcPort: Int?
    /// Sewn's data directory; `~` is expanded. Default RAO_HOME/sewn/db.
    public var dataDir: String?
    /// HF_HOME for Sewn; `~` is expanded. Default RAO_HOME/models/huggingface.
    public var hfHome: String?

    public init(httpPort: Int? = nil, grpcPort: Int? = nil, dataDir: String? = nil, hfHome: String? = nil) {
        self.httpPort = httpPort
        self.grpcPort = grpcPort
        self.dataDir = dataDir
        self.hfHome = hfHome
    }

    public static func load(from url: URL) -> SewnConfig {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return SewnConfig() }
        return (try? JSONDecoder().decode(SewnConfig.self, from: data)) ?? SewnConfig()
    }

    public static func load(home: RaoHome) -> SewnConfig { load(from: home.sewnConfigFile) }

    public var ports: RaoPorts {
        RaoPorts(http: httpPort ?? RaoPortPlan.sewn.http, grpc: grpcPort ?? RaoPortPlan.sewn.grpc)
    }

    public func dataDirectory(home: RaoHome) -> URL {
        guard let dataDir, !dataDir.isEmpty else { return home.sewnDataDirectory }
        return URL(fileURLWithPath: RaoHome.expandTilde(dataDir), isDirectory: true)
    }

    public func huggingFaceHome(home: RaoHome) -> URL {
        guard let hfHome, !hfHome.isEmpty else { return home.huggingFaceHome }
        return URL(fileURLWithPath: RaoHome.expandTilde(hfHome), isDirectory: true)
    }
}

// MARK: - install.json

/// What sits in RAO_HOME/sewn/bin, and who put it there.
public struct SewnInstallRecord: Codable, Sendable, Equatable {
    public var contract: Int
    public var sha256: String
    public var installedBy: RaoApp
    public var appVersion: String
    public var installedAt: Date

    public init(contract: Int, sha256: String, installedBy: RaoApp, appVersion: String, installedAt: Date) {
        self.contract = contract
        self.sha256 = sha256
        self.installedBy = installedBy
        self.appVersion = appVersion
        self.installedAt = installedAt
    }

    public static func load(home: RaoHome) -> SewnInstallRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(home.sewnInstallRecord)) else { return nil }
        return try? RaoHome.decoder.decode(SewnInstallRecord.self, from: data)
    }

    public func write(home: RaoHome) throws {
        try PrivateFile.writeAtomically(try RaoHome.encoder.encode(self), to: home.sewnInstallRecord, mode: 0o600)
    }
}

// MARK: - Run records and leases

/// A process, named so that a recycled pid can't pass for it: its pid and
/// when it started (microseconds since 1970). A nil start means the launcher
/// couldn't read it; the pid alone is then trusted.
public struct ProcessStamp: Codable, Sendable, Hashable {
    public var pid: Int32
    public var processStart: UInt64?

    public init(pid: Int32, processStart: UInt64?) {
        self.pid = pid
        self.processStart = processStart
    }
}

/// What a launcher leaves beside a server it started: enough for the next
/// launcher, in this app or another, to decide whether that process is still
/// the one it claims to be.
public struct RunRecord: Codable, Sendable, Equatable {
    public struct Launcher: Codable, Sendable, Equatable {
        public var app: RaoApp
        public var process: ProcessStamp

        public init(app: RaoApp, process: ProcessStamp) {
            self.app = app
            self.process = process
        }
    }

    public var process: ProcessStamp
    /// The executable it runs, resolved.
    public var binary: String
    public var ports: RaoPorts
    public var launcher: Launcher?
    public var startedAt: Date

    public init(process: ProcessStamp, binary: String, ports: RaoPorts, launcher: Launcher?, startedAt: Date) {
        self.process = process
        self.binary = binary
        self.ports = ports
        self.launcher = launcher
        self.startedAt = startedAt
    }

    public static func load(_ url: URL) -> RunRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return nil }
        return try? RaoHome.decoder.decode(RunRecord.self, from: data)
    }

    public func write(_ url: URL) throws {
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(try RaoHome.encoder.encode(self), to: url, mode: 0o600)
    }

    public static func remove(_ url: URL) {
        unlink(PrivateFile.path(url))
    }
}

/// An app saying "I still need Sewn". Live while its process is; a pinned
/// lease (a dev script's) lasts until it is released.
public struct RaoLease: Codable, Sendable, Equatable {
    public var app: RaoApp
    public var process: ProcessStamp
    public var pinned: Bool
    public var acquiredAt: Date

    public init(app: RaoApp, process: ProcessStamp, pinned: Bool = false, acquiredAt: Date) {
        self.app = app
        self.process = process
        self.pinned = pinned
        self.acquiredAt = acquiredAt
    }
}

// MARK: - Environment files

/// `KEY=value` files: `#` comments, blank lines, optional `export `, quotes
/// stripped. The shape Sewn's and Thread's `.env` loaders read.
public enum EnvFile {

    public static func parse(_ contents: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            pairs.append((key, value))
        }
        return pairs
    }

    public static func read(_ url: URL) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return [:] }
        var values: [String: String] = [:]
        for pair in parse(String(decoding: data, as: UTF8.self)) { values[pair.key] = pair.value }
        return values
    }

    /// Sets each variable from `url` in this process — unless it is already
    /// set (with `overwrite` false) or `denying` names it. Returns the keys
    /// applied.
    @discardableResult
    public static func apply(_ url: URL, overwrite: Bool = false, denying: Set<String> = []) -> [String] {
        var applied: [String] = []
        for (key, value) in read(url).sorted(by: { $0.key < $1.key }) where !denying.contains(key) {
            if setenv(key, value, overwrite ? 1 : 0) == 0 { applied.append(key) }
        }
        return applied
    }
}

/// RAO_HOME/sewn/sewn.env: the shared Sewn's public configuration, written by
/// the app that installed it from values it ships with, read by Sewn at start.
public enum SewnEnvironmentFile {
    /// All a writer may put there.
    public static let allowedKeys: Set<String> = ["SUPABASE_URL", "SUPABASE_ANON_KEY"]
    /// Never taken from it, whatever it says: secrets and keys have homes of
    /// their own.
    public static let deniedKeys: Set<String> = [
        RaoHome.environmentKey, StackSecret.appEnvironmentKey, StackSecret.environmentKey,
        ProviderKeyStore.mistralAPIKey, ProviderKeyStore.tinkerAPIKey,
    ]

    public enum WriteError: Error, Equatable {
        case disallowedKeys([String])
    }

    public static func write(_ values: [String: String], to url: URL) throws {
        let disallowed = values.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard disallowed.isEmpty else { throw WriteError.disallowedKeys(disallowed) }
        var lines = ["# Written by a Rao app when it installed Sewn. Public values only."]
        for key in values.keys.sorted() {
            lines.append("\(key)=\(values[key]!)")
        }
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(Data((lines.joined(separator: "\n") + "\n").utf8), to: url, mode: 0o600)
    }
}
