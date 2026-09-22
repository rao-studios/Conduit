//
//  StackSecret.swift
//  RaoStack
//
//  WHAT: The primitives of the local-stack handshake, in one place: the names
//        on the wire, secret and nonce generation, the constant-time compare,
//        the /health proof and the loopback checks.
//  IN:   Sewn and Thread (server side), Ambient, Craft and Veil (client side).
//        These used to be copied into each of them.
//  OUT:  StackMode (servers), StackChallenge (clients), the launchers.
//  PIN:  The proof is lowercase hex of HMAC-SHA256(key: secret,
//        message: "ambient-stack-health-v1:" + nonce), nonce exactly as sent.
//        Unchanged from the one-app stack, so a server and an app built on
//        either side of this move still agree. The known-answer vectors in
//        RaoStackTests pin it.
//

import Crypto
import Foundation

public enum StackSecret {
    /// The launcher sets it on a Thread (its app's secret) and, on a one-app
    /// stack, on Sewn. A shared Sewn reads every app's secret from RAO_HOME.
    public static let environmentKey = "AMBIENT_STACK_SECRET"
    /// Which app a Thread belongs to on a shared stack.
    public static let appEnvironmentKey = "RAO_APP"

    /// HTTP: the caller's secret on every request except /health.
    public static let headerName = "X-Ambient-Secret"
    /// HTTP: the challenge on /health. Never the secret.
    public static let nonceHeaderName = "X-Ambient-Nonce"
    /// HTTP: on /health only, which app's secret the proof should use.
    /// Trusted nowhere else — a request's app is whichever secret it carries.
    public static let appHeaderName = "X-Rao-App"
    /// gRPC: `X-Ambient-Secret` as gRPC spells metadata keys.
    public static let metadataKey = "x-ambient-secret"
    /// Domain-separates the proof, so /health is not a general HMAC oracle.
    public static let proofDomain = "ambient-stack-health-v1:"

    // MARK: - Generation

    /// 32 random bytes, lowercase hex: one app's secret.
    public static func generate() -> String { randomHex(bytes: 32) }

    /// 16 random bytes, lowercase hex: one challenge, never reused.
    public static func nonce() -> String { randomHex(bytes: 16) }

    private static func randomHex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return hex((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: - Shape

    /// Exactly 64 hex characters, either case.
    public static func isWellFormedSecret(_ secret: String) -> Bool {
        secret.utf8.count == 64 && secret.utf8.allSatisfy(isHexDigit)
    }

    /// 16...128 hex characters, either case.
    public static func isWellFormedNonce(_ nonce: String) -> Bool {
        (16...128).contains(nonce.utf8.count) && nonce.utf8.allSatisfy(isHexDigit)
    }

    // MARK: - Comparing and proving

    /// Constant-time byte compare. False for nil and for any length mismatch
    /// (checked up front: the length of the secret isn't what it protects).
    public static func matches(_ presented: String?, secret: String?) -> Bool {
        guard let presented, let secret else { return false }
        let expected = Array(secret.utf8)
        let given = Array(presented.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ given[index]
        }
        return difference == 0
    }

    /// What a server answers on /health for `nonce`.
    public static func proof(nonce: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data((proofDomain + nonce).utf8), using: key)
        return hex(Array(code))
    }

    /// Whether `proof` is the answer for `nonce` under `secret`, in constant
    /// time. Either case of hex is accepted.
    public static func isValidProof(_ proof: String?, nonce: String, secret: String) -> Bool {
        guard let proof, let code = hexBytes(proof) else { return false }
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data((proofDomain + nonce).utf8), using: key)
    }

    // MARK: - Loopback

    /// A request's Host (authority) is this machine: `127.0.0.1`, `localhost`
    /// or `[::1]`, with or without a port.
    public static func isLoopback(authority: String?) -> Bool {
        guard let authority, !authority.isEmpty else { return false }
        let host: Substring
        if authority.hasPrefix("[") {
            host = authority.split(separator: "]", maxSplits: 1).first.map { $0.dropFirst() } ?? ""
        } else {
            host = authority.split(separator: ":", maxSplits: 1).first ?? ""
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// A host a client may send a secret to: `127.0.0.1`, `localhost`, `::1`
    /// or `[::1]`. Anything else never sees one.
    public static func isLoopback(host: String?) -> Bool {
        guard let host else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: - Hex

    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Bytes of an even-length hex string, either case; nil otherwise.
    public static func hexBytes(_ hex: String) -> [UInt8]? {
        let characters = Array(hex.utf8)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool { nibble(byte) != nil }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
