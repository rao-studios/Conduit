//
//  SewnInstaller.swift
//  RaoStackLauncher
//
//  WHAT: Puts the Sewn an app ships with into RAO_HOME/sewn/bin, where every
//        Rao app runs it from, and checks what is there before anyone runs it.
//  IN:   The "vessel" app at launch (Ambient today): its bundled sewn-server
//        and mlx.metallib, its version, the public values Sewn needs.
//  OUT:  bin/sewn-server, bin/mlx.metallib, install.json, sewn.env.
//  PIN:  Install when nothing is there; replace when the bundled contract is
//        newer, or when it is the same contract, this app installed it, and
//        the bytes differ (this app was updated). Never downgrade, never
//        replace another app's newer or equal install. Files are copied beside
//        their destination and renamed into place: overwriting a signed
//        executable in place can get a running copy killed, and a reader must
//        never see half a binary. Symlinks are resolved (the app bundle keeps
//        mlx.metallib as one); quarantine is stripped. A bundled binary that
//        fails the signature policy is never installed.
//

#if os(macOS)
import Darwin
import Foundation
import RaoStack

public struct SewnPayload: Sendable, Equatable {
    public var binary: URL
    public var metallib: URL?
    /// Free text for install.json, e.g. "1.0.0 (1) 5984003".
    public var appVersion: String
    public var contract: Int
    /// Written to sewn.env (SewnEnvironmentFile.allowedKeys only).
    public var publicEnvironment: [String: String]

    public init(binary: URL, metallib: URL?, appVersion: String, contract: Int = RaoContract.version,
                publicEnvironment: [String: String] = [:]) {
        self.binary = binary
        self.metallib = metallib
        self.appVersion = appVersion
        self.contract = contract
        self.publicEnvironment = publicEnvironment
    }
}

public enum SewnInstallOutcome: Sendable, Equatable {
    /// This call put the payload in place; `replaced` is what was there.
    case installed(SewnInstallRecord, replaced: SewnInstallRecord?)
    /// The payload was already installed.
    case alreadyCurrent(SewnInstallRecord)
    /// Another install stays: newer, or equal and not this app's.
    case keptExisting(SewnInstallRecord)

    public var record: SewnInstallRecord {
        switch self {
        case .installed(let record, _), .alreadyCurrent(let record), .keptExisting(let record): return record
        }
    }
}

public enum SewnInstallError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case modified(expected: String, found: String)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .notInstalled: return "no Sewn is installed in ~/.rao"
        case .modified: return "the Sewn in ~/.rao no longer matches what was installed"
        case .copyFailed(let reason): return "couldn't install Sewn: \(reason)"
        }
    }
}

public struct SewnInstaller: Sendable {
    public let home: RaoHome
    public let policy: SignaturePolicy

    public init(home: RaoHome, policy: SignaturePolicy = .standard) {
        self.home = home
        self.policy = policy
    }

    public func installedRecord() -> SewnInstallRecord? {
        guard PrivateFile.exists(home.sewnBinary) else { return nil }
        return SewnInstallRecord.load(home: home)
    }

    public var isInstalled: Bool { installedRecord() != nil }

    /// What a vessel would do with `payload`, without doing it.
    public static func decision(bundled contract: Int, bundledSHA: String, by app: RaoApp, existing: SewnInstallRecord?) -> Decision {
        guard let existing else { return .install }
        if existing.sha256 == bundledSHA { return .current }
        if contract > existing.contract { return .install }
        if contract == existing.contract && existing.installedBy == app { return .install }
        return .keep
    }

    public enum Decision: Sendable, Equatable {
        case install, current, keep
    }

    /// Installs `payload` when the rules say so. Serialized across processes.
    @discardableResult
    public func installIfNeeded(_ payload: SewnPayload, by app: RaoApp, now: Date = Date()) throws -> SewnInstallOutcome {
        try PrivateFile.ensureDirectory(home.sewnDirectory)
        try PrivateFile.ensureDirectory(home.sewnBinDirectory)
        return try PrivateFile.withExclusiveLock(home.sewnInstallLockFile) {
            let source = payload.binary.resolvingSymlinksInPath()
            let bundledSHA = try FileDigest.sha256(of: source)
            let existing = installedRecord()
            switch Self.decision(bundled: payload.contract, bundledSHA: bundledSHA, by: app, existing: existing) {
            case .current:
                let record = existing!
                // A metallib added since, or removed by hand: put it back.
                if let metallib = payload.metallib, !PrivateFile.exists(home.sewnMetallib) {
                    try place(metallib.resolvingSymlinksInPath(), at: home.sewnMetallib, mode: 0o644)
                }
                try writeEnvironmentIfMissing(payload.publicEnvironment)
                return .alreadyCurrent(record)
            case .keep:
                return .keptExisting(existing!)
            case .install:
                try policy.check(source)
                try place(source, at: home.sewnBinary, mode: 0o755)
                if let metallib = payload.metallib {
                    try place(metallib.resolvingSymlinksInPath(), at: home.sewnMetallib, mode: 0o644)
                }
                let record = SewnInstallRecord(contract: payload.contract, sha256: bundledSHA, installedBy: app,
                                               appVersion: payload.appVersion, installedAt: now)
                try record.write(home: home)
                if !payload.publicEnvironment.isEmpty {
                    try SewnEnvironmentFile.write(payload.publicEnvironment, to: home.sewnEnvFile)
                }
                return .installed(record, replaced: existing)
            }
        }
    }

    /// Throws unless the installed Sewn is what install.json says and passes
    /// the signature policy. Run before every exec of it.
    public func verifyInstalled() throws {
        guard let record = installedRecord() else { throw SewnInstallError.notInstalled }
        let found = try FileDigest.sha256(of: home.sewnBinary)
        guard found == record.sha256 else { throw SewnInstallError.modified(expected: record.sha256, found: found) }
        try policy.check(home.sewnBinary)
    }

    // MARK: - Files

    private func writeEnvironmentIfMissing(_ values: [String: String]) throws {
        guard !values.isEmpty, !PrivateFile.exists(home.sewnEnvFile) else { return }
        try SewnEnvironmentFile.write(values, to: home.sewnEnvFile)
    }

    /// Copies `source` beside `destination` and renames it into place.
    private func place(_ source: URL, at destination: URL, mode: mode_t) throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(getpid()).\(UInt32.random(in: .min ... .max)).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
        } catch {
            throw SewnInstallError.copyFailed("\(error.localizedDescription)")
        }
        let tempPath = PrivateFile.path(temp)
        _ = chmod(tempPath, mode)
        _ = removexattr(tempPath, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard rename(tempPath, PrivateFile.path(destination)) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(tempPath)
            throw SewnInstallError.copyFailed("rename: \(reason)")
        }
    }
}
#endif
