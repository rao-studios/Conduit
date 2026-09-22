//
//  LaunchSpecTests.swift
//  RaoStackTests
//

import Foundation
import XCTest
@testable import RaoStack

final class LaunchSpecTests: XCTestCase {
    let home = RaoHome(root: URL(fileURLWithPath: "/tmp/rao"))
    let shell: [String: String] = [
        "PATH": "/usr/bin", "HOME": "/Users/x", "LANG": "en_US.UTF-8", "HF_ENDPOINT": "https://hf",
        "MISTRAL_API_KEY": "leaked?", "OPENAI_API_KEY": "leaked?", "AMBIENT_STACK_SECRET": "leaked?",
        "RAO_HOME": "/elsewhere", "RAO_APP": "veil", "THREAD_NODE_ID": "stale", "AWS_SECRET": "no",
        "THREAD_PQ_MLX": "1",
    ]

    func testSewnRunsFromTheHomeOnTheSharedPorts() {
        let spec = LaunchSpecs.sewn(home: home, config: SewnConfig(), challengeApp: .ambient, inherited: shell)
        XCTAssertEqual(spec.role, .sewn)
        XCTAssertEqual(PrivateFile.path(spec.executable), "/tmp/rao/sewn/bin/sewn-server")
        XCTAssertEqual(spec.arguments, ["--host", "127.0.0.1", "--port", "47080", "--grpc-port", "47091",
                                        "--data-dir", "/tmp/rao/sewn/db"])
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/tmp/rao/sewn")
        XCTAssertEqual(spec.environment["RAO_HOME"], "/tmp/rao")
        XCTAssertEqual(spec.environment["HF_HOME"], "/tmp/rao/models/huggingface")
        XCTAssertNil(spec.environment["AMBIENT_STACK_SECRET"], "a shared Sewn reads every secret from the home")
        XCTAssertNil(spec.environment["MISTRAL_API_KEY"])
        XCTAssertNil(spec.environment["OPENAI_API_KEY"])
        XCTAssertNil(spec.environment["AWS_SECRET"])
        XCTAssertEqual(spec.environment["HF_ENDPOINT"], "https://hf")
        XCTAssertEqual(spec.challengeApp, .ambient)
        XCTAssertEqual(PrivateFile.path(spec.startLock), "/tmp/rao/sewn/run/start.lock")
    }

    func testSewnHonoursItsConfig() {
        let config = SewnConfig(httpPort: 1, grpcPort: 2, dataDir: "/data/sewn", hfHome: "/models")
        let spec = LaunchSpecs.sewn(home: home, config: config, executable: URL(fileURLWithPath: "/checkout/sewn-server"),
                                    workingDirectory: URL(fileURLWithPath: "/checkout"), challengeApp: .craft, inherited: [:])
        XCTAssertEqual(spec.arguments, ["--host", "127.0.0.1", "--port", "1", "--grpc-port", "2", "--data-dir", "/data/sewn"])
        XCTAssertEqual(spec.environment["HF_HOME"], "/models")
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/checkout")
    }

    func testAThreadGetsItsAppsSecretPortsAndDataButNothingSecretInArgv() {
        let node = UUID()
        let spec = LaunchSpecs.thread(
            for: .craft, home: home, executable: URL(fileURLWithPath: "/bin/thread"), secret: "craft-secret",
            sewnPorts: RaoPortPlan.sewn,
            options: ThreadLaunchOptions(useMLX: true, graphBackend: "keyword", nodeID: node), inherited: shell)
        XCTAssertEqual(spec.arguments, [
            "--host", "127.0.0.1", "--port", "48081", "--grpc-port", "48090",
            "--mothership-host", "127.0.0.1", "--mothership-grpc-port", "47091",
            "--data-dir", "/tmp/rao/apps/craft/thread-db", "--graph-backend", "keyword", "--use-mlx",
        ])
        XCTAssertEqual(spec.environment["AMBIENT_STACK_SECRET"], "craft-secret")
        XCTAssertEqual(spec.environment["RAO_APP"], "craft")
        XCTAssertEqual(spec.environment["RAO_HOME"], "/tmp/rao")
        XCTAssertEqual(spec.environment["THREAD_NODE_ID"], node.uuidString)
        XCTAssertEqual(spec.environment["THREAD_PQ_MLX"], "1")
        XCTAssertNil(spec.environment["MISTRAL_API_KEY"])
        XCTAssertFalse(spec.arguments.contains { $0.contains("craft-secret") || $0.contains(node.uuidString) })
        XCTAssertEqual(PrivateFile.path(spec.runRecord), "/tmp/rao/apps/craft/run/thread.json")
        XCTAssertEqual(spec.challengeApp, .craft)
    }

