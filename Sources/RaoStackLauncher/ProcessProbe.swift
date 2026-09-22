//
//  ProcessProbe.swift
//  RaoStackLauncher
//
//  WHAT: What a launcher can learn about a process without trusting it: is it
//        alive, when did it start, what executable is it, which pids listen
//        on a port.
//  PIN:  A pid alone names nothing once it can be recycled; a pid plus its
//        start time names one process. lsof, not a pid file, says who holds a
//        port.
//

#if os(macOS)
import Darwin
import Foundation
import RaoStack

public enum ProcessProbe {

    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Microseconds since 1970 when `pid` started; nil when it isn't running.
    public static func startTime(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// The executable `pid` runs, as the kernel reports it.
    public static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func stamp(of pid: pid_t) -> ProcessStamp? {
        guard isAlive(pid) else { return nil }
        return ProcessStamp(pid: pid, processStart: startTime(of: pid))
    }

    /// This process.
    public static var current: ProcessStamp {
        ProcessStamp(pid: getpid(), processStart: startTime(of: getpid()))
    }

    /// Whether `stamp` still names a running process: alive, and started when
    /// it says (when it says).
    public static func isRunning(_ stamp: ProcessStamp) -> Bool {
        guard isAlive(stamp.pid) else { return false }
        guard let recorded = stamp.processStart else { return true }
        return startTime(of: stamp.pid) == recorded
    }

    /// Pids listening on TCP `port`, per lsof. Empty when none, or lsof failed.
    public static func listeningPIDs(port: Int) -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePIDs(String(decoding: data, as: UTF8.self))
    }

    static func parsePIDs(_ output: String) -> Set<pid_t> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Resolved path of a file URL, for comparing against `executablePath`.
    public static func resolvedPath(_ url: URL) -> String {
        PrivateFile.path(url.resolvingSymlinksInPath())
    }
}
#endif
