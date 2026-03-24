// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// URLSessionWebSocketTask (and therefore DefaultWebSocketConnection) is not available on Linux.
#if !os(Linux)
import XCTest
@testable import SignalRClient

/// Tests the URLSession teardown race condition in `DefaultWebSocketConnection.stop()`.
///
/// ## The bug
/// `stop()` called `urlSession?.finishTasksAndInvalidate()` and returned immediately.
/// `finishTasksAndInvalidate()` triggers an **asynchronous** teardown inside Network.framework:
/// the WebSocket task dealloc reads `task.session` (an ObjC retain) on a background thread.
/// If the actor holding `urlSession` was released before that retain completed, the result was
/// an `objc_retain` crash (bad access, ISA = 0x20).
///
/// ## The fix
/// `stop()` now awaits `didBecomeInvalidWithError:` via a `CheckedContinuation` before
/// nilling `urlSession` and `websocket`, guaranteeing the session outlives Network.framework's
/// async teardown.
final class DefaultWebSocketConnectionStopTests: XCTestCase {

    private var logger: Logger!

    override func setUp() {
        super.setUp()
        logger = Logger(logLevel: .error, logHandler: DefaultLogHandler())
    }

    /// Reliable regression test: verifies that `stop()` does not return until URLSession
    /// invalidation has fully completed.
    ///
    /// Injects a `DelegateProxy` that intercepts `didBecomeInvalidWithError` from the real
    /// URLSession and holds it for a fixed `invalidationDelay` before forwarding it to
    /// `DefaultWebSocketConnection`. With the fix, `stop()` awaits that callback and therefore
    /// takes ≥ `invalidationDelay`. Without the fix, `stop()` returns immediately — the
    /// assertion fails, exposing the bug before any memory-safety crash can occur.
    ///
    /// This test is deterministic: it does not rely on lucky race-condition timing.
    func testStop_waitsForURLSessionInvalidationBeforeReturning() async throws {
        let invalidationDelay: TimeInterval = 0.1 // 100 ms — well above scheduling noise

        // Build a connection using our injected session factory.
        // DefaultWebSocketConnection is internal (not private), accessible via @testable.
        let connection = WebSocketTransport.DefaultWebSocketConnection(
            logger: logger,
            sessionFactory: { config, delegate, queue in
                // DelegateProxy sits between URLSession and DefaultWebSocketConnection.
                // It suppresses all task/WebSocket events (preventing an internal stop()
                // call from racing with ours) and delays didBecomeInvalidWithError by
                // `invalidationDelay`, creating a controlled, measurable window.
                let proxy = DelegateProxy(realDelegate: delegate, delay: invalidationDelay)
                return URLSession(configuration: config, delegate: proxy, delegateQueue: queue)
            }
        )

        // Wrap in a WebSocketTransport so we can call stop() through the normal path.
        let transport = WebSocketTransport(
            accessTokenFactory: nil,
            logger: logger,
            headers: [:],
            websocket: connection
        )

        // Start connecting. connect() creates the URLSession synchronously, then suspends
        // at openTcs.task(). The connection to port 1 will never open (ECONNREFUSED), but
        // because DelegateProxy suppresses task events, DefaultWebSocketConnection never
        // receives didCompleteWithError — so connect() stays suspended until stop() unblocks it.
        let connectTask = Task {
            try? await transport.connect(url: "ws://127.0.0.1:1", transferFormat: .text)
        }

        // Yield to let connect() create the URLSession and reach its openTcs suspension.
        await Task.yield()

        // ── Measure how long stop() takes ────────────────────────────────────────────────
        let start = Date()
        try? await transport.stop(error: nil)
        let elapsed = Date().timeIntervalSince(start)
        // ─────────────────────────────────────────────────────────────────────────────────

        await connectTask.value

        // With the fix: stop() awaits didBecomeInvalidWithError (arrives after 100 ms)
        //               → elapsed ≥ 100 ms ✓
        //
        // Without the fix: stop() returns immediately after finishTasksAndInvalidate()
        //                  → elapsed ≈ 0 ms → assertion fails, exposing the bug ✗
        XCTAssertGreaterThanOrEqual(
            elapsed,
            invalidationDelay * 0.9,
            "stop() returned in \(String(format: "%.3f", elapsed))s but should have " +
            "waited ≥\(invalidationDelay)s for URLSession invalidation. " +
            "This means stop() does not await didBecomeInvalidWithError — the fix is missing."
        )
    }

    /// Crash-reproduction stress test using a real WebSocket server.
    ///
    /// With a genuinely established (or in-progress) connection, Network.framework has live
    /// TCP/TLS state to tear down asynchronously. Calling `stop()` and immediately releasing
    /// the transport creates the exact condition that caused the `objc_retain` crash in production.
    ///
    /// **To verify**: revert `stop()` to the original (remove the `withCheckedContinuation` block)
    /// and run this test — expect `EXC_BAD_ACCESS` in `objc_retain` within a few iterations.
    /// With the fix in place it should complete all iterations without crashing.
    func testStop_doesNotCrashWithRealWebSocketServer() async throws {
        let url = "wss://ws.euw.newblack.test.eva-online.cloud/signalr/shop?requestedOrganizationUnitID=93"

        for i in 1...50 {
            let transport = WebSocketTransport(
                accessTokenFactory: nil,
                logger: logger,
                headers: [:]
                // No mock → real DefaultWebSocketConnection with a real URLSession
            )

            // Start connecting. We don't need it to succeed — even the TLS handshake
            // in progress is enough for Network.framework to have teardown work to do.
            let connectTask = Task {
                try? await transport.connect(url: url, transferFormat: .text)
            }

            // Let the connection attempt get underway (TLS, HTTP upgrade, etc.).
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

            // Stop while Network.framework may still be active.
            // Old code: finishTasksAndInvalidate() + immediate return → crash window.
            // New code: awaits didBecomeInvalidWithError() → safe.
            try? await transport.stop(error: nil as Error?)
            _ = await connectTask.result

            // transport is released here — on old code this is the crash trigger.
            print("iteration \(i)/50 completed")
        }
    }
}

// MARK: - DelegateProxy

/// Sits between a `URLSession` and `DefaultWebSocketConnection` to control invalidation timing.
///
/// - Delays `didBecomeInvalidWithError` by a fixed amount before forwarding to the real delegate.
///   This makes the invalidation timing deterministic and testable.
/// - Intentionally does **not** forward task-level or WebSocket-level delegate methods
///   (`didCompleteWithError`, `didOpenWithProtocol`, etc.), suppressing them entirely.
///   This prevents Network.framework from triggering an internal `stop()` call that would
///   race with the explicit `stop()` call in the test.
private final class DelegateProxy: NSObject, URLSessionDelegate {
    private let realDelegate: URLSessionDelegate
    private let delay: TimeInterval

    init(realDelegate: URLSessionDelegate, delay: TimeInterval) {
        self.realDelegate = realDelegate
        self.delay = delay
        super.init()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let realDelegate = realDelegate
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            realDelegate.urlSession?(session, didBecomeInvalidWithError: error)
        }
    }
}
#endif
