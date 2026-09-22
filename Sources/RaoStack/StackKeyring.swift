//
//  StackKeyring.swift
//  RaoStack
//
//  WHAT: Every app's stack secret, as a shared Sewn holds them: which app a
//        presented secret belongs to, and which secret to prove for an app.
//  IN:   RAO_HOME/secrets/<app>, read at start and again when a well-formed
//        secret misses (an app provisioned after Sewn started) or the ring is
//        a minute old (a secret revoked by deleting its file).
//  OUT:  StackMode.multiApp → the HTTP middleware, /health, the gRPC resolver.
//  PIN:  A presented value is compared against every entry, with no early
//        exit, so timing says nothing about which app — or whether any —
//        matched. A file anyone else can read is skipped, not trusted. Two apps
//        with one value are both dropped: that value can't say which app it is.
//        Reloads on a miss are throttled, so a stream of bad guesses can't turn
//        into a stream of file reads.
//

import Foundation

public final class StackKeyring: @unchecked Sendable {

    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public let app: RaoApp?
        public let reason: String
        public var description: String { app.map { "\($0.rawValue): \(reason)" } ?? reason }
    }

    private let home: RaoHome?
    private let minimumReloadInterval: TimeInterval
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var secrets: [RaoApp: String] = [:]
    private var loadedAt: Date = .distantPast
    private var issues: [Issue] = []

    /// A ring read from `home`'s secrets directory.
    public init(
        home: RaoHome,
        minimumReloadInterval: TimeInterval = 2,
        maximumAge: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.minimumReloadInterval = minimumReloadInterval
        self.maximumAge = maximumAge
        self.now = now
        reload()
    }

    /// A fixed ring, for tests: never reloads, and takes the values as given.
    public init(fixed: [RaoApp: String]) {
        self.home = nil
        self.minimumReloadInterval = .infinity
        self.maximumAge = .infinity
        self.now = { Date() }
        self.secrets = fixed
        self.loadedAt = Date()
    }

    // MARK: - Lookups

    /// The app `presented` is the secret of, or nil.
    public func app(forPresented presented: String?) -> RaoApp? {
        guard let presented, !presented.isEmpty else { return nil }
        refreshIfOld()
        if let app = match(presented) { return app }
        // A secret published after the last read — an app that provisioned
        // itself while this Sewn was running. Only a well-formed value earns
        // a reload.
        guard StackSecret.isWellFormedSecret(presented), reloadIfAllowed() else { return nil }
        return match(presented)
    }

    /// `app`'s secret, for proving it on /health; nil when it has none.
    public func secret(for app: RaoApp) -> String? {
        refreshIfOld()
        if let secret = lock.withLock({ secrets[app] }) { return secret }
        guard reloadIfAllowed() else { return nil }
        return lock.withLock { secrets[app] }
    }

    public var provisionedApps: [RaoApp] {
        lock.withLock { RaoApp.allCases.filter { secrets[$0] != nil } }
    }

    public var lastIssues: [Issue] { lock.withLock { issues } }

    // MARK: - Loading

    /// Reads every app's secret again. Returns what was skipped and why.
    @discardableResult
    public func reload() -> [Issue] {
        guard let home else { return [] }
        var loaded: [RaoApp: String] = [:]
        var found: [Issue] = []
        for app in RaoApp.allCases {
            do {
                if let secret = try home.readSecret(for: app) { loaded[app] = secret }
            } catch {
                found.append(Issue(app: app, reason: "\(error)"))
            }
        }
        let byValue = Dictionary(grouping: loaded.keys, by: { loaded[$0]! })
        for apps in byValue.values where apps.count > 1 {
            for app in apps { loaded[app] = nil }
            found.append(Issue(app: nil, reason: "\(apps.map(\.rawValue).sorted().joined(separator: ", ")) share one secret; none of them is accepted"))
        }
        let stamp = now()
        lock.withLock {
            secrets = loaded
            issues = found
            loadedAt = stamp
        }
        return found
    }

    private func match(_ presented: String) -> RaoApp? {
        let entries = lock.withLock { secrets }
        var found: RaoApp?
        for app in RaoApp.allCases {
            // Every entry is compared, match or not.
            if StackSecret.matches(presented, secret: entries[app]) { found = app }
        }
        return found
    }

    private func refreshIfOld() {
        guard home != nil else { return }
        let age = now().timeIntervalSince(lock.withLock { loadedAt })
        if age >= maximumAge { reload() }
    }

    /// Reloads unless one happened within the throttle; true when it did.
    private func reloadIfAllowed() -> Bool {
        guard home != nil else { return false }
        let age = now().timeIntervalSince(lock.withLock { loadedAt })
        guard age >= minimumReloadInterval else { return false }
        reload()
        return true
    }
}
