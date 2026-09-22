//
//  RaoHome+Provisioning.swift
//  RaoStack
//
//  WHAT: Making ~/.rao exist, privately, with a secret for every app.
//  IN:   Whichever app launches first (Ambient today); any app later, which
//        finds everything already there.
//  OUT:  0700 directories, layout.json, secrets/<app> for every RaoApp.
//  PIN:  Idempotent and race-safe: two apps provisioning at once end with one
//        secret per app, because a secret is published with link(), which
//        fails if the name exists, and is never overwritten afterwards. The
//        first app writes every app's secret so Sewn, whoever starts it, knows
//        all three before the others ever launch.
//

import Foundation

public struct RaoLayout: Codable, Sendable, Equatable {
    public var version: Int
    public var createdBy: RaoApp
    public var createdAt: Date

    public init(version: Int = RaoContract.layoutVersion, createdBy: RaoApp, createdAt: Date) {
        self.version = version
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

extension RaoHome {

    /// Creates whatever is missing and returns every app's secret.
    @discardableResult
    public func provision(by app: RaoApp, now: Date = Date()) throws -> [RaoApp: String] {
        for directory in privateDirectories {
            try PrivateFile.ensureDirectory(directory)
        }
        if !PrivateFile.exists(layoutFile) {
            let layout = RaoLayout(createdBy: app, createdAt: now)
            try PrivateFile.publishIfAbsent(try Self.encoder.encode(layout), to: layoutFile, mode: 0o600)
        }
        var secrets: [RaoApp: String] = [:]
        for each in RaoApp.allCases {
            secrets[each] = try ensureSecret(for: each)
        }
        let byValue = Dictionary(grouping: secrets.keys, by: { secrets[$0]! })
        if let shared = byValue.values.first(where: { $0.count > 1 }) {
            throw RaoHomeError.duplicateSecret(shared.sorted { $0.rawValue < $1.rawValue })
        }
        return secrets
    }

    /// This app's secret, publishing one first if none exists yet. Doesn't
    /// touch any other app's.
    @discardableResult
    public func ensureSecret(for app: RaoApp) throws -> String {
        try PrivateFile.ensureDirectory(root)
        try PrivateFile.ensureDirectory(secretsDirectory)
        if let existing = try readSecret(for: app) { return existing }
        let secret = StackSecret.generate()
        _ = try PrivateFile.publishIfAbsent(Data(secret.utf8), to: secretFile(for: app), mode: 0o600)
        // Whoever won the race, the file now holds the one secret.
        guard let published = try readSecret(for: app) else { throw RaoHomeError.missingSecret(app) }
        return published
    }

    /// `app`'s secret, or nil when none has been published. Throws when the
    /// file is readable by others, owned by someone else, or not 64 hex.
    public func readSecret(for app: RaoApp) throws -> String? {
        let file = secretFile(for: app)
        guard PrivateFile.exists(file) else { return nil }
        try PrivateFile.verifyPrivate(file)
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard StackSecret.isWellFormedSecret(value) else { throw RaoHomeError.malformedSecret(app) }
        return value.lowercased()
    }

    /// The layout file, if one was written.
    public func layout() -> RaoLayout? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(layoutFile)) else { return nil }
        return try? Self.decoder.decode(RaoLayout.self, from: data)
    }

    /// Every directory provisioning creates, 0700.
    public var privateDirectories: [URL] {
        var directories = [
            root, secretsDirectory, keysDirectory,
            sewnDirectory, sewnBinDirectory, sewnDataDirectory, sewnRunDirectory, sewnLeasesDirectory,
            appsDirectory, modelsDirectory,
        ]
        for app in RaoApp.allCases {
            directories.append(appDirectory(app))
            directories.append(threadRunDirectory(for: app))
        }
        return directories
    }

    // MARK: - Coding

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