    func testAStandaloneThreadWithCustomPlacesAndItsOwnModels() {
        let spec = LaunchSpecs.thread(
            for: .ambient, home: home, executable: URL(fileURLWithPath: "/bin/thread"), secret: "s",
            sewnPorts: RaoPortPlan.sewn,
            options: ThreadLaunchOptions(dataDirectory: URL(fileURLWithPath: "/Users/x/Documents/maryOS/thread-db"),
                                         ports: RaoPorts(http: 8081, grpc: 9090), mothership: false,
                                         huggingFaceHome: .inherit),
            inherited: ["HF_HOME": "/Users/x/Documents/huggingface"])
        XCTAssertFalse(spec.arguments.contains("--mothership-host"))
        XCTAssertTrue(spec.arguments.contains("/Users/x/Documents/maryOS/thread-db"))
        XCTAssertEqual(spec.ports, RaoPorts(http: 8081, grpc: 9090))
        XCTAssertEqual(spec.environment["HF_HOME"], "/Users/x/Documents/huggingface")
    }
}

final class RaoPortPlanTests: XCTestCase {
    func testEveryPortIsDistinctAndClearOfTheOtherStacks() {
        var ports = [RaoPortPlan.sewn.http, RaoPortPlan.sewn.grpc]
        for app in RaoApp.allCases { ports += [RaoPortPlan.thread(app).http, RaoPortPlan.thread(app).grpc] }
        XCTAssertEqual(Set(ports).count, ports.count)
        XCTAssertTrue(Set(ports).isDisjoint(with: RaoPortPlan.reservedElsewhere))
        XCTAssertEqual(RaoPortPlan.thread(.ambient), RaoPorts(http: 47081, grpc: 47090), "Ambient's ports never moved")
    }

    func testAppNames() {
        XCTAssertEqual(RaoApp(header: " Craft\n"), .craft)
        XCTAssertNil(RaoApp(header: "mary"))
        XCTAssertNil(RaoApp(header: nil))
    }
}

final class EnvFileTests: XCTestCase {
    func testParsing() {
        let pairs = EnvFile.parse("""
        # comment
        SUPABASE_URL=https://x.supabase.co
        export SUPABASE_ANON_KEY="anon"
          QUOTED='single'
        NOEQUALS
        =novalue
        EMPTY=
        """)
        XCTAssertEqual(pairs.map(\.key), ["SUPABASE_URL", "SUPABASE_ANON_KEY", "QUOTED", "EMPTY"])
        XCTAssertEqual(pairs.map(\.value), ["https://x.supabase.co", "anon", "single", ""])
    }

    func testSewnsFileTakesOnlyPublicValues() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        XCTAssertThrowsError(try SewnEnvironmentFile.write(["MISTRAL_API_KEY": "k"], to: test.home.sewnEnvFile))
        try SewnEnvironmentFile.write(["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"], to: test.home.sewnEnvFile)
        XCTAssertEqual(EnvFile.read(test.home.sewnEnvFile), ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"])
        XCTAssertEqual(test.mode(test.home.sewnEnvFile), 0o600)
    }

    func testApplyingNeverOverridesTheEnvironmentOrADeniedKey() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let file = test.home.sewnDirectory.appendingPathComponent("probe.env")
        let unique = "RAO_TEST_\(UUID().uuidString.prefix(8))"
        setenv("\(unique)_SET", "shell", 1)
        try PrivateFile.writeAtomically(Data("\(unique)_NEW=file\n\(unique)_SET=file\nMISTRAL_API_KEY=file\n".utf8), to: file)
        let applied = EnvFile.apply(file, denying: SewnEnvironmentFile.deniedKeys)
        XCTAssertFalse(applied.contains("MISTRAL_API_KEY"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["\(unique)_NEW"], "file")
        XCTAssertEqual(ProcessInfo.processInfo.environment["\(unique)_SET"], "shell")
        unsetenv("\(unique)_NEW")
        unsetenv("\(unique)_SET")
    }
}

final class StackChallengeTests: XCTestCase {
    typealias KAT = StackSecretTests.KAT

    private func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testVerdicts() {
        func verdict(_ data: Data?, status: Int? = 200, secret: String = "s3cret", app: RaoApp? = nil) -> StackVerdict {
            StackChallenge.verdict(status: status, body: data, nonce: KAT.nonce, secret: secret, expectedApp: app)
        }
        XCTAssertEqual(verdict(nil, status: nil), .down)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret]), status: 503), .down)
        XCTAssertEqual(verdict(body(["stack": "open"])), .open)
        XCTAssertEqual(verdict(body(["stack": "matched"])), .legacy)
        XCTAssertEqual(verdict(body(["stack": "mismatched"])), .legacy)
        XCTAssertEqual(verdict(body(["status": "ok"])), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof"])), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret])), .ours(contract: nil))
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret]), secret: "other"), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "app": "ambient", "contract": 1]), app: .ambient),
                       .ours(contract: 1))
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "app": "craft"]), app: .ambient),
                       .stale, "a proof for another app than the one asked is not ours")
    }

    func testTheChallengeNamesTheAppAndNeverTheSecret() {
        let headers = StackChallenge.headers(nonce: KAT.nonce, app: .veil)
        XCTAssertEqual(headers, ["X-Ambient-Nonce": KAT.nonce, "X-Rao-App": "veil"])
        XCTAssertEqual(StackChallenge.headers(nonce: KAT.nonce, app: nil), ["X-Ambient-Nonce": KAT.nonce])
    }
}
