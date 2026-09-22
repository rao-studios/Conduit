//
//  RaoHomeTests.swift
//  RaoStackTests
//

import Foundation
import XCTest
@testable import RaoStack

final class RaoHomeTests: XCTestCase {

    func testTheLayoutIsTheContract() {
        let home = RaoHome(root: URL(fileURLWithPath: "/tmp/r"))
        XCTAssertEqual(PrivateFile.path(home.secretFile(for: .craft)), "/tmp/r/secrets/craft")
        XCTAssertEqual(PrivateFile.path(home.providersFile), "/tmp/r/keys/providers.json")
        XCTAssertEqual(PrivateFile.path(home.sewnBinary), "/tmp/r/sewn/bin/sewn-server")
        XCTAssertEqual(PrivateFile.path(home.sewnMetallib), "/tmp/r/sewn/bin/mlx.metallib")
        XCTAssertEqual(PrivateFile.path(home.sewnInstallRecord), "/tmp/r/sewn/install.json")
        XCTAssertEqual(PrivateFile.path(home.sewnEnvFile), "/tmp/r/sewn/sewn.env")
        XCTAssertEqual(PrivateFile.path(home.sewnConfigFile), "/tmp/r/sewn/config.json")
        XCTAssertEqual(PrivateFile.path(home.sewnDataDirectory), "/tmp/r/sewn/db")
        XCTAssertEqual(PrivateFile.path(home.sewnRunRecord), "/tmp/r/sewn/run/sewn.json")
        XCTAssertEqual(PrivateFile.path(home.sewnLease(for: .veil)), "/tmp/r/sewn/leases/veil.json")
        XCTAssertEqual(PrivateFile.path(home.threadDataDirectory(for: .ambient)), "/tmp/r/apps/ambient/thread-db")
        XCTAssertEqual(PrivateFile.path(home.threadRunRecord(for: .ambient)), "/tmp/r/apps/ambient/run/thread.json")
        XCTAssertEqual(PrivateFile.path(home.huggingFaceHome), "/tmp/r/models/huggingface")
    }

    func testServersOnlyUseAHomeTheirLauncherNamed() throws {
        XCTAssertNil(try RaoHome.fromEnvironment([:]))
        XCTAssertNil(try RaoHome.fromEnvironment(["RAO_HOME": "  "]))
        XCTAssertEqual(try RaoHome.fromEnvironment(["RAO_HOME": "/x/y"]).map { PrivateFile.path($0.root) }, "/x/y")
        XCTAssertThrowsError(try RaoHome.fromEnvironment(["RAO_HOME": "relative/path"]))
        let tilde = try RaoHome.fromEnvironment(["RAO_HOME": "~/.rao-test"])
        XCTAssertTrue(PrivateFile.path(tilde!.root).hasPrefix(PrivateFile.path(RaoHome.userHomeDirectory)))
    }

    func testAppsAlwaysGetAHome() {
        XCTAssertEqual(PrivateFile.path(RaoHome.resolved([:]).root),
                       PrivateFile.path(RaoHome.userHomeDirectory.appendingPathComponent(".rao")))
        XCTAssertEqual(PrivateFile.path(RaoHome.resolved(["RAO_HOME": "/elsewhere"]).root), "/elsewhere")
        XCTAssertEqual(PrivateFile.path(RaoHome.resolved(["RAO_HOME": "not/absolute"]).root),
                       PrivateFile.path(RaoHome.userHomeDirectory.appendingPathComponent(".rao")))
    }

    func testProvisioningIsPrivateAndGivesEveryAppItsOwnSecret() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        XCTAssertEqual(Set(secrets.keys), Set(RaoApp.allCases))
        XCTAssertEqual(Set(secrets.values).count, RaoApp.allCases.count)
        XCTAssertTrue(secrets.values.allSatisfy(StackSecret.isWellFormedSecret))
        XCTAssertEqual(test.mode(test.home.root), 0o700)
        XCTAssertEqual(test.mode(test.home.secretsDirectory), 0o700)
        for app in RaoApp.allCases {
            XCTAssertEqual(test.mode(test.home.secretFile(for: app)), 0o600, app.rawValue)
        }
        XCTAssertEqual(test.home.layout()?.createdBy, .ambient)
    }

    func testProvisioningAgainKeepsEverySecret() throws {
        let test = TestHome()
        let first = try test.home.provision(by: .ambient)
        let second = try test.home.provision(by: .craft)
        XCTAssertEqual(first, second)
        XCTAssertEqual(test.home.layout()?.createdBy, .ambient, "the first app to arrive is recorded")
    }

    func testConcurrentProvisionersAgreeOnOneSecretPerApp() throws {
        let test = TestHome()
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            let app = RaoApp.allCases[index % RaoApp.allCases.count]
            if let secrets = try? test.home.provision(by: app) { results.append(secrets) }
        }
        XCTAssertEqual(results.all.count, 12)
        XCTAssertEqual(Set(results.all).count, 1, "every provisioner read the same secrets back")
    }

    func testALooseDirectoryIsTightenedAndALooseSecretRefused() throws {
        let test = TestHome()
        try FileManager.default.createDirectory(at: test.home.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try test.home.provision(by: .veil)
        XCTAssertEqual(test.mode(test.home.root), 0o700)

        chmod(PrivateFile.path(test.home.secretFile(for: .veil)), 0o644)
        XCTAssertThrowsError(try test.home.readSecret(for: .veil))
    }

    func testAMalformedSecretIsRefused() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.writeAtomically(Data("short".utf8), to: test.home.secretFile(for: .craft))
        XCTAssertThrowsError(try test.home.readSecret(for: .craft)) { error in
            XCTAssertEqual(error as? RaoHomeError, .malformedSecret(.craft))
        }
    }

    func testEnsureSecretTouchesOnlyItsApp() throws {
        let test = TestHome()
        let veil = try test.home.ensureSecret(for: .veil)
        XCTAssertEqual(try test.home.readSecret(for: .veil), veil)
        XCTAssertNil(try test.home.readSecret(for: .ambient))
    }
}

final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[RaoApp: String]] = []
    func append(_ value: [RaoApp: String]) { lock.withLock { values.append(value) } }
    var all: [[RaoApp: String]] { lock.withLock { values } }
}
