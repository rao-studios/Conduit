//
//  ThreadSessionManagerTests.swift
//  ConduitTests
//
//  One session per Thread, closed only by the handle that opened it: a second
//  open is refused, a stale handle can't close its successor, and a real close
//  finishes the stream and fails whoever was waiting on the Thread.
//

import Foundation
import XCTest
@testable import Conduit

final class ThreadSessionManagerTests: XCTestCase {

    func testASecondOpenForTheSameThreadIsRefused() async throws {
        let manager = ThreadSessionManager(logger: RecordingLogger())
        let threadId = UUID()
        let first = try await manager.openSession(for: threadId)

        do {
            _ = try await manager.openSession(for: threadId)
            XCTFail("expected sessionAlreadyOpen")
        } catch ThreadSessionError.sessionAlreadyOpen(let refused) {
            XCTAssertEqual(refused, threadId)
        }

        let stillLive = await manager.hasSession(for: threadId)
        XCTAssertTrue(stillLive, "the refusal leaves the first session alone")
        await manager.closeSession(first.handle)
    }

    func testAStaleHandleCannotCloseTheSessionThatReplacedIt() async throws {
        let logger = RecordingLogger()
        let manager = ThreadSessionManager(logger: logger)
        let threadId = UUID()

        let a = try await manager.openSession(for: threadId)
        await manager.closeSession(a.handle)
        let b = try await manager.openSession(for: threadId)

        await manager.closeSession(a.handle)   // late teardown from the old handler
        let liveAfterStaleClose = await manager.hasSession(for: threadId)
        XCTAssertTrue(liveAfterStaleClose)
        XCTAssertTrue(logger.warnings.contains { $0.contains("stale handler") })

        await manager.closeSession(b.handle)
        let liveAfterRealClose = await manager.hasSession(for: threadId)
        XCTAssertFalse(liveAfterRealClose)
    }

    func testClosingTheLiveHandleFinishesTheStreamAndCancelsPendingRequests() async throws {
        let manager = ThreadSessionManager(logger: RecordingLogger())
        let threadId = UUID()
        let (handle, outgoing) = try await manager.openSession(for: threadId)

        var stats = Thread_V1_ThreadSessionMessage()
        stats.payload = .statsRequest(Thread_V1_ThreadStatsRequest())
        let pendingRequest = Task { try await manager.request(stats, to: threadId, timeoutSeconds: 10) }

        // The request is pending as soon as its message reaches the channel.
        var iterator = outgoing.makeAsyncIterator()
        let queued = await iterator.next()
        XCTAssertEqual(queued.map { payloadName($0.payload) }, "statsRequest")

        await manager.closeSession(handle)

        let afterClose = await iterator.next()
        XCTAssertNil(afterClose, "closing finishes the outgoing stream")
        do {
            _ = try await pendingRequest.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // The waiter learns the Thread went away instead of waiting out the timeout.
        }
        let live = await manager.hasSession(for: threadId)
        XCTAssertFalse(live)
    }

    func testReopeningAfterCloseGetsAHigherGeneration() async throws {
        let manager = ThreadSessionManager(logger: RecordingLogger())
        let threadId = UUID()

        let first = try await manager.openSession(for: threadId)
        await manager.closeSession(first.handle)
        let second = try await manager.openSession(for: threadId)

        XCTAssertGreaterThan(second.handle.generation, first.handle.generation)
        XCTAssertNotEqual(first.handle, second.handle)
        XCTAssertEqual(second.handle.threadId, threadId)
        await manager.closeSession(second.handle)
    }

    func testRequestWithoutASessionFailsFast() async {
        let manager = ThreadSessionManager(logger: RecordingLogger())
        let threadId = UUID()
        do {
            _ = try await manager.request(Thread_V1_ThreadSessionMessage(), to: threadId, timeoutSeconds: 10)
            XCTFail("expected noSession")
        } catch ThreadSessionError.noSession(let missing) {
            XCTAssertEqual(missing, threadId)
        } catch {
            XCTFail("expected noSession, got \(error)")
        }
    }
}
