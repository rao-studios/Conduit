//
//  RaoHome.swift
//  RaoStack
//
//  WHAT: Where the shared stack lives: one hidden directory per user, ~/.rao,
//        holding one Sewn, one Thread database per app, each app's secret and
//        the provider keys the user gave any of them.
//  IN:   RAO_HOME (a launcher's override, and how tests and dev runs use a
//        scratch home); otherwise the user's home directory.
//  OUT:  Every path the apps and the servers read or write. Nothing outside
//        this file spells a path under ~/.rao.
//  PIN:  Two entry points on purpose. Apps call `resolved()` and always get a
//        home. Servers call `fromEnvironment()` and get one only when their
//        launcher set RAO_HOME — a hosted Sewn that happens to run as a user
//        with a ~/.rao must not change how it behaves.
//
//        ~/.rao/
//          layout.json
//          secrets/<app>                    0600, 64 hex
//          keys/providers.json              0600
//          sewn/bin/{sewn-server,mlx.metallib}
//          sewn/{install.json,sewn.env,config.json}
//          sewn/db/
//          sewn/run/{sewn.json,sewn.log,start.lock}
//          sewn/leases/<app>.json, <app>.pinned.json
//          apps/<app>/thread-db/
//          apps/<app>/run/{thread.json,thread.log}
//          models/huggingface/
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct RaoHome: Sendable, Hashable, CustomStringConvertible {
    public static let environmentKey = "RAO_HOME"
    public static let directoryName = ".rao"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var description: String { PrivateFile.path(root) }

    // MARK: - Finding the home

    /// For servers: the home their launcher named in RAO_HOME, or nil when it
    /// named none. Throws for a value that isn't an absolute path (after `~`).
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RaoHome? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let expanded = expandTilde(raw)
        guard expanded.hasPrefix("/") else { throw RaoHomeError.notAbsolute(raw) }
        return RaoHome(root: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    /// For apps: RAO_HOME when it names an absolute path, otherwise ~/.rao.
    public static func resolved(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RaoHome {
        if let home = try? fromEnvironment(environment) { return home }
        return RaoHome(root: userHomeDirectory.appendingPathComponent(directoryName, isDirectory: true))
    }

    /// The user's real home directory from the password database, so a
    /// sandbox container or a stray $HOME can't move the shared stack.
    public static var userHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~` and `~/…` against the user's home; anything else unchanged.
    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return PrivateFile.path(userHomeDirectory) }
        if path.hasPrefix("~/") {
            return PrivateFile.path(userHomeDirectory) + String(path.dropFirst(1))
        }
        return path
    }

    // MARK: - Layout

    public var layoutFile: URL { root.appendingPathComponent("layout.json") }

    public var secretsDirectory: URL { root.appendingPathComponent("secrets", isDirectory: true) }
    public func secretFile(for app: RaoApp) -> URL { secretsDirectory.appendingPathComponent(app.rawValue) }

    public var keysDirectory: URL { root.appendingPathComponent("keys", isDirectory: true) }
    public var providersFile: URL { keysDirectory.appendingPathComponent("providers.json") }
    public var providersLockFile: URL { keysDirectory.appendingPathComponent(".providers.lock") }

    public var sewnDirectory: URL { root.appendingPathComponent("sewn", isDirectory: true) }
    public var sewnBinDirectory: URL { sewnDirectory.appendingPathComponent("bin", isDirectory: true) }
    public var sewnBinary: URL { sewnBinDirectory.appendingPathComponent("sewn-server") }
    public var sewnMetallib: URL { sewnBinDirectory.appendingPathComponent("mlx.metallib") }
    public var sewnInstallRecord: URL { sewnDirectory.appendingPathComponent("install.json") }
    public var sewnInstallLockFile: URL { sewnDirectory.appendingPathComponent(".install.lock") }
    public var sewnEnvFile: URL { sewnDirectory.appendingPathComponent("sewn.env") }
    public var sewnConfigFile: URL { sewnDirectory.appendingPathComponent("config.json") }
    public var sewnDataDirectory: URL { sewnDirectory.appendingPathComponent("db", isDirectory: true) }
    public var sewnRunDirectory: URL { sewnDirectory.appendingPathComponent("run", isDirectory: true) }
    public var sewnRunRecord: URL { sewnRunDirectory.appendingPathComponent("sewn.json") }
    public var sewnLogFile: URL { sewnRunDirectory.appendingPathComponent("sewn.log") }
    public var sewnStartLockFile: URL { sewnRunDirectory.appendingPathComponent("start.lock") }
    public var sewnLeasesDirectory: URL { sewnDirectory.appendingPathComponent("leases", isDirectory: true) }
    public func sewnLease(for app: RaoApp) -> URL { sewnLeasesDirectory.appendingPathComponent("\(app.rawValue).json") }
    /// A dev script's lease: held until released, whatever process wrote it.
    public func sewnPinnedLease(for app: RaoApp) -> URL { sewnLeasesDirectory.appendingPathComponent("\(app.rawValue).pinned.json") }

    public var appsDirectory: URL { root.appendingPathComponent("apps", isDirectory: true) }
    public func appDirectory(_ app: RaoApp) -> URL { appsDirectory.appendingPathComponent(app.rawValue, isDirectory: true) }
    public func threadDataDirectory(for app: RaoApp) -> URL { appDirectory(app).appendingPathComponent("thread-db", isDirectory: true) }
    public func threadRunDirectory(for app: RaoApp) -> URL { appDirectory(app).appendingPathComponent("run", isDirectory: true) }
    public func threadRunRecord(for app: RaoApp) -> URL { threadRunDirectory(for: app).appendingPathComponent("thread.json") }
    public func threadLogFile(for app: RaoApp) -> URL { threadRunDirectory(for: app).appendingPathComponent("thread.log") }

    public var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var huggingFaceHome: URL { modelsDirectory.appendingPathComponent("huggingface", isDirectory: true) }
}

public enum RaoHomeError: Error, Equatable, CustomStringConvertible {
    case notAbsolute(String)
    case missing(String)
    case missingSecret(RaoApp)
    case malformedSecret(RaoApp)
    case duplicateSecret([RaoApp])
    case unknownApp(String?)

    public var description: String {
        switch self {
        case .notAbsolute(let value): return "RAO_HOME must be an absolute path, got \"\(value)\""
        case .missing(let path): return "\(path) does not exist — a Rao app provisions it on first launch"
        case .missingSecret(let app): return "no secret for \(app.rawValue) in RAO_HOME/secrets"
        case .malformedSecret(let app): return "secrets/\(app.rawValue) is not 64 hex characters"
        case .duplicateSecret(let apps): return "apps share one secret: \(apps.map(\.rawValue).joined(separator: ", "))"
        case .unknownApp(let value): return "RAO_APP names no Rao app: \(value ?? "unset")"
        }
    }
}
