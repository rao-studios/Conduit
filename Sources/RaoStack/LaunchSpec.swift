//
//  LaunchSpec.swift
//  RaoStack
//
//  WHAT: Exactly how Sewn and an app's Thread are started on a shared stack:
//        executable, arguments, environment, working directory, where they
//        log and where their run record goes.
//  IN:   Ambient's LocalStackManager, the RaoStackLauncher (Craft, Veil).
//  OUT:  Byte-identical launches whichever app does the launching, so a
//        change to Sewn's or Thread's flags is made here once.
//  PIN:  Nothing secret in argv (`ps` shows it to every user): the secret, the
//        node id and RAO_HOME ride in the environment. A child inherits only an
//        allowlisted slice of the launcher's environment — never RAO_*,
//        AMBIENT_* or a provider key; the servers read keys from RAO_HOME.
//

import Foundation

public struct LaunchSpec: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case sewn
        case thread
    }

    public var role: Role
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var ports: RaoPorts
    public var runRecord: URL
    public var logFile: URL
    /// Whose secret /health should prove: X-Rao-App on the challenge.
    public var challengeApp: RaoApp?

    public init(role: Role, executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: URL, ports: RaoPorts, runRecord: URL, logFile: URL, challengeApp: RaoApp?) {
        self.role = role
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.runRecord = runRecord
        self.logFile = logFile
        self.challengeApp = challengeApp
    }

    public var healthURL: URL { URL(string: "http://127.0.0.1:\(ports.http)/health")! }
    /// Held while starting this server, by every launcher in every app, so
    /// two never start it at once. Beside the run record.
    public var startLock: URL { runRecord.deletingLastPathComponent().appendingPathComponent("start.lock") }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(ports.http)")! }
}

public struct ThreadLaunchOptions: Sendable, Equatable {
    public enum HuggingFaceHome: Sendable, Equatable {
        /// RAO_HOME/models/huggingface.
        case shared
        /// Set nothing: the child keeps whatever HF_HOME it inherits, or the
        /// hub's own default.
        case inherit
        case path(URL)
    }

    /// `--use-mlx`: embed on device.
    public var useMLX: Bool
    /// `--graph-backend mlx|mistral|keyword`.
    public var graphBackend: String?
    public var mlxModel: String?
    public var graphModel: String?
    /// THREAD_NODE_ID. Nil lets Thread keep the id in its data directory.
    public var nodeID: UUID?
    /// Overrides RAO_HOME/apps/<app>/thread-db (a user's custom location).
    public var dataDirectory: URL?
    /// Overrides the app's ports from RaoPortPlan (a user's custom ports).
    public var ports: RaoPorts?
    /// Register with the shared Sewn. Off: the Thread runs standalone.
    public var mothership: Bool
    public var huggingFaceHome: HuggingFaceHome
    /// Appended as given, last.
    public var extraArguments: [String]

    public init(useMLX: Bool = false, graphBackend: String? = nil, mlxModel: String? = nil, graphModel: String? = nil,
                nodeID: UUID? = nil, dataDirectory: URL? = nil, ports: RaoPorts? = nil, mothership: Bool = true,
                huggingFaceHome: HuggingFaceHome = .shared, extraArguments: [String] = []) {
        self.useMLX = useMLX
        self.graphBackend = graphBackend
        self.mlxModel = mlxModel
        self.graphModel = graphModel
        self.nodeID = nodeID
        self.dataDirectory = dataDirectory
        self.ports = ports
        self.mothership = mothership
        self.huggingFaceHome = huggingFaceHome
        self.extraArguments = extraArguments
    }
}

public enum LaunchSpecs {

