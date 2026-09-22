//
//  RaoApp.swift
//  RaoStack
//
//  WHAT: The Rao apps that share one stack, and the ports each one's Thread
//        and the shared Sewn listen on.
//  PIN:  A closed set on purpose. Sewn accepts a secret per app it knows, so
//        adding an app is a contract change made once, here, and picked up by
//        Sewn, Thread and every app when they bump Conduit.
//        The ports stay clear of the 8080/8081/9090/9091/9092 defaults Mary,
//        Bonnie and Fleet run open stacks on.
//

public enum RaoApp: String, CaseIterable, Codable, Sendable, Hashable {
    case ambient
    case craft
    case veil

    /// An app named by a header or an environment value: trimmed, any case.
    /// Nil for anything that isn't one of the apps.
    public init?(header: String?) {
        guard let header else { return nil }
        let name = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let app = RaoApp(rawValue: name) else { return nil }
        self = app
    }

    public var displayName: String {
        switch self {
        case .ambient: return "Ambient"
        case .craft: return "Craft"
        case .veil: return "Veil"
        }
    }
}

public struct RaoPorts: Codable, Hashable, Sendable, CustomStringConvertible {
    public var http: Int
    public var grpc: Int

    public init(http: Int, grpc: Int) {
        self.http = http
        self.grpc = grpc
    }

    public var description: String { "http \(http), grpc \(grpc)" }
}

public enum RaoPortPlan {
    /// The one Sewn every app shares.
    public static let sewn = RaoPorts(http: 47080, grpc: 47091)

    /// Each app's own Thread.
    public static func thread(_ app: RaoApp) -> RaoPorts {
        switch app {
        case .ambient: return RaoPorts(http: 47081, grpc: 47090)
        case .craft: return RaoPorts(http: 48081, grpc: 48090)
        case .veil: return RaoPorts(http: 49081, grpc: 49090)
        }
    }

    /// The defaults other stacks on this machine use (Mary, Bonnie, Fleet and
    /// the servers' own flags). Nothing in the plan may land on one.
    public static let reservedElsewhere: Set<Int> = [8080, 8081, 9090, 9091, 9092]
}

import Foundation
