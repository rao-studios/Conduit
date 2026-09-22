//
//  StackSecretTests.swift
//  RaoStackTests
//
//  The proof every app and both servers agree on, pinned by the known
//  answers Sewn's, Thread's and Ambient's tests have always used.
//

import Conduit
import Foundation
import XCTest
@testable import RaoStack

final class StackSecretTests: XCTestCase {

    /// `printf '%s' 'ambient-stack-health-v1:<nonce>' | openssl dgst -sha256 -hmac '<secret>'`
    enum KAT {
        static let nonce = "000102030405060708090a0b0c0d0e0f"
        static let proofForS3cret = "eb9c34a43319f28ce0a8af801edaf4e6f7d588ed4c16d8edf05e4ed6db53272c"
        static let proofForOther = "320c7f0d1afe5b81c3875afe27948389026503d31477a92543a13e7ef1843ba2"
    }

    func testTheProofMatchesTheKnownAnswers() {
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "s3cret"), KAT.proofForS3cret)
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "other"), KAT.proofForOther)
    }

    func testAProofIsCheckedInEitherCaseAndOnlyForItsSecret() {
        XCTAssertTrue(StackSecret.isValidProof(KAT.proofForS3cret, nonce: KAT.nonce, secret: "s3cret"))
        XCTAssertTrue(StackSecret.isValidProof(KAT.proofForS3cret.uppercased(), nonce: KAT.nonce, secret: "s3cret"))
        XCTAssertFalse(StackSecret.isValidProof(KAT.proofForS3cret, nonce: KAT.nonce, secret: "other"))
        XCTAssertFalse(StackSecret.isValidProof(nil, nonce: KAT.nonce, secret: "s3cret"))
        XCTAssertFalse(StackSecret.isValidProof("zz", nonce: KAT.nonce, secret: "s3cret"))
    }

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecret.matches("s3cret", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cres", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cret-and-more", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches(nil, secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("anything", secret: nil))
    }

    func testGeneratedSecretsAndNoncesAreWellFormedAndDistinct() {
        let secrets = (0..<20).map { _ in StackSecret.generate() }
        XCTAssertEqual(Set(secrets).count, 20)
        XCTAssertTrue(secrets.allSatisfy(StackSecret.isWellFormedSecret))
        let nonce = StackSecret.nonce()
        XCTAssertEqual(nonce.count, 32)
        XCTAssertTrue(StackSecret.isWellFormedNonce(nonce))
    }

    func testShapes() {
        XCTAssertFalse(StackSecret.isWellFormedSecret(String(repeating: "a", count: 63)))
        XCTAssertFalse(StackSecret.isWellFormedSecret(String(repeating: "g", count: 64)))
        XCTAssertTrue(StackSecret.isWellFormedSecret(String(repeating: "A", count: 64)))
        XCTAssertFalse(StackSecret.isWellFormedNonce("abc"))
        XCTAssertFalse(StackSecret.isWellFormedNonce(String(repeating: "ab", count: 65)))
        XCTAssertTrue(StackSecret.isWellFormedNonce(KAT.nonce.uppercased()))
    }

    func testLoopback() {
        for authority in ["127.0.0.1", "127.0.0.1:47080", "localhost:1", "[::1]:47080", "LOCALHOST"] {
            XCTAssertTrue(StackSecret.isLoopback(authority: authority), authority)
        }
        for authority in [nil, "", "evil.example", "127.0.0.1.evil.example", "10.0.0.2:47080", "[::2]:1"] {
            XCTAssertFalse(StackSecret.isLoopback(authority: authority), authority ?? "nil")
        }
        XCTAssertTrue(StackSecret.isLoopback(host: "[::1]"))
        XCTAssertFalse(StackSecret.isLoopback(host: "example.com"))
    }

    func testTheGRPCKeyIsConduits() {
        XCTAssertEqual(StackSecret.metadataKey, StackSecretMetadata.key)
    }
}
