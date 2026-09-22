//
//  StackMode.swift
//  RaoStack
//
//  WHAT: How a server's local stack is secured, decided once at start from
//        its environment, and the per-request rules that follow from it: who
//        may call, which app they are, what /health answers.
//  IN:   Sewn and Thread at launch (`sewn(environment:)`, `thread(environment:)`).
//  OUT:  Their HTTP middlewares, their /health routes, their gRPC
//        interceptors (through `singleSecret` / `grpcResolver`).
//  PIN:  Three modes, and a server is only ever in one.
//        - open: no secret. Hosted deployments, Mary, Bonnie, Fleet, dev
//          scripts. Nothing here changes for them; /health's JSON is exactly
//          what it was.
//        - single: one secret, the one-app stack Ambient 1.0 launched and
//          every app's own Thread on a shared stack.
//        - multiApp: a shared Sewn, which accepts each app's secret and knows
//          which app is calling by which one matched. Only RAO_HOME turns it
//          on; it wins over AMBIENT_STACK_SECRET when both are set.
//        A Thread told to use RAO_HOME never comes up open: without its
//        secret it refuses to start.
//

import Foundation

public enum StackMode: Sendable {
    case open
    case single(secret: String, app: RaoApp?)
    case multiApp(StackKeyring)

    // MARK: - From the environment

    /// Sewn's mode: RAO_HOME → multiApp; else AMBIENT_STACK_SECRET → single;
    /// else open. Throws for a RAO_HOME that isn't usable.
    public static func sewn(environment: [String: String]) throws -> StackMode {
        if let home = try RaoHome.fromEnvironment(environment) {
            guard PrivateFile.exists(home.root) else { throw RaoHomeError.missing(PrivateFile.path(home.root)) }
            try PrivateFile.verifyPrivate(home.root)
            return .multiApp(StackKeyring(home: home))
        }
        if let secret = nonEmpty(environment[StackSecret.environmentKey]) {
            return .single(secret: secret, app: RaoApp(header: environment[StackSecret.appEnvironmentKey]))
        }
        return .open
    }

    /// A Thread's mode: always one app's secret or none. AMBIENT_STACK_SECRET
    /// → single; else RAO_HOME + RAO_APP → single with secrets/<app>; RAO_HOME
    /// without a usable app or secret throws (never open); else open.
    public static func thread(environment: [String: String]) throws -> StackMode {
        let app = RaoApp(header: environment[StackSecret.appEnvironmentKey])
        if let secret = nonEmpty(environment[StackSecret.environmentKey]) {
            return .single(secret: secret, app: app)
        }
        if let home = try RaoHome.fromEnvironment(environment) {
            guard let app else { throw RaoHomeError.unknownApp(environment[StackSecret.appEnvironmentKey]) }
            guard let secret = try home.readSecret(for: app) else { throw RaoHomeError.missingSecret(app) }
            return .single(secret: secret, app: app)
        }
        return .open
    }

    /// Whether AMBIENT_STACK_SECRET was set but ignored because RAO_HOME won.
    public static func ignoresSingleSecret(sewnEnvironment environment: [String: String]) -> Bool {
        (try? RaoHome.fromEnvironment(environment)) != nil && nonEmpty(environment[StackSecret.environmentKey]) != nil
    }

    // MARK: - Facts

    /// Any secret at all: loopback only, secret required, no CORS.
    public var isLocal: Bool {
        if case .open = self { return false }
        return true
    }

    /// The one secret, for a single-secret gRPC interceptor or a Thread's
    /// mothership client.
    public var singleSecret: String? {
        if case .single(let secret, _) = self { return secret }
        return nil
    }

    /// The app a single-secret server belongs to, when its launcher said.
    public var app: RaoApp? {
        if case .single(_, let app) = self { return app }
        return nil
    }

    public var keyring: StackKeyring? {
        if case .multiApp(let keyring) = self { return keyring }
        return nil
    }

    /// For Conduit's `StackSecretServerInterceptor(resolver:)` and
    /// `ThreadRegistrationServiceImpl(callerResolver:)`: presented secret →
    /// app id. Nil unless multiApp.
    public var grpcResolver: (@Sendable (String) -> String?)? {
        guard case .multiApp(let keyring) = self else { return nil }
        return { presented in keyring.app(forPresented: presented)?.rawValue }
    }

    /// One line for the startup log. Never a secret.
    public var summary: String {
        switch self {
        case .open:
            return "open (no stack secret)"
        case .single(_, let app):
            return "local, one secret" + (app.map { " (\($0.rawValue))" } ?? "")
        case .multiApp(let keyring):
            let apps = keyring.provisionedApps.map(\.rawValue).joined(separator: ", ")
            return "shared, one secret per app (\(apps.isEmpty ? "none provisioned yet" : apps))"
        }
    }

    // MARK: - Per request

    /// Whether a request may pass, and as which app. /health is not asked.
    public func admit(authority: String?, presented: String?) -> StackAdmission {
        switch self {
        case .open:
            return .admitted(nil)
        case .single(let secret, let app):
            guard StackSecret.isLoopback(authority: authority) else { return .notLoopback }
            return StackSecret.matches(presented, secret: secret) ? .admitted(app) : .badSecret
        case .multiApp(let keyring):
            guard StackSecret.isLoopback(authority: authority) else { return .notLoopback }
            guard let app = keyring.app(forPresented: presented) else { return .badSecret }
            return .admitted(app)
        }
    }

    /// What /health answers. The secret itself never answers; a proof needs a
    /// well-formed nonce and, on a shared Sewn, an app it knows.
    public func healthAnswer(nonce: String?, requestedApp: String?) -> StackHealthAnswer {
        switch self {
        case .open:
            return StackHealthAnswer(stack: "open", proof: nil, app: nil, contract: nil)
        case .single(let secret, let app):
            guard let nonce, StackSecret.isWellFormedNonce(nonce) else {
                return StackHealthAnswer(stack: "proof", proof: nil, app: app, contract: RaoContract.version)
            }
            return StackHealthAnswer(stack: "proof", proof: StackSecret.proof(nonce: nonce, secret: secret),
                                     app: app, contract: RaoContract.version)
        case .multiApp(let keyring):
            guard let nonce, StackSecret.isWellFormedNonce(nonce),
                  let app = RaoApp(header: requestedApp),
                  let secret = keyring.secret(for: app) else {
                return StackHealthAnswer(stack: "proof", proof: nil, app: nil, contract: RaoContract.version)
            }
            return StackHealthAnswer(stack: "proof", proof: StackSecret.proof(nonce: nonce, secret: secret),
                                     app: app, contract: RaoContract.version)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum StackAdmission: Sendable, Equatable {
    /// Pass. The app is known on a shared Sewn and on a Thread whose launcher
    /// named it; nil when open.
    case admitted(RaoApp?)
    /// 421: the Host isn't this machine.
    case notLoopback
    /// 401: no secret, or not one this server knows.
    case badSecret

    public var app: RaoApp? {
        if case .admitted(let app) = self { return app }
        return nil
    }
}

/// /health's stack fields. `proof`, `app` and `contract` are left out of the
/// JSON when nil, so an open server's answer is unchanged.
public struct StackHealthAnswer: Sendable, Equatable, Codable {
    public let stack: String
    public let proof: String?
    public let app: RaoApp?
    public let contract: Int?

    public init(stack: String, proof: String?, app: RaoApp?, contract: Int?) {
        self.stack = stack
        self.proof = proof
        self.app = app
        self.contract = contract
    }
}
