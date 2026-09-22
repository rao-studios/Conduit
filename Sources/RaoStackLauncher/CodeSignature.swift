//
//  CodeSignature.swift
//  RaoStackLauncher
//
//  WHAT: Whether an executable in ~/.rao may be run: signed by Rao's
//        Developer ID team, intact.
//  IN:   SewnInstaller (before copying a bundled Sewn in) and every launcher
//        (before exec'ing the installed one).
//  PIN:  ~/.rao is writable by anything running as this user, so what sits
//        there is only run once its signature says Rao built it. Development
//        builds are ad-hoc signed and accept anything; a shipped app never
//        does.
//

#if os(macOS)
import Foundation
import Security

public enum SignaturePolicy: Sendable, Equatable {
    /// Valid, and signed by this Apple Developer team.
    case developerID(teamID: String)
    /// Development only: no check.
    case unchecked

    /// Rao's Apple Developer team.
    public static let raoTeamID = "TA6WK7F4P8"

    /// Release builds check for Rao's team; debug builds don't.
    public static var standard: SignaturePolicy {
        #if DEBUG
        return .unchecked
        #else
        return .developerID(teamID: raoTeamID)
        #endif
    }

    public var requirement: String? {
        switch self {
        case .developerID(let teamID):
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        case .unchecked:
            return nil
        }
    }

    /// Throws unless `url` satisfies the policy.
    public func check(_ url: URL) throws {
        guard let requirementText = requirement else { return }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw SignatureError.unreadable(url.path(percentEncoded: false), status)
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw SignatureError.unreadable(requirementText, status)
        }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw SignatureError.rejected(url.path(percentEncoded: false), status)
        }
    }
}

public enum SignatureError: Error, Equatable, CustomStringConvertible {
    case unreadable(String, OSStatus)
    case rejected(String, OSStatus)

    public var description: String {
        switch self {
        case .unreadable(let what, let status): return "can't read the signature of \(what) (\(status))"
        case .rejected(let what, let status): return "\(what) is not signed by Rao (\(status))"
        }
    }
}
#endif
