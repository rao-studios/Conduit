//
//  ProviderKeyStoreTests.swift
//  RaoStackTests
//

import Foundation
import XCTest
@testable import RaoStack

final class ProviderKeyStoreTests: XCTestCase {

    func testTheEnvironmentAnswersWithoutAFile() {
        let store = ProviderKeyStore(home: nil, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertFalse(store.isFileBacked)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")
        XCTAssertNil(store.value(for: "TINKER_API_KEY"))
    }

    func testTheFileBeatsTheEnvironmentAndAChangeIsSeenWithoutANewStore() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")

        let writer = ProviderKeyStore(home: test.home)
        try writer.write("MISTRAL_API_KEY", value: "typed-1", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "typed-1")
        try writer.write("MISTRAL_API_KEY", value: "typed-2", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "typed-2")
        XCTAssertEqual(store.record(for: "MISTRAL_API_KEY")?.writtenBy, .ambient)

        try writer.remove("MISTRAL_API_KEY")
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env", "removed: back to the environment")
    }

    func testAnEmptyValueFallsBackAndTheFileIsPrivate() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home, environment: { ["MISTRAL_API_KEY": "from-env"] })
        try store.write("MISTRAL_API_KEY", value: "", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")
        XCTAssertEqual(test.mode(test.home.providersFile), 0o600)
    }

    func testWritersOfDifferentKeysBothSurvive() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = ProviderKeyStore(home: test.home)
            try? store.write("KEY_\(index)", value: "v\(index)", source: .typed, writtenBy: .craft)
        }
        let records = ProviderKeyStore(home: test.home).records()
        XCTAssertEqual(records.count, 20)
    }

    func testAnUnreadableFileIsNoKeys() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.writeAtomically(Data("not json".utf8), to: test.home.providersFile)
        XCTAssertTrue(ProviderKeyStore(home: test.home).records().isEmpty)
    }
}
