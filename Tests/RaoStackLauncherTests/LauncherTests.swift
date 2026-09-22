//
//  LauncherTests.swift
//  RaoStackLauncherTests
//
//  Leases, the installer's rules, and a real adopt-or-spawn against a small
//  stand-in server that proves a secret on /health the way Sewn and Thread do.
//

import Darwin
import Foundation
import RaoStack
import XCTest
@testable import RaoStackLauncher

final class LauncherTestHome {
    let home: RaoHome
    private let base: URL

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rao-launcher-\(UUID().uuidString)", isDirectory: true)
        home = RaoHome(root: base.appendingPathComponent("home", isDirectory: true))
        try? home.provision(by: .ambient)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func file(_ name: String, contents: String, mode: mode_t = 0o755) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        chmod(PrivateFile.path(url), mode)
        return url
    }
}

final class ProcessProbeTests: XCTestCase {
    func testThisProcessIsItself() {
        let me = ProcessProbe.current
        XCTAssertEqual(me.pid, getpid())
        XCTAssertNotNil(me.processStart)
        XCTAssertTrue(ProcessProbe.isRunning(me))
        XCTAssertFalse(ProcessProbe.isRunning(ProcessStamp(pid: getpid(), processStart: (me.processStart ?? 0) + 1)),
                       "a pid with another start time is another process")
        XCTAssertNotNil(ProcessProbe.executablePath(of: getpid()))
        XCTAssertEqual(ProcessProbe.parsePIDs("12\n 34 \nx\n"), [12, 34])
    }
}

final class SewnLeasesTests: XCTestCase {
    func testLiveDeadAndPinnedLeases() throws {
        let test = LauncherTestHome()
        let leases = SewnLeases(home: test.home)
        try leases.acquire(for: .ambient)
        XCTAssertEqual(leases.liveHolders(), [.ambient])
        XCTAssertFalse(leases.othersAlive(excluding: .ambient))

        // Craft crashed: its lease names a process that is gone.
        try leases.acquire(for: .craft, process: ProcessStamp(pid: 999_999, processStart: 1))
        XCTAssertEqual(leases.liveHolders(), [.ambient])
        XCTAssertFalse(PrivateFile.exists(test.home.sewnLease(for: .craft)), "swept")

        // A dev script's pinned lease counts, whatever process wrote it.
        try leases.acquire(for: .veil, pinned: true, process: ProcessStamp(pid: 999_999, processStart: 1))
        XCTAssertTrue(leases.othersAlive(excluding: .ambient))
        XCTAssertEqual(leases.others(excluding: .ambient), [.veil])

        leases.release(for: .veil, pinned: true)
        leases.release(for: .ambient)
        XCTAssertTrue(leases.liveHolders().isEmpty)
    }

    func testAnotherLiveProcessesLeaseIsNotDroppedByThisOne() throws {
        let test = LauncherTestHome()
        let leases = SewnLeases(home: test.home)
        let parent = ProcessStamp(pid: getppid(), processStart: ProcessProbe.startTime(of: getppid()))
        try leases.acquire(for: .craft, process: parent)
        leases.release(for: .craft)
        XCTAssertEqual(leases.liveHolders(), [.craft])
    }
}

final class SewnInstallerTests: XCTestCase {
    func testTheRules() {
        let current = SewnInstallRecord(contract: 1, sha256: "aa", installedBy: .ambient, appVersion: "1", installedAt: Date())
        XCTAssertEqual(SewnInstaller.decision(bundled: 1, bundledSHA: "aa", by: .craft, existing: nil), .install)
        XCTAssertEqual(SewnInstaller.decision(bundled: 1, bundledSHA: "aa", by: .craft, existing: current), .current)
        XCTAssertEqual(SewnInstaller.decision(bundled: 2, bundledSHA: "bb", by: .craft, existing: current), .install, "newer contract")
        XCTAssertEqual(SewnInstaller.decision(bundled: 1, bundledSHA: "bb", by: .ambient, existing: current), .install, "own update")
        XCTAssertEqual(SewnInstaller.decision(bundled: 1, bundledSHA: "bb", by: .craft, existing: current), .keep, "another app's equal")
        XCTAssertEqual(SewnInstaller.decision(bundled: 0, bundledSHA: "bb", by: .ambient, existing: current), .keep, "never downgrade")
    }

