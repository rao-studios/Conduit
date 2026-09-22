//
//  RaoStackSupervisor.swift
//  RaoStackLauncher
//
//  WHAT: One app's view of the shared stack: its home and secret, the shared
//        Sewn (adopted or started, held by a lease), and its own Thread.
//  IN:   Craft and Veil at launch and quit. (Ambient drives the same
//        contract through its own LocalStackManager for its first shared
//        release; folding it onto this is a follow-up.)
//  OUT:  Handles to a proved Sewn and a proved Thread; a quit that stops the
//        app's Thread, and Sewn only when no other app still needs it.
//  PIN:  Only the vessel app installs Sewn (SewnInstaller); this supervisor
//        runs whatever is installed, after checking it is what install.json
//        says and is signed by Rao. A development launch may name a checkout
//        build instead.
//

#if os(macOS)
import Foundation
import RaoStack

public actor RaoStackSupervisor {
    public nonisolated let app: RaoApp
    public nonisolated let home: RaoHome
    public nonisolated let policy: SignaturePolicy
    private let environment: [String: String]
    private var sewnServer: ManagedServer?
    private var threadServer: ManagedServer?
    private let leaseHeld = LeaseFlag()

    public init(
        app: RaoApp,
        home: RaoHome = .resolved(),
        policy: SignaturePolicy = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.app = app
        self.home = home
        self.policy = policy
        self.environment = environment
    }

    // MARK: - Facts

    public nonisolated var installer: SewnInstaller { SewnInstaller(home: home, policy: policy) }
    public nonisolated var leases: SewnLeases { SewnLeases(home: home) }
    public nonisolated var sewnIsInstalled: Bool { installer.isInstalled }
    public nonisolated var sewnPorts: RaoPorts { SewnConfig.load(home: home).ports }

    /// Creates whatever of ~/.rao is missing; returns this app's secret.
    @discardableResult
    public func prepare() throws -> String {
        let secrets = try home.provision(by: app)
        guard let secret = secrets[app] else { throw RaoHomeError.missingSecret(app) }
        return secret
    }

    // MARK: - Sewn

    /// The shared Sewn, adopted or started, with this app's lease on it.
    /// - Parameters:
    ///   - executable: A checkout build to run instead of the installed Sewn
    ///     (development). Nil runs RAO_HOME/sewn/bin/sewn-server, verified.
    ///   - workingDirectory: Where a checkout build runs (its `.env`).
    ///   - pinned: Hold the lease until `releaseSewn(pinned: true)`, whatever
    ///     happens to this process (a dev script).
    public func ensureSewn(
        executable: URL? = nil,
        workingDirectory: URL? = nil,
        pinned: Bool = false,
        timeout: TimeInterval = 60
    ) async throws -> ServerHandle {
        let secret = try home.ensureSecret(for: app)
        if executable == nil { try installer.verifyInstalled() }
        try leases.acquire(for: app, pinned: pinned)
        if !pinned { leaseHeld.set(true) }
        let spec = LaunchSpecs.sewn(home: home, executable: executable, workingDirectory: workingDirectory,
                                    challengeApp: app, inherited: environment)
        let server = reuse(sewnServer, for: spec) ?? ManagedServer(
            spec: spec, secret: secret, launcherApp: app,
            policy: executable == nil ? policy : nil,
            othersNeedIt: { [leases, app] in leases.others(excluding: app) })
        sewnServer = server
        return try await server.ensureRunning(timeout: timeout)
    }

    /// Lets go of this app's lease; stops Sewn when no one else holds one.
    public func releaseSewn(pinned: Bool = false, stopIfLastHolder: Bool = true) async {
        leases.release(for: app, pinned: pinned)
        if !pinned { leaseHeld.set(false) }
        guard stopIfLastHolder, leases.live().isEmpty else { return }
        if let sewnServer {
            await sewnServer.stop()
        } else {
            ManagedServer.stopRecordedSync(home.sewnRunRecord)
        }
    }

    // MARK: - Thread

    /// This app's Thread, adopted or started.
    public func ensureThread(
        executable: URL,
        options: ThreadLaunchOptions = ThreadLaunchOptions(),
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 60
    ) async throws -> ServerHandle {
        let secret = try home.ensureSecret(for: app)
        try PrivateFile.ensureDirectory(home.appDirectory(app))
        try PrivateFile.ensureDirectory(home.threadRunDirectory(for: app))
        let spec = LaunchSpecs.thread(for: app, home: home, executable: executable, secret: secret,
                                      sewnPorts: sewnPorts, options: options,
                                      workingDirectory: workingDirectory, inherited: environment)
        let server = reuse(threadServer, for: spec) ?? ManagedServer(spec: spec, secret: secret, launcherApp: app)
        threadServer = server
        return try await server.ensureRunning(timeout: timeout)
    }

    public func stopThread() async {
        if let threadServer {
            await threadServer.stop()
        } else {
            ManagedServer.stopRecordedSync(home.threadRunRecord(for: app), launchedBy: ProcessProbe.current)
        }
    }

    // MARK: - Quit

    public func shutdown() async {
        await stopThread()
        if leaseHeld.value { await releaseSewn() }
    }

    /// For a terminate handler that can't await: stops the Thread this
    /// process started, drops this process's lease and stops Sewn if nobody
    /// else holds one.
    public nonisolated func shutdownSync() {
        ManagedServer.stopRecordedSync(home.threadRunRecord(for: app), launchedBy: ProcessProbe.current)
        guard leaseHeld.value else { return }
        leases.release(for: app)
        leaseHeld.set(false)
        if leases.live().isEmpty { ManagedServer.stopRecordedSync(home.sewnRunRecord) }
    }

    private func reuse(_ server: ManagedServer?, for spec: LaunchSpec) -> ManagedServer? {
        guard let server, server.spec == spec else { return nil }
        return server
    }
}

/// Whether this process holds its app's Sewn lease, readable from a
/// terminate handler.
final class LeaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    var value: Bool { lock.withLock { held } }
    func set(_ value: Bool) { lock.withLock { held = value } }
}
#endif
