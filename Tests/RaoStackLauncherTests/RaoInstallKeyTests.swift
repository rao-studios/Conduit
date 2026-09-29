//
//  RaoInstallKeyTests.swift
//  RaoStackLauncherTests
//
//  One key per Mac: made once, adopted by the next app, never made twice by
//  a race or by a Keychain that said no, and an app's own key only when it
//  asks for one. Every store here is in memory but the last test's, which
//  only reads.
//

#if os(macOS)
import CryptoKit
import Foundation
import RaoStack
import Security
import XCTest
@testable import RaoStackLauncher

final class RaoInstallKeyTests: XCTestCase {

    /// A Keychain item in memory, with the answers a test wants from it.
    final class MemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        var blob: Data?
        var readAnswer: RaoInstallKey.Store.Read?
        var addAnswer: RaoInstallKey.Store.Add?
        /// Another app's blob, landing between this app's read and its add.
        var racedBy: Data?
        private(set) var adds = 0
        private(set) var replaces = 0

        var store: RaoInstallKey.Store {
            RaoInstallKey.Store(
                read: { [self] in
                    lock.withLock {
                        if let readAnswer { return readAnswer }
                        return blob.map(RaoInstallKey.Store.Read.found) ?? .notFound
                    }
                },
                add: { [self] data in
                    lock.withLock {
                        adds += 1
                        if let racedBy {
                            blob = racedBy
                            return .duplicate
                        }
                        if let addAnswer { return addAnswer }
                        guard blob == nil else { return .duplicate }
                        blob = data
                        return .added
                    }
                },
                replace: { [self] data in
                    lock.withLock {
                        replaces += 1
                        blob = data
                        return true
                    }
                })
        }
    }

    static func softwareBlob() -> Data {
        Data([RaoInstallKey.softwareTag]) + P256.Signing.PrivateKey().rawRepresentation
    }

    func identity(_ key: RaoInstallKey) async throws -> RaoInstallKey.Identity {
        let found = await key.identity()
        return try XCTUnwrap(found)
    }

    // MARK: - One key per Mac

    func testTheFirstAppMakesTheKeyAndTheNextAdoptsIt() async throws {
        let mac = MemoryStore()
        let ambient = try await identity(RaoInstallKey(app: .ambient, shared: mac.store, preferEnclave: false))
        let craft = try await identity(RaoInstallKey(app: .craft, shared: mac.store, preferEnclave: false))
        XCTAssertEqual(ambient, craft, "two apps, one key")
        XCTAssertEqual(ambient.scope, .mac)
        XCTAssertEqual(ambient.protection, .keychain)
        XCTAssertEqual(ambient.keyID.count, 16)
        XCTAssertEqual(mac.adds, 1)
    }

    func testTheAppThatLosesTheRaceAdoptsTheWinnersKey() async throws {
        let mac = MemoryStore()
        let winner = Self.softwareBlob()
        mac.racedBy = winner
        let identity = try await identity(RaoInstallKey(app: .veil, shared: mac.store, preferEnclave: false))
        let winnerKey = try P256.Signing.PrivateKey(rawRepresentation: winner.dropFirst())
        XCTAssertEqual(identity.publicKey, winnerKey.publicKey.compressedRepresentation)
    }

    func testALockedKeychainMakesNothing() async {
        let mac = MemoryStore()
        mac.readAnswer = .refused(errSecInteractionNotAllowed)
        let key = RaoInstallKey(app: .ambient, fallback: .appKeychain, shared: mac.store, own: MemoryStore().store)
        let identity = await key.identity()
        XCTAssertNil(identity, "a Keychain that said no is not an empty one")
        XCTAssertEqual(mac.adds, 0)
    }

    func testAKeyMadeOnAnotherMacIsReplaced() async throws {
        let mac = MemoryStore()
        mac.blob = Data([RaoInstallKey.enclaveTag]) + Data(repeating: 7, count: 40)
        let identity = try await identity(RaoInstallKey(app: .ambient, shared: mac.store, preferEnclave: false))
        XCTAssertEqual(mac.replaces, 1)
        XCTAssertEqual(mac.blob?.first, RaoInstallKey.softwareTag)
        XCTAssertEqual(identity.scope, .mac)
    }

    // MARK: - Without the access group

    func testWithoutTheEntitlementThereIsNoKeyUnlessTheAppAsks() async throws {
        let mac = MemoryStore()
        mac.readAnswer = .missingEntitlement
        let cli = await RaoInstallKey(app: .craft, shared: mac.store, preferEnclave: false).identity()
        XCTAssertNil(cli, "a tool that does not ask gets nothing")

        let own = MemoryStore()
        let app = try await identity(RaoInstallKey(
            app: .ambient, fallback: .appKeychain, shared: mac.store, own: own.store,
            preferEnclave: false))
        XCTAssertEqual(app.scope, .app)
        XCTAssertEqual(own.adds, 1)
        XCTAssertEqual(mac.adds, 0)
    }

    func testAnAddRefusedForTheEntitlementFallsBackToo() async throws {
        let mac = MemoryStore()
        mac.addAnswer = .missingEntitlement
        let identity = try await identity(RaoInstallKey(
            app: .ambient, fallback: .appKeychain, shared: mac.store, own: MemoryStore().store,
            preferEnclave: false))
        XCTAssertEqual(identity.scope, .app)
    }

    // MARK: - Signing

    func testSignaturesCheckAgainstThePublicKey() async throws {
        let key = RaoInstallKey(app: .ambient, shared: MemoryStore().store, preferEnclave: SecureEnclave.isAvailable)
        let identity = try await identity(key)
        XCTAssertEqual(identity.protection, SecureEnclave.isAvailable ? .secureEnclave : .keychain)
        let message = Data("rao-verified-record/1\n{}".utf8)
        let signature = try await key.signature(for: message)
        XCTAssertEqual(signature.count, 64)
        let publicKey = try P256.Signing.PublicKey(compressedRepresentation: identity.publicKey)
        XCTAssertTrue(publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
        XCTAssertEqual(identity.keyID, RaoInstallKey.keyID(for: identity.publicKey))
    }

    func testNoKeyMeansNoSignature() async {
        let mac = MemoryStore()
        mac.readAnswer = .missingEntitlement
        let key = RaoInstallKey(app: .craft, shared: mac.store)
        do {
            _ = try await key.signature(for: Data())
            XCTFail("signed without a key")
        } catch {
            XCTAssertEqual(error as? RaoInstallKey.Problem, .noKey)
        }
    }

    // MARK: - The real Keychain, read only

    /// This test process carries no access group, so the Mac's item must be
    /// out of its reach — the gate the entitlement is.
    func testTheRealSharedItemIsClosedToAProcessWithoutTheEntitlement() {
        XCTAssertEqual(RaoInstallKey.Store.sharedKeychain.read(), .missingEntitlement)
    }
}
#endif
