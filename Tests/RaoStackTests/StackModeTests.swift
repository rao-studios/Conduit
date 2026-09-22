//
//  StackModeTests.swift
//  RaoStackTests
//
//  Which mode a server is in, from its environment, and what each mode
//  admits and answers on /health.
//

import Foundation
import XCTest
@testable import RaoStack

final class StackModeTests: XCTestCase {
    typealias KAT = StackSecretTests.KAT

    // MARK: - Sewn's environment

    func testSewnWithNothingIsOpen() throws {
        guard case .open = try StackMode.sewn(environment: [:]) else { return XCTFail("expected open") }
    }

    func testSewnWithOneSecretIsSingle() throws {
        let mode = try StackMode.sewn(environment: ["AMBIENT_STACK_SECRET": "s3cret"])
        XCTAssertEqual(mode.singleSecret, "s3cret")
        XCTAssertNil(mode.grpcResolver)
    }

    func testSewnWithAHomeIsMultiAppAndIgnoresTheSingleSecret() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let environment = ["RAO_HOME": PrivateFile.path(test.home.root), "AMBIENT_STACK_SECRET": "s3cret"]
        let mode = try StackMode.sewn(environment: environment)
        XCTAssertNotNil(mode.keyring)
        XCTAssertNil(mode.singleSecret)
        XCTAssertTrue(StackMode.ignoresSingleSecret(sewnEnvironment: environment))
        XCTAssertEqual(mode.keyring?.provisionedApps, RaoApp.allCases)
    }

    func testSewnRefusesAHomeThatIsMissingOrOpen() throws {
        let test = TestHome()
        XCTAssertThrowsError(try StackMode.sewn(environment: ["RAO_HOME": PrivateFile.path(test.home.root)]))
        try test.home.provision(by: .ambient)
        chmod(PrivateFile.path(test.home.root), 0o755)
        XCTAssertThrowsError(try StackMode.sewn(environment: ["RAO_HOME": PrivateFile.path(test.home.root)]))
        XCTAssertThrowsError(try StackMode.sewn(environment: ["RAO_HOME": "relative"]))
    }

    // MARK: - Thread's environment

    func testThreadTakesItsLaunchersSecretAndApp() throws {
        let mode = try StackMode.thread(environment: ["AMBIENT_STACK_SECRET": "s3cret", "RAO_APP": "craft"])
        XCTAssertEqual(mode.singleSecret, "s3cret")
        XCTAssertEqual(mode.app, .craft)
    }

    func testThreadReadsItsSecretFromTheHomeWhenNotHandedOne() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .veil)
        let mode = try StackMode.thread(environment: ["RAO_HOME": PrivateFile.path(test.home.root), "RAO_APP": "veil"])
        XCTAssertEqual(mode.singleSecret, secrets[.veil])
    }

    func testAThreadToldToUseAHomeNeverComesUpOpen() throws {
        let test = TestHome()
        let root = PrivateFile.path(test.home.root)
        XCTAssertThrowsError(try StackMode.thread(environment: ["RAO_HOME": root])) { error in
            XCTAssertEqual(error as? RaoHomeError, .unknownApp(nil))
        }
        XCTAssertThrowsError(try StackMode.thread(environment: ["RAO_HOME": root, "RAO_APP": "craft"])) { error in
            XCTAssertEqual(error as? RaoHomeError, .missingSecret(.craft))
        }
        guard case .open = try StackMode.thread(environment: [:]) else { return XCTFail("no home, no secret: open") }
    }

    // MARK: - Admission

    func testOpenAdmitsEveryone() {
        XCTAssertEqual(StackMode.open.admit(authority: "evil.example", presented: nil), .admitted(nil))
    }

    func testSingleChecksHostBeforeSecret() {
        let mode = StackMode.single(secret: "s3cret", app: .ambient)
        XCTAssertEqual(mode.admit(authority: "evil.example", presented: "s3cret"), .notLoopback)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: "wrong"), .badSecret)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: nil), .badSecret)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: "s3cret"), .admitted(.ambient))
    }

    func testMultiAppKnowsTheCallerBySecret() {
        let mode = StackMode.multiApp(StackKeyring(fixed: [.ambient: "s3cret", .craft: "other"]))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "s3cret"), .admitted(.ambient))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "other"), .admitted(.craft))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "nobody's"), .badSecret)
        XCTAssertEqual(mode.admit(authority: "evil.example", presented: "s3cret"), .notLoopback)
        XCTAssertEqual(mode.grpcResolver?("other"), "craft")
        XCTAssertNil(mode.grpcResolver?("nobody's"))
    }

    // MARK: - /health

    func testOpenHealthIsUnchanged() throws {
        let answer = StackMode.open.healthAnswer(nonce: KAT.nonce, requestedApp: "ambient")
        XCTAssertEqual(answer, StackHealthAnswer(stack: "open", proof: nil, app: nil, contract: nil))
        let json = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        XCTAssertEqual(json, #"{"stack":"open"}"#, "nil fields are left out, not null")
    }

    func testSingleHealthProvesItsSecret() {
        let mode = StackMode.single(secret: "s3cret", app: .craft)
        let answer = mode.healthAnswer(nonce: KAT.nonce, requestedApp: "veil")
        XCTAssertEqual(answer.proof, KAT.proofForS3cret, "X-Rao-App is ignored by a one-secret server")
        XCTAssertEqual(answer.app, .craft)
        XCTAssertEqual(answer.contract, RaoContract.version)
        XCTAssertNil(mode.healthAnswer(nonce: "zz", requestedApp: nil).proof)
    }

    func testMultiAppHealthProvesTheRequestedAppsSecret() {
        let mode = StackMode.multiApp(StackKeyring(fixed: [.ambient: "s3cret", .craft: "other"]))
        let craft = mode.healthAnswer(nonce: KAT.nonce, requestedApp: "craft")
        XCTAssertEqual(craft.proof, KAT.proofForOther)
        XCTAssertEqual(craft.app, .craft)
        let ambient = mode.healthAnswer(nonce: KAT.nonce, requestedApp: " Ambient ")
        XCTAssertEqual(ambient.proof, KAT.proofForS3cret)

        for requested in [nil, "", "bogus", "veil"] {
            let answer = mode.healthAnswer(nonce: KAT.nonce, requestedApp: requested)
            XCTAssertEqual(answer.stack, "proof")
            XCTAssertNil(answer.proof, requested ?? "nil")
            XCTAssertNil(answer.app)
        }
        XCTAssertNil(mode.healthAnswer(nonce: nil, requestedApp: "craft").proof)
    }

    func testTheSummaryNeverShowsASecret() {
        let secret = StackSecret.generate()
        XCTAssertFalse(StackMode.single(secret: secret, app: nil).summary.contains(secret))
        XCTAssertFalse(StackMode.multiApp(StackKeyring(fixed: [.ambient: secret])).summary.contains(secret))
    }
}
