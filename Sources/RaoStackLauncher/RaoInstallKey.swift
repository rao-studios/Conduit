//
//  RaoInstallKey.swift
//  RaoStackLauncher
//
//  WHAT: This Mac's one signing key for Rao Verified records, shared by
//        every Rao app: made in the Secure Enclave by whichever app needs it
//        first, its blob kept in the Keychain under Rao's access group.
//  IN:   The data-protection Keychain, group TA6WK7F4P8.nyc.rao.verified
//  OUT:  The key's public identity and ES256 signatures, for each app's Rao
//        Verified signer (Ambient: RaoVerifiedInstallKey)
//  PIN:  ONE KEY PER MAC. Every app signed with the access group reads the
//        same item. The first to find none makes it; one that loses that
//        race adopts the winner's. The item is this-device-only, so it never
//        leaves in a backup or a migration: a new Mac makes its own.
//  PIN:  THE ENTITLEMENT IS THE GATE. Only an app whose signature carries the
//        access group — which takes a provisioning profile — can read the
//        item. A command-line tool, a helper or a bare development binary
//        gets nothing from it.
//  PIN:  AN APP'S OWN KEY ONLY WHEN IT ASKS. A caller without the entitlement
//        may opt in to a key of its own in the login Keychain. It is a
//        different key and says so (`scope: .app`). A command-line tool never
//        opts in: a tool that could seal a verified record is the forgery tool.
//  PIN:  NEVER A SECOND KEY BY ACCIDENT. A Keychain that is locked or says no
//        is not an empty one: nothing is made, and the caller seals nothing
//        until a later launch can read it.
//

#if os(macOS)
import CryptoKit
import Foundation
import RaoStack
import Security

public actor RaoInstallKey {

    /// Where the private key lives.
    public enum Protection: String, Sendable, Equatable {
        /// Made inside the Secure Enclave; the private key cannot leave it.
        case secureEnclave = "se"
        /// A software key, where there is no enclave.
        case keychain = "kc"
    }

    /// Whose key it is.
    public enum Scope: String, Sendable, Equatable {
        /// The Mac's, shared by every Rao app through the access group.
        case mac
        /// One app's own, for a build without the access group.
        case app
    }

    /// The key's public half.
    public struct Identity: Sendable, Equatable {
        /// P-256, compressed: 33 bytes.
        public let publicKey: Data
        /// First 8 bytes of SHA-256 over `publicKey`, hex — Rao Verified's key id.
        public let keyID: String
        public let protection: Protection
        public let scope: Scope
    }

    /// What a caller without the access group gets.
    public enum Fallback: Sendable, Equatable {
        /// Nothing: no key, so nothing is sealed.
        case none
        /// A key of its own in the login Keychain.
        case appKeychain
    }

    public enum Problem: Error, Equatable { case noKey }

    /// Where a key's blob is kept. The Keychain in an app; memory in tests.
    public struct Store: Sendable {
        public enum Read: Sendable, Equatable {
            case found(Data)
            case notFound
            /// The process is not signed with the access group.
            case missingEntitlement
            /// Locked, denied, or anything else the Keychain said instead.
            case refused(Int32)
        }

        public enum Add: Sendable, Equatable {
            case added
            /// Another app put one there first.
            case duplicate
            case missingEntitlement
            case refused(Int32)
        }

        public var read: @Sendable () -> Read
        public var add: @Sendable (Data) -> Add
        /// Overwrites a blob this Mac cannot use. False when the Keychain refused.
        public var replace: @Sendable (Data) -> Bool

        public init(
            read: @escaping @Sendable () -> Read,
            add: @escaping @Sendable (Data) -> Add,
            replace: @escaping @Sendable (Data) -> Bool
        ) {
            self.read = read
            self.add = add
            self.replace = replace
        }
    }

    /// Rao's Keychain group for the key. The team prefix is what the
    /// entitlement and the provisioning profile both spell.
    public static let accessGroup = SignaturePolicy.raoTeamID + ".nyc.rao.verified"
    public static let service = "nyc.rao.verified"
    /// Numbered, so a deliberate rotation is a new account, not a rewrite.
    public static let account = "install-key-1"

    /// The blob leads with one byte saying what follows.
    static let enclaveTag: UInt8 = 0x01
    static let softwareTag: UInt8 = 0x02

    private enum Key {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private enum Outcome {
        case key(Key)
        case missingEntitlement
        case unavailable
    }

    private let shared: Store
    private let own: Store?
    private let preferEnclave: Bool
    private var held: (key: Key, identity: Identity)?
    /// This launch could not have a key; it does not ask again.
    private var unavailable = false

    /// - Parameters:
    ///   - app: who is asking — names the key of its own, if it falls back.
    ///   - fallback: what to do without the access group.
    public init(
        app: RaoApp,
        fallback: Fallback = .none,
        shared: Store = .sharedKeychain,
        own: Store? = nil,
        preferEnclave: Bool = SecureEnclave.isAvailable
    ) {
        self.shared = shared
        self.own = fallback == .appKeychain ? (own ?? .appKeychain(app)) : nil
        self.preferEnclave = preferEnclave
    }

    // MARK: - Using it

    /// The key's public half, or nil when no key can be had right now.
    public func identity() -> Identity? {
        load()?.identity
    }

    /// ECDSA P-256 over SHA-256 of `message` (ES256): raw r‖s, 64 bytes.
    public func signature(for message: Data) throws -> Data {
        guard let key = load()?.key else { throw Problem.noKey }
        switch key {
        case .enclave(let key): return try key.signature(for: message).rawRepresentation
        case .software(let key): return try key.signature(for: message).rawRepresentation
        }
    }

    /// The key id of a public key, as Rao Verified spells it.
    public static func keyID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The key's life

    private func load() -> (key: Key, identity: Identity)? {
        if let held { return held }
        guard !unavailable else { return nil }
        switch obtain(from: shared) {
        case .key(let key):
            return keep(key, scope: .mac)
        case .unavailable:
            unavailable = true
            return nil
        case .missingEntitlement:
            guard let own, case .key(let key) = obtain(from: own) else {
                unavailable = true
                return nil
            }
            return keep(key, scope: .app)
        }
    }

    private func obtain(from store: Store) -> Outcome {
        switch store.read() {
        case .found(let blob):
            if let key = Self.decode(blob) { return .key(key) }
            // Made on another Mac, or by a format this build does not read.
            // Replaced, and then whatever the store holds is the key: another
            // app may have replaced it in the same moment.
            let fresh = make()
            guard store.replace(Self.encode(fresh)) else { return .unavailable }
            return stored(in: store) ?? .key(fresh)
        case .notFound:
            let fresh = make()
            switch store.add(Self.encode(fresh)) {
            case .added:
                return .key(fresh)
            case .duplicate:
                // Another app made the Mac's key first. Theirs is the one.
                return stored(in: store) ?? .unavailable
            case .missingEntitlement:
                return .missingEntitlement
            case .refused:
                return .unavailable
            }
        case .missingEntitlement:
            return .missingEntitlement
        case .refused:
            return .unavailable
        }
    }

    private func stored(in store: Store) -> Outcome? {
        guard case .found(let blob) = store.read(), let key = Self.decode(blob) else { return nil }
        return .key(key)
    }

    private func keep(_ key: Key, scope: Scope) -> (key: Key, identity: Identity) {
        let publicKey: Data
        let protection: Protection
        switch key {
        case .enclave(let key):
            publicKey = key.publicKey.compressedRepresentation
            protection = .secureEnclave
        case .software(let key):
            publicKey = key.publicKey.compressedRepresentation
            protection = .keychain
        }
        let identity = Identity(
            publicKey: publicKey, keyID: Self.keyID(for: publicKey),
            protection: protection, scope: scope)
        held = (key, identity)
        return (key, identity)
    }

    private func make() -> Key {
        if preferEnclave, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return .enclave(key)
        }
        return .software(P256.Signing.PrivateKey())
    }

    private static func encode(_ key: Key) -> Data {
        switch key {
        case .enclave(let key): return Data([enclaveTag]) + key.dataRepresentation
        case .software(let key): return Data([softwareTag]) + key.rawRepresentation
        }
    }

    private static func decode(_ blob: Data) -> Key? {
        guard let tag = blob.first else { return nil }
        let body = Data(blob.dropFirst())
        switch tag {
        case enclaveTag:
            return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)).map(Key.enclave)
        case softwareTag:
            return (try? P256.Signing.PrivateKey(rawRepresentation: body)).map(Key.software)
        default:
            return nil
        }
    }
}

