//
//  StackSecretInterceptors.swift
//  Conduit
//
//  WHAT: The gRPC half of Ambient's local-stack contract. A mothership the
//        app launched for itself answers only RPCs that carry the launch's
//        secret in x-ambient-secret and arrive over loopback; the Thread it
//        launched stamps that secret on every RPC it sends.
//  IN:   AMBIENT_STACK_SECRET, set by the launcher (Ambient's
//        LocalStackManager) in both children's environments. Sewn hands it
//        to `StackSecretServerInterceptor.forLocalMode`; Thread hands it to
//        `StackSecretClientInterceptor`. Hosted deployments set nothing and
//        get no interceptor — nothing here changes for them.
//  OUT:  PERMISSION_DENIED for a peer that isn't loopback; UNAUTHENTICATED
//        without the secret. The HTTP side of the same contract is
//        X-Ambient-Secret in Sewn/Thread's StackSecretMiddleware.
//  PIN:  A refusal is logged with the method and the peer, never the
//        presented value — a wrong guess in a log line is still a secret.
//        The compare is constant-time so a wrong guess learns nothing from
//        how long it took.
//

import Foundation
import GRPCCore

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

/// Refuses every RPC that doesn't carry the stack secret from a loopback peer.
/// Install on the mothership's `GRPCServer` (``ConduitMothershipServer`` takes
/// it through `interceptors:`); build it with ``forLocalMode(secret:logger:)``
/// so a deployment without a secret gets no interceptor at all.
public struct StackSecretServerInterceptor: ServerInterceptor {

    private let secret: String
    private let requireLoopbackPeer: Bool
    private let logger: (any ConduitLogger)?

    /// - Parameters:
    ///   - secret: The value every request must present.
    ///   - requireLoopbackPeer: Also refuse peers that aren't this machine.
    ///     On by default — the local stack has no business answering the LAN.
    ///   - logger: Where refusals are noted (method and peer, never the value).
    public init(secret: String, requireLoopbackPeer: Bool = true, logger: (any ConduitLogger)? = nil) {
        self.secret = secret
        self.requireLoopbackPeer = requireLoopbackPeer
        self.logger = logger
    }

    /// The interceptor list for a server given `AMBIENT_STACK_SECRET`: one
    /// interceptor when a secret is set, none when it is nil or empty.
    public static func forLocalMode(secret: String?, logger: (any ConduitLogger)? = nil) -> [any ServerInterceptor] {
        guard let secret, !secret.isEmpty else { return [] }
        return [StackSecretServerInterceptor(secret: secret, logger: logger)]
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
        guard StackSecretMetadata.matches(presented, secret: secret) else {
            logger?.warning("StackSecret: refused \(method) from \(peer) — missing or wrong \(StackSecretMetadata.key)")
            throw RPCError(code: .unauthenticated, message: "Missing or wrong x-ambient-secret")
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
