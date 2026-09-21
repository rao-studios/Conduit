//
//  DuplicateSessionInProcessTests.swift
//  ConduitTests
//
//  The refusal end to end: while one Session stream is live for a Thread id,
//  a second one for the same id fails with ALREADY_EXISTS and leaves the
//  first untouched; once the first closes, the slot is free again.
//

import Foundation
import GRPCCore
import XCTest
@testable import Conduit

final class DuplicateSessionInProcessTests: XCTestCase {

    func testASecondSessionIsRefusedUntilTheFirstCloses() async throws {
        let mothership = InProcessMothership()
        let threadId = UUID()

        try await mothership.run { stub in
            // The first session stays open until `release` finishes, and
            // reports each pong it receives on `pongs`.
            let (release, releaseNow) = AsyncStream<Void>.makeStream()
            let (pongs, pongArrived) = AsyncStream<Void>.makeStream()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let pongCount = try await stub.session(
                        requestProducer: { writer in
                            try await writer.write(.ping(threadId: threadId))
                            for await _ in release {}   // hold the stream open
                        },
                        onResponse: { response in
                            var count = 0
                            for try await msg in response.messages {
                                if case .pong = msg.payload {
                                    count += 1
                                    pongArrived.yield(())
                                }
                            }
                            return count
                        }
                    )
                    XCTAssertEqual(pongCount, 1)
                }

                // The pong is sent after openSession, so once it lands the
                // first session is live on the mothership.
                var pongIterator = pongs.makeAsyncIterator()
                _ = await pongIterator.next()
                let liveAfterFirst = await mothership.sessionManager.hasSession(for: threadId)
                XCTAssertTrue(liveAfterFirst)

                // Second session, same id: ALREADY_EXISTS.
                do {
                    try await stub.session(
                        requestProducer: { writer in try await writer.write(.ping(threadId: threadId)) },
                        onResponse: { response in for try await _ in response.messages {} }
                    )
                    XCTFail("expected ALREADY_EXISTS")
                } catch let error as RPCError {
                    XCTAssertEqual(error.code, .alreadyExists)
                    XCTAssertTrue(error.message.contains(threadId.uuidString))
                }

                // The refusal did not disturb the first session.
                let liveAfterRefusal = await mothership.sessionManager.hasSession(for: threadId)
                XCTAssertTrue(liveAfterRefusal)

                // Let the first client half-close; the mothership reaps its session.
                releaseNow.finish()
                try await group.waitForAll()
            }

            let reaped = await waitUntil { await !mothership.sessionManager.hasSession(for: threadId) }
            XCTAssertTrue(reaped, "the first session should be closed once its stream ends")

            // Third session: the slot is free and answers with a pong.
            let gotPong = try await stub.session(
                requestProducer: { writer in try await writer.write(.ping(threadId: threadId)) },
                onResponse: { response in
                    for try await msg in response.messages {
                        if case .pong = msg.payload { return true }
                    }
                    return false
                }
            )
            XCTAssertTrue(gotPong)
        }

        XCTAssertTrue(mothership.logger.warnings.contains { $0.contains("Refused a second session for Thread \(threadId)") })
    }
}
