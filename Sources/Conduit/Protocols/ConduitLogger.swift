import Logging

/// Logging seam for Conduit's session/client machinery. Consumers route these
/// through their own logging stacks (e.g. Seer's structured Cockpit logger);
/// the optional label carries the event name some backends key on.
public protocol ConduitLogger: Sendable {
    func debug(_ label: String?, _ message: String)
    func info(_ label: String?, _ message: String)
    func warning(_ label: String?, _ message: String)
    func error(_ label: String?, _ message: String)
}

public extension ConduitLogger {
    func debug(_ message: String)   { debug(nil, message) }
    func info(_ message: String)    { info(nil, message) }
    func warning(_ message: String) { warning(nil, message) }
    func error(_ message: String)   { error(nil, message) }
}

/// Default adapter over swift-log for consumers without a custom logging stack.
public struct SwiftLogConduitLogger: ConduitLogger {
    public let base: Logger

    public init(_ base: Logger) { self.base = base }

    public func debug(_ label: String?, _ message: String)   { base.debug("\(message)") }
    public func info(_ label: String?, _ message: String)    { base.info("\(message)") }
    public func warning(_ label: String?, _ message: String) { base.warning("\(message)") }
    public func error(_ label: String?, _ message: String)   { base.error("\(message)") }
}
