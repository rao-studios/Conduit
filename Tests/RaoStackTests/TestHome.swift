//
//  TestHome.swift
//  RaoStackTests
//

import Foundation
@testable import RaoStack

/// A throwaway RAO_HOME under the temp directory, removed on deinit.
final class TestHome {
    let home: RaoHome
    let url: URL

    init(file: StaticString = #file) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rao-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rao home", isDirectory: true)   // a space, on purpose
        home = RaoHome(root: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func mode(_ url: URL) -> UInt16? { PrivateFile.ownerAndMode(url)?.mode }
}
