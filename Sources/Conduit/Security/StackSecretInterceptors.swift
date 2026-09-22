//
//  StackSecretInterceptors.swift
//  Conduit
//
//  WHAT: The gRPC half of Ambient's local-stack contract. A mothership the
//        app launched for itself answers only RPCs that carry the launch's
//        secret in x-ambient-secret and arrive over loopback; the Thread it
//        launched stamps that secret on every RPC it sends.
//  IN:   One app's stack: AMBIENT_STACK_SECRET, set by the launcher in both
//        children's environments; Sewn hands it to
//        `StackSecretServerInterceptor.forLocalMode(secret:)`, Thread to
//        `StackSecretClientInterceptor`. A shared ~/.rao stack: Sewn knows
//        every app's secret and hands a resolver (presented secret → app id)
//        to `forLocalMode(resolver:)`, so one mothership accepts each app's
//        Thread and knows which app it belongs to. Hosted deployments set
//        nothing and get no interceptor — nothing here changes for them.
//  OUT:  PERMISSION_DENIED for a peer that isn't loopback; UNAUTHENTICATED
//        without a secret the server knows. The HTTP side of the same
//        contract is X-Ambient-Secret in Sewn/Thread's StackSecretMiddleware.
//  PIN:  A refusal is logged with the method and the peer, never the
//        presented value — a wrong guess in a log line is still a secret.
//        The compare is constant-time so a wrong guess learns nothing from
//        how long it took.
//

import Foundation
import GRPCCore

/// Maps a presented stack secret to the app it belongs to — `"ambient"`,
/// `"craft"`, `"veil"` — or nil when it is no app's secret. A shared stack's
/// mothership builds one from the keyring in ~/.rao (RaoStack's `StackMode`);
/// Conduit only needs the answer, never the secrets themselves.
public typealias StackSecretResolver = @Sendable (_ presented: String) -> String?

/// The metadata key both halves agree on, and the checks the server applies.
public enum StackSecretMetadata {

    /// gRPC metadata keys are lowercase on the wire; this is the HTTP header
    /// `X-Ambient-Secret` as gRPC spells it.
    public static let key = "x-ambient-secret"

    /// The first `x-ambient-secret` value on the request, if any.
    public static func presented(in metadata: Metadata) -> String? {
        var values = metadata[stringValues: key].makeIterator()
        return values.next()
    }

    /// The app whose secret `metadata` presents, per `resolver`; nil when the
    /// request carries no secret or one no app owns.
    public static func callerApp(in metadata: Metadata, resolver: StackSecretResolver) -> String? {
        guard let presented = presented(in: metadata), !presented.isEmpty else { return nil }
        return resolver(presented)
    }

    /// Constant-time byte compare. False for nil and for any length mismatch
    /// (checked up front: the length of the secret isn't what it protects).
    public static func matches(_ presented: String?, secret: String) -> Bool {
        guard let presented else { return false }
        let expected = Array(secret.utf8)
        let given = Array(presented.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ given[index]
        }
        return difference == 0
    }

    /// Whether `peer` (a `ServerContext.remotePeer` string) is this machine:
    /// `ipv4:127.x.x.x:port`, `ipv6:[::1]:port`, an IPv4-mapped loopback,
    /// a Unix socket, or grpc-swift's in-process transport.
    public static func isLoopbackPeer(_ peer: String) -> Bool {
        loopbackPeerPrefixes.contains { peer.hasPrefix($0) }
    }

    private static let loopbackPeerPrefixes = [
        "ipv4:127.",
        "ipv6:[::1]:",
        "ipv6:[::ffff:127.",
        "unix:",
        "in-process:",
    ]
}

// MARK: - Server side

/// Refuses every RPC that doesn't carry a stack secret the server knows, from
/// a loopback peer. Install on the mothership's `GRPCServer`
/// (``ConduitMothershipServer`` takes it through `interceptors:`); build it
/// with ``forLocalMode(secret:logger:)`` for one app's stack, or
/// ``forLocalMode(resolver:logger:)`` for a shared one, so a deployment
/// without either gets no interceptor at all.
public struct StackSecretServerInterceptor: ServerInterceptor {

