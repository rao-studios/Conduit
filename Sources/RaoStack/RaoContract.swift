//
//  RaoContract.swift
//  RaoStack
//
//  WHAT: The version of the shared-stack contract this build speaks. Sewn
//        reports it on /health; installers compare it before replacing the
//        Sewn in ~/.rao; launchers restart a shared Sewn that is older.
//  PIN:  Bump `version` when a change to Sewn, Thread or this package means an
//        app built against the old contract can't use the new stack as-is (a
//        new required header, a new file the servers depend on, a new port).
//        Adding a field every reader ignores is not a bump.
//

public enum RaoContract {
    /// The stack contract: /health, the wire, the launch arguments.
    public static let version = 1
    /// The ~/.rao layout (layout.json's `version`).
    public static let layoutVersion = 1
}
