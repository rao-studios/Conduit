//
//  StackProbe.swift
//  RaoStackLauncher
//
//  WHAT: One /health challenge over the network: a fresh nonce and the app's
//        name out, a verdict back.
//  PIN:  Never sends a secret. Loopback only, no proxy, no cache, no cookies.
//

#if os(macOS)
import Foundation
import RaoStack

public enum StackProbe {

    public static func challenge(_ spec: LaunchSpec, secret: String, timeout: TimeInterval = 2) async -> StackVerdict {
        await challenge(url: spec.healthURL, secret: secret, app: spec.challengeApp, timeout: timeout)
    }

    public static func challenge(url: URL, secret: String, app: RaoApp?, timeout: TimeInterval = 2) async -> StackVerdict {
        let nonce = StackSecret.nonce()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in StackChallenge.headers(nonce: nonce, app: app) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return StackChallenge.verdict(status: status, body: data, nonce: nonce, secret: secret, expectedApp: app)
        } catch {
            return .down
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()
}
#endif
