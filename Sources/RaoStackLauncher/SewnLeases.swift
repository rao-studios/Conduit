//
//  SewnLeases.swift
//  RaoStackLauncher
//
//  WHAT: Who still needs the shared Sewn. Each app holds a lease while it
//        runs; a dev script can pin one until it lets go.
//  IN:   Launchers (acquire at start, release at quit), quit paths deciding
//        whether to stop Sewn.
//  OUT:  `othersAlive(excluding:)`: stop Sewn only when it is false.
//  PIN:  Synchronous on purpose — an app's terminate handler can't await. A
//        lease is live while its process is (pid and start time), so a crashed
//        app never keeps Sewn up forever; dead leases are swept on read.
//

#if os(macOS)
import Foundation
import RaoStack

public struct SewnLeases: Sendable {
    public let home: RaoHome

    public init(home: RaoHome) {
        self.home = home
    }

    /// Records that `app` (this process) needs Sewn. A pinned lease outlives
    /// the process that wrote it.
    public func acquire(for app: RaoApp, pinned: Bool = false, process: ProcessStamp = ProcessProbe.current, now: Date = Date()) throws {
        try PrivateFile.ensureDirectory(home.sewnLeasesDirectory)
        let lease = RaoLease(app: app, process: process, pinned: pinned, acquiredAt: now)
        let file = pinned ? home.sewnPinnedLease(for: app) : home.sewnLease(for: app)
        try PrivateFile.writeAtomically(try RaoHome.encoder.encode(lease), to: file, mode: 0o600)
    }

    /// Lets go of `app`'s lease (its pinned one, when `pinned`). An unpinned
    /// lease is only removed by the process that holds it, so a second copy
    /// of an app (Craft's CLI beside Craft.app) can't drop the first's.
    public func release(for app: RaoApp, pinned: Bool = false, heldBy holder: ProcessStamp = ProcessProbe.current) {
        let file = pinned ? home.sewnPinnedLease(for: app) : home.sewnLease(for: app)
        if !pinned,
           let data = FileManager.default.contents(atPath: PrivateFile.path(file)),
           let lease = try? RaoHome.decoder.decode(RaoLease.self, from: data),
           lease.process.pid != holder.pid,
           ProcessProbe.isRunning(lease.process) {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// Every lease that is still live, dead ones removed.
    public func live() -> [RaoLease] {
        let directory = home.sewnLeasesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(directory)) else { return [] }
        var leases: [RaoLease] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)),
                  let lease = try? RaoHome.decoder.decode(RaoLease.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if lease.pinned || ProcessProbe.isRunning(lease.process) {
                leases.append(lease)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return leases.sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// The apps holding a live lease.
    public func liveHolders() -> [RaoApp] {
        var seen: [RaoApp] = []
        for lease in live() where !seen.contains(lease.app) { seen.append(lease.app) }
        return seen
    }

    /// Whether anyone other than `app`'s own (unpinned) lease needs Sewn: a
    /// different app, or a pinned lease of any app.
    public func othersAlive(excluding app: RaoApp) -> Bool {
        live().contains { $0.app != app || $0.pinned }
    }

    /// Who, other than `app`, is holding Sewn — for a "still in use by …" line.
    public func others(excluding app: RaoApp) -> [RaoApp] {
        var seen: [RaoApp] = []
        for lease in live() where (lease.app != app || lease.pinned) && !seen.contains(lease.app) {
            seen.append(lease.app)
        }
        return seen
    }
}
#endif
