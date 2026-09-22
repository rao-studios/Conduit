//
//  StackChallenge.swift
//  RaoStack
//
//  WHAT: The client half of /health: what to send, and what the answer says
//        about whoever holds the port.
//  IN:   A launcher's challenge (Ambient's LocalStackManager, the
//        RaoStackLauncher, Veil's SewnClient).
//  OUT:  A verdict the launcher acts on: adopt, spawn, restart or refuse.
//  PIN:  The request carries a fresh nonce and the app's name, never a
//        secret. Only a server that can read that app's secret answers with a
//        proof that checks. A server that proves a different app than the one
//        asked for is stale, not ours.
//

import Foundation

public enum StackVerdict: Equatable, Sendable {
    /// Nothing answered, or not with a 200.
    case down
    /// It proved it holds the app's secret. `contract` is what it reports
    /// (nil from a build before the shared stack).
    case ours(contract: Int?)
    /// It answered, but could not prove the secret: a server left from
    /// another launch or home, or something else holding the port.
    case stale
    /// It asks for no secret: started by hand, or a build from before local
    /// mode. Trusted only by a development binary.
    case open
    /// A build from before the challenge: it echoes "matched"/"mismatched"
    /// and cannot prove anything. Never ours.
    case legacy

    public var isOurs: Bool {
        if case .ours = self { return true }
        return false
    }
}

public enum StackChallenge {

    /// Headers for one /health challenge.
    public static func headers(nonce: String, app: RaoApp?) -> [String: String] {
        var headers = [StackSecret.nonceHeaderName: nonce]
        if let app { headers[StackSecret.appHeaderName] = app.rawValue }
        return headers
    }

    /// Reads a /health answer. `/health` says `"stack": "proof" | "open"`,
    /// and with a well-formed nonce `"proof": <hex>`, checked in constant
    /// time. A 200 that says none of this is something other than Sewn or
    /// Thread.
    public static func verdict(status: Int?, body: Data?, nonce: String, secret: String, expectedApp: RaoApp? = nil) -> StackVerdict {
        guard status == 200 else { return .down }
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        switch object?["stack"] as? String {
        case "open":
            return .open
        case "proof":
            guard StackSecret.isValidProof(object?["proof"] as? String, nonce: nonce, secret: secret) else { return .stale }
            if let expectedApp, let named = object?["app"] as? String, named != expectedApp.rawValue {
                return .stale
            }
            return .ours(contract: object?["contract"] as? Int)
        case "matched", "mismatched":
            return .legacy
        default:
            return .stale
        }
    }
}