    private enum Check: Sendable {
        case secret(String)
        case resolver(StackSecretResolver)
    }

    private let check: Check
    private let requireLoopbackPeer: Bool
    private let logger: (any ConduitLogger)?

    /// - Parameters:
    ///   - secret: The value every request must present.
    ///   - requireLoopbackPeer: Also refuse peers that aren't this machine.
    ///     On by default — the local stack has no business answering the LAN.
    ///   - logger: Where refusals are noted (method and peer, never the value).
    public init(secret: String, requireLoopbackPeer: Bool = true, logger: (any ConduitLogger)? = nil) {
        self.check = .secret(secret)
        self.requireLoopbackPeer = requireLoopbackPeer
        self.logger = logger
    }

    /// A shared stack: accept any secret `resolver` maps to an app.
    /// - Parameters:
    ///   - resolver: Presented secret → app id, or nil for no app's secret.
    ///   - requireLoopbackPeer: As for ``init(secret:requireLoopbackPeer:logger:)``.
    ///   - logger: Where refusals are noted (method and peer, never the value).
    public init(resolver: @escaping StackSecretResolver, requireLoopbackPeer: Bool = true, logger: (any ConduitLogger)? = nil) {
        self.check = .resolver(resolver)
        self.requireLoopbackPeer = requireLoopbackPeer
        self.logger = logger
    }

    /// The interceptor list for a server given `AMBIENT_STACK_SECRET`: one
    /// interceptor when a secret is set, none when it is nil or empty.
    public static func forLocalMode(secret: String?, logger: (any ConduitLogger)? = nil) -> [any ServerInterceptor] {
        guard let secret, !secret.isEmpty else { return [] }
        return [StackSecretServerInterceptor(secret: secret, logger: logger)]
    }

    /// The interceptor list for a shared stack's mothership: one interceptor
    /// when a resolver is given, none when it is nil.
    public static func forLocalMode(resolver: StackSecretResolver?, logger: (any ConduitLogger)? = nil) -> [any ServerInterceptor] {
        guard let resolver else { return [] }
        return [StackSecretServerInterceptor(resolver: resolver, logger: logger)]
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let method = context.descriptor.fullyQualifiedMethod
        let peer = context.remotePeer

        if requireLoopbackPeer, !StackSecretMetadata.isLoopbackPeer(peer) {
            logger?.warning("StackSecret: refused \(method) from \(peer) — not a loopback peer")
            throw RPCError(code: .permissionDenied, message: "This server answers on loopback only")
        }

        let presented = StackSecretMetadata.presented(in: request.metadata)
        switch check {
        case .secret(let secret):
            guard StackSecretMetadata.matches(presented, secret: secret) else {
                logger?.warning("StackSecret: refused \(method) from \(peer) — missing or wrong \(StackSecretMetadata.key)")
                throw RPCError(code: .unauthenticated, message: "Missing or wrong x-ambient-secret")
            }
        case .resolver(let resolver):
            guard let presented, !presented.isEmpty, resolver(presented) != nil else {
                logger?.warning("StackSecret: refused \(method) from \(peer) — missing or unknown \(StackSecretMetadata.key)")
                throw RPCError(code: .unauthenticated, message: "Missing or unknown x-ambient-secret")
            }
        }

        return try await next(request, context)
    }
}

// MARK: - Client side

/// Stamps the stack secret onto every RPC. Install on the Thread's client
/// (``MothershipRegistrationClient`` takes it through `interceptors:`). With
/// no secret to present it passes requests through untouched, so it is safe
/// to install unconditionally and let the closure decide.
public struct StackSecretClientInterceptor: ClientInterceptor {

    private let secret: @Sendable () -> String?

    /// - Parameter secret: Read on every RPC; nil or empty means "add nothing".
    public init(secret: @escaping @Sendable () -> String?) {
        self.secret = secret
    }

    /// A fixed secret, e.g. the value of `AMBIENT_STACK_SECRET` read at launch.
    public init(secret: String) {
        self.init(secret: { secret })
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        guard let value = secret(), !value.isEmpty else {
            return try await next(request, context)
        }
        var request = request
        request.metadata.replaceOrAddString(value, forKey: StackSecretMetadata.key)
        return try await next(request, context)
    }
}
