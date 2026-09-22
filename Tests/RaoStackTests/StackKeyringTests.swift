//
//  StackKeyringTests.swift
//  RaoStackTests
//

import Foundation
import XCTest
@testable import RaoStack

final class StackKeyringTests: XCTestCase {

    func testItResolvesEachAppBySecret() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        let ring = StackKeyring(home: test.home)
        for app in RaoApp.allCases {
            XCTAssertEqual(ring.app(forPresented: secrets[app]), app)
            XCTAssertEqual(ring.secret(for: app), secrets[app])
        }
        XCTAssertNil(ring.app(forPresented: nil))
        XCTAssertNil(ring.app(forPresented: ""))
        XCTAssertNil(ring.app(forPresented: StackSecret.generate()))
    }

    func testASecretPublishedLaterIsPickedUpOnAMiss() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        XCTAssertEqual(ring.provisionedApps, [.ambient])

        let craft = try test.home.ensureSecret(for: .craft)
        XCTAssertNil(ring.app(forPresented: craft), "within the throttle: no reload")
        clock.advance(3)
        XCTAssertEqual(ring.app(forPresented: craft), .craft)
    }

    func testAMalformedGuessNeverTriggersAReload() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        let craft = try test.home.ensureSecret(for: .craft)
        clock.advance(3)
        XCTAssertNil(ring.app(forPresented: "not-hex"))
        XCTAssertEqual(ring.provisionedApps, [.ambient], "a malformed value earned no read")
        XCTAssertEqual(ring.app(forPresented: craft), .craft)
    }

    func testAnOldRingReloadsSoARevokedSecretStopsWorking() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, maximumAge: 60, now: { clock.now })
        try FileManager.default.removeItem(at: test.home.secretFile(for: .veil))
        XCTAssertEqual(ring.app(forPresented: secrets[.veil]), .veil)
        clock.advance(61)
        XCTAssertNil(ring.app(forPresented: secrets[.veil]))
    }

    func testAnOpenFileIsSkippedAndSharedValuesDropBothApps() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        chmod(PrivateFile.path(test.home.secretFile(for: .veil)), 0o644)
        try PrivateFile.writeAtomically(Data(secrets[.ambient]!.utf8), to: test.home.secretFile(for: .craft))
        let ring = StackKeyring(home: test.home)
        XCTAssertTrue(ring.provisionedApps.isEmpty)
        XCTAssertEqual(ring.lastIssues.count, 2)
        XCTAssertNil(ring.app(forPresented: secrets[.ambient]))
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