    /// Environment names a child inherits from its launcher.
    public static let inheritedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TZ",
        "XDG_CACHE_HOME",                       // Frigate's cache root fallback
        "SUPABASE_URL", "SUPABASE_ANON_KEY",    // public; a shell value beats sewn.env
    ]

    /// Environment prefixes a child inherits.
    public static let inheritedPrefixes = [
        "LC_",                                  // locale
        "HF_",                                  // HF_HOME, HF_ENDPOINT, HF_HUB_* — model downloads
        "MLX_",                                 // MLX diagnostics and compile switches
        "SEWN_", "THREAD_", "FRIGATE_",         // the servers' own knobs
    ]

    /// Never inherited, even under an allowed prefix: the launcher sets what
    /// matters explicitly.
    public static let neverInherited: Set<String> = [
        RaoHome.environmentKey, StackSecret.appEnvironmentKey, StackSecret.environmentKey,
        "THREAD_NODE_ID", "SEWN_DATA_DIR", "THREAD_DATA_DIR",
    ]

    /// The allowlisted slice of `environment`.
    public static func inherited(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            guard !neverInherited.contains(name), !name.hasSuffix("_API_KEY") else { return false }
            return inheritedNames.contains(name) || inheritedPrefixes.contains { name.hasPrefix($0) }
        }
    }

    // MARK: - Sewn

    /// The shared Sewn.
    /// - Parameters:
    ///   - executable: Default RAO_HOME/sewn/bin/sewn-server; a dev launcher
    ///     passes its checkout's build.
    ///   - workingDirectory: Default RAO_HOME/sewn. A checkout build runs in
    ///     its checkout so it finds that checkout's `.env`.
    ///   - buildID: Reported as RAO_SEWN_BUILD, for logs.
    ///   - inherited: The launcher's environment; filtered here.
    public static func sewn(
        home: RaoHome,
        config: SewnConfig? = nil,
        executable: URL? = nil,
        workingDirectory: URL? = nil,
        buildID: String? = nil,
        challengeApp: RaoApp,
        inherited: [String: String]
    ) -> LaunchSpec {
        let config = config ?? SewnConfig.load(home: home)
        let ports = config.ports
        var environment = Self.inherited(inherited)
        environment[RaoHome.environmentKey] = PrivateFile.path(home.root)
        environment["HF_HOME"] = PrivateFile.path(config.huggingFaceHome(home: home))
        if let buildID { environment["RAO_SEWN_BUILD"] = buildID }
        return LaunchSpec(
            role: .sewn,
            executable: executable ?? home.sewnBinary,
            arguments: [
                "--host", "127.0.0.1",
                "--port", String(ports.http),
                "--grpc-port", String(ports.grpc),
                "--data-dir", PrivateFile.path(config.dataDirectory(home: home)),
            ],
            environment: environment,
            workingDirectory: workingDirectory ?? home.sewnDirectory,
            ports: ports,
            runRecord: home.sewnRunRecord,
            logFile: home.sewnLogFile,
            challengeApp: challengeApp
        )
    }

    // MARK: - Thread

    /// `app`'s own Thread.
    /// - Parameters:
    ///   - secret: `app`'s stack secret; the Thread accepts only it.
    ///   - sewnPorts: Where the shared Sewn listens (for registration).
    ///   - workingDirectory: Default RAO_HOME/apps/<app>. A checkout build
    ///     runs in its checkout so it finds that checkout's `.env`.
    public static func thread(
        for app: RaoApp,
        home: RaoHome,
        executable: URL,
        secret: String,
        sewnPorts: RaoPorts,
        options: ThreadLaunchOptions = ThreadLaunchOptions(),
        workingDirectory: URL? = nil,
        inherited: [String: String]
    ) -> LaunchSpec {
        let ports = options.ports ?? RaoPortPlan.thread(app)
        let dataDirectory = options.dataDirectory ?? home.threadDataDirectory(for: app)
        var arguments = [
            "--host", "127.0.0.1",
            "--port", String(ports.http),
            "--grpc-port", String(ports.grpc),
        ]
        if options.mothership {
            arguments += [
                "--mothership-host", "127.0.0.1",
                "--mothership-grpc-port", String(sewnPorts.grpc),
            ]
        }
        arguments += ["--data-dir", PrivateFile.path(dataDirectory)]
        if let graphBackend = options.graphBackend { arguments += ["--graph-backend", graphBackend] }
        if options.useMLX { arguments.append("--use-mlx") }
        if let mlxModel = options.mlxModel { arguments += ["--mlx-model", mlxModel] }
        if let graphModel = options.graphModel { arguments += ["--graph-model", graphModel] }
        arguments += options.extraArguments

        var environment = Self.inherited(inherited)
        environment[RaoHome.environmentKey] = PrivateFile.path(home.root)
        environment[StackSecret.appEnvironmentKey] = app.rawValue
        environment[StackSecret.environmentKey] = secret
        if let nodeID = options.nodeID { environment["THREAD_NODE_ID"] = nodeID.uuidString }
        switch options.huggingFaceHome {
        case .shared: environment["HF_HOME"] = PrivateFile.path(home.huggingFaceHome)
        case .inherit: break
        case .path(let url): environment["HF_HOME"] = PrivateFile.path(url)
        }

        return LaunchSpec(
            role: .thread,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory ?? home.appDirectory(app),
            ports: ports,
            runRecord: home.threadRunRecord(for: app),
            logFile: home.threadLogFile(for: app),
            challengeApp: app
        )
    }
}