// MARK: - The Keychain

extension RaoInstallKey.Store {

    /// The Mac's key: the data-protection Keychain, Rao's access group,
    /// this device only.
    public static let sharedKeychain = keychain(
        query: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RaoInstallKey.service,
            kSecAttrAccount as String: RaoInstallKey.account,
            kSecAttrAccessGroup as String: RaoInstallKey.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ],
        adding: [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Rao Verified — this Mac's key",
        ])

    /// One app's own key: the login Keychain, trusted to that app alone.
    public static func appKeychain(_ app: RaoApp) -> RaoInstallKey.Store {
        keychain(
            query: [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: RaoInstallKey.service,
                kSecAttrAccount as String: "\(RaoInstallKey.account).\(app.rawValue)",
            ],
            adding: [
                kSecAttrLabel as String: "Rao Verified — \(app.displayName)'s own key",
            ])
    }

    private static func keychain(query: [String: Any], adding: [String: Any]) -> RaoInstallKey.Store {
        // A dictionary of CF values is not Sendable; the queries are built
        // once and never changed, so each closure keeps its own copy.
        nonisolated(unsafe) let query = query
        nonisolated(unsafe) let adding = adding
        return RaoInstallKey.Store(
            read: {
                var request = query
                request[kSecReturnData as String] = true
                request[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    return (result as? Data).map(Read.found) ?? .refused(status)
                case errSecItemNotFound:
                    return .notFound
                case errSecMissingEntitlement:
                    return .missingEntitlement
                default:
                    return .refused(status)
                }
            },
            add: { data in
                var request = query.merging(adding) { _, new in new }
                request[kSecValueData as String] = data
                let status = SecItemAdd(request as CFDictionary, nil)
                switch status {
                case errSecSuccess: return .added
                case errSecDuplicateItem: return .duplicate
                case errSecMissingEntitlement: return .missingEntitlement
                default: return .refused(status)
                }
            },
            replace: { data in
                SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                    == errSecSuccess
            })
    }
}
#endif