    func testInstallVerifyAndTamper() throws {
        let test = LauncherTestHome()
        let binary = try test.file("sewn-server", contents: "#!/bin/sh\necho v1\n")
        let metallib = try test.file("real.metallib", contents: "metal", mode: 0o644)
        let link = binary.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: metallib)
        let installer = SewnInstaller(home: test.home, policy: .unchecked)
        let payload = SewnPayload(binary: binary, metallib: link, appVersion: "1.0.0 (1)",
                                  publicEnvironment: ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"])

        guard case .installed(let record, nil) = try installer.installIfNeeded(payload, by: .ambient) else {
            return XCTFail("expected a first install")
        }
        XCTAssertEqual(record.sha256, try FileDigest.sha256(of: binary))
        XCTAssertEqual(try String(contentsOf: test.home.sewnMetallib, encoding: .utf8), "metal", "the link was resolved")
        XCTAssertEqual(PrivateFile.ownerAndMode(test.home.sewnBinary)?.mode, 0o755)
        XCTAssertEqual(EnvFile.read(test.home.sewnEnvFile)["SUPABASE_URL"], "u")
        XCTAssertNoThrow(try installer.verifyInstalled())

        guard case .alreadyCurrent = try installer.installIfNeeded(payload, by: .ambient) else { return XCTFail("current") }

        let v2 = try test.file("sewn-server-2", contents: "#!/bin/sh\necho v2\n")
        var craftPayload = payload
        craftPayload.binary = v2
        guard case .keptExisting = try installer.installIfNeeded(craftPayload, by: .craft) else {
            return XCTFail("craft's equal-contract build doesn't replace ambient's")
        }
        guard case .installed(_, let replaced) = try installer.installIfNeeded(craftPayload, by: .ambient) else {
            return XCTFail("ambient's own update does")
        }
        XCTAssertEqual(replaced?.sha256, record.sha256)

        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: test.home.sewnBinary)
        XCTAssertThrowsError(try installer.verifyInstalled())
    }
}

/// A stand-in for Sewn or Thread: answers /health with the v1 proof for a
/// secret it reads from the environment, the way the real servers do.
private let standInServer = """
#!/usr/bin/env python3
import hashlib, hmac, http.server, json, os, sys
port = int(sys.argv[1]); secret = os.environ.get("AMBIENT_STACK_SECRET", "")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        nonce = self.headers.get("X-Ambient-Nonce") or ""
        body = {"stack": "proof", "contract": 1}
        if nonce:
            body["proof"] = hmac.new(secret.encode(), ("ambient-stack-health-v1:" + nonce).encode(), hashlib.sha256).hexdigest()
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"""

final class ManagedServerTests: XCTestCase {

    private func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func spec(_ test: LauncherTestHome, script: URL, secret: String, port: Int) -> LaunchSpec {
        LaunchSpec(role: .thread, executable: script, arguments: [String(port)],
                   environment: ["PATH": "/usr/bin:/bin", "AMBIENT_STACK_SECRET": secret],
                   workingDirectory: test.home.appDirectory(.craft), ports: RaoPorts(http: port, grpc: port),
                   runRecord: test.home.threadRunRecord(for: .craft), logFile: test.home.threadLogFile(for: .craft),
                   challengeApp: .craft)
    }

    func testSpawnAdoptAndStop() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-thread", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freePort()
        let spec = spec(test, script: script, secret: secret, port: port)

        let first = ManagedServer(spec: spec, secret: secret, launcherApp: .craft)
        let started = try await first.ensureRunning(timeout: 20)
        XCTAssertFalse(started.adopted)
        XCTAssertTrue(ProcessProbe.isAlive(started.pid))
        let record = try XCTUnwrap(RunRecord.load(spec.runRecord))
        XCTAssertEqual(record.process.pid, started.pid)
        XCTAssertEqual(record.launcher?.app, .craft)
        XCTAssertEqual(record.launcher?.process, ProcessProbe.current)

        // Another supervisor in this same process adopts it rather than
        // starting a second one.
        let second = ManagedServer(spec: spec, secret: secret, launcherApp: .craft)
        let adopted = try await second.ensureRunning(timeout: 20)
        XCTAssertTrue(adopted.adopted)
        XCTAssertEqual(adopted.pid, started.pid)

        // The wrong secret is never ours: the port is in use.
        let impostor = ManagedServer(spec: spec, secret: StackSecret.generate(), launcherApp: .craft)
        RunRecord.remove(spec.runRecord)
        do {
            _ = try await impostor.ensureRunning(timeout: 5)
            XCTFail("expected portInUse")
        } catch let error as ManagedServerError {
            guard case .portInUse = error else { return XCTFail("\(error)") }
        }

        await first.stop()
        let gone = await waitUntil { !ProcessProbe.isAlive(started.pid) }
        XCTAssertTrue(gone)
        XCTAssertNil(RunRecord.load(spec.runRecord))
    }

    func testAServerThatExitsReportsItsLog() async throws {
        let test = LauncherTestHome()
        let script = try test.file("dies", contents: "#!/bin/sh\necho 'bad flag' >&2\nexit 3\n")
        let secret = try test.home.ensureSecret(for: .craft)
        let server = ManagedServer(spec: spec(test, script: script, secret: secret, port: freePort()),
                                   secret: secret, launcherApp: .craft)
        do {
            _ = try await server.ensureRunning(timeout: 10)
            XCTFail("expected exited")
        } catch let error as ManagedServerError {
            guard case .exited(let tail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(tail.contains("bad flag"))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
