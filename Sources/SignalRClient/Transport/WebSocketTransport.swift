// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor WebSocketTransport: Transport {
    private let logger: Logger
    private let accessTokenFactory: (@Sendable () async throws -> String?)?
    private let headers: [String: String]
    private let webSocketConnection: WebSocketConnection

    private var transferFormat: TransferFormat = .text

    init(accessTokenFactory: (@Sendable () async throws -> String?)?,
         logger: Logger,
         headers: [String: String],
         urlSession: URLSession? = nil,
         websocket: WebSocketConnection? = nil) {
        self.accessTokenFactory = accessTokenFactory
        self.logger = logger
        self.headers = headers
        self.webSocketConnection = websocket ?? DefaultWebSocketConnection(logger: logger, urlSession: urlSession)
    }

    func onReceive(_ handler: OnReceiveHandler?) async {
        await self.webSocketConnection.onReceive(handler)
    }

    func onClose(_ handler: OnCloseHander?) async {
        await self.webSocketConnection.onClose(handler)
    }

    func connect(url: String, transferFormat: TransferFormat) async throws {
        self.logger.log(level: .debug, message: "(WebSockets transport) Connecting.")

        self.transferFormat = transferFormat
        var urlComponents = URLComponents(url: URL(string: url)!, resolvingAgainstBaseURL: false)!
        if urlComponents.scheme == "http" {
            urlComponents.scheme = "ws"
        } else if urlComponents.scheme == "https" {
            urlComponents.scheme = "wss"
        }

        var request = URLRequest(url: urlComponents.url!)

        // Add headeres
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        // Add token to header
        if let factory = accessTokenFactory, let token = try await factory() {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Add user-agent
        request.addValue(Utils.getUserAgent(), forHTTPHeaderField: "User-Agent")

        try await webSocketConnection.connect(request: request, transferFormat: transferFormat)
    }

    func send(_ data: StringOrData) async throws {
        try await webSocketConnection.send(data)
    }

    func stop(error: Error?) async throws {
        try await webSocketConnection.stop(error: error)
    }

    protocol WebSocketConnection {
        func connect(request: URLRequest, transferFormat: TransferFormat) async throws
        func send(_ data: StringOrData) async throws
        func stop(error: Error?) async throws
        func onReceive(_ handler: OnReceiveHandler?) async
        func onClose(_ handler: OnCloseHander?) async
    }

    #if os(Linux)
        private actor DefaultWebSocketConnection: WebSocketConnection {
            func connect(request: URLRequest, transferFormat: TransferFormat) async throws {
                throw SignalRError.unsupportedTransport("WebSockets transport is not supported on Linux")
            }

            func send(_ data: StringOrData) async throws {
                throw SignalRError.unsupportedTransport("WebSockets transport is not supported on Linux")
            }

            func stop(error: (any Error)?) async throws {
                throw SignalRError.unsupportedTransport("WebSockets transport is not supported on Linux")
            }

            func onReceive(_ handler: WebSocketTransport.OnReceiveHandler?) async {
            }

            func onClose(_ handler: WebSocketTransport.OnCloseHander?) async {
            }

            init(logger: Logger, urlSession: URLSession?) {
            }
        }
    #else
        actor DefaultWebSocketConnection: NSObject, WebSocketConnection, URLSessionWebSocketDelegate {
            /// Creates a `URLSession` configured with the given parameters.
            /// Replaceable in tests to control invalidation timing.
            internal typealias SessionFactory = @Sendable (URLSessionConfiguration, URLSessionDelegate, OperationQueue) -> URLSession

            private let logger: Logger
            private let sessionFactory: SessionFactory
            private let openTcs: TaskCompletionSource<Void> = TaskCompletionSource()

            private var urlSession: URLSession?
            private var websocket: URLSessionWebSocketTask?
            private var receiveTask: Task<Void, Never>?
            private var onReceive: OnReceiveHandler?
            private var onClose: OnCloseHander?

            private var closed: Bool = false
            private var invalidationContinuation: CheckedContinuation<Void, Never>?

            // The caller-supplied session, if any. Its configuration is copied into the session
            // created below, and its delegate handles authentication challenges.
            private let providedSession: URLSession?

            init(logger: Logger, urlSession: URLSession? = nil, sessionFactory: @escaping SessionFactory = { URLSession(configuration: $0, delegate: $1, delegateQueue: $2) }) {
                self.logger = logger
                self.providedSession = urlSession
                self.sessionFactory = sessionFactory
            }

            func connect(request: URLRequest, transferFormat: TransferFormat) async throws {
                urlSession = sessionFactory(Utils.sessionConfiguration(from: providedSession), self, OperationQueue())
                websocket = urlSession!.webSocketTask(with: request)

                guard websocket != nil else {
                    throw SignalRError.failedToStartConnection("(WebSockets transport) WebSocket is nil")
                }

                websocket!.resume() // connect but it won't throw even failure

                receiveTask = Task { [weak self] in
                    guard let self = self else { return }
                    await receiveMessage()
                }

                // wait for startTcs to be completed before returning from connect
                // this is to ensure that the connection is truely established
                try await openTcs.task()
            }

            func send(_ data: StringOrData) async throws {
                guard let ws = self.websocket, ws.state == .running else {
                    throw SignalRError.invalidOperation("(WebSockets transport) Cannot send until the transport is connected")
                }

                switch data {
                case .string(let str):
                    try await ws.send(URLSessionWebSocketTask.Message.string(str))
                case .data(let data):
                    try await ws.send(URLSessionWebSocketTask.Message.data(data))
                }
            }

            func stop(error: Error?) async {
                if closed {
                    return
                }
                closed = true

                websocket?.cancel() // Close the current connection first

                // Await full URLSession teardown before releasing references.
                // Without this, Network.framework's async dealloc of the WebSocket task can
                // read `self.session` after URLSession has already been freed → objc_retain crash.
                if let session = urlSession {
                    await withCheckedContinuation { continuation in
                        invalidationContinuation = continuation
                        session.finishTasksAndInvalidate()
                    }
                    urlSession = nil
                    websocket = nil
                }

                if await openTcs.trySetResult(.failure(error ?? SignalRError.connectionAborted)) == true {
                    receiveTask?.cancel() // Cancel the receive task
                } else {
                    await receiveTask?.value // Wait for the receive task to complete
                    await onClose?(error) // Call the close handler
                }
            }

            func onReceive(_ handler: OnReceiveHandler?) async {
                onReceive = handler
            }

            func onClose(_ handler: OnCloseHander?) async {
                onClose = handler
            }

            nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
                Task {
                    await self.resumeInvalidationContinuation()
                }
            }

            private func resumeInvalidationContinuation() {
                invalidationContinuation?.resume()
                invalidationContinuation = nil
            }

            // Let the caller-supplied session's delegate answer challenges (e.g. certificate pinning)
            nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
                if !Utils.forwardAuthChallenge(challenge, session: session, task: task, to: providedSession, completionHandler: completionHandler) {
                    completionHandler(.performDefaultHandling, nil)
                }
            }


            nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
                logger.log(level: .debug, message: "(WebSockets transport) URLSession didCompleteWithError: \(String(describing: error))")

                Task {
                    await stop(error: error)
                }
            }

            // When receive websocket close message?
            nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
                logger.log(level: .debug, message: "(WebSockets transport) URLSession didCloseWith: \(closeCode)")

                Task {
                    await stop(error: nil)
                }
            }

            nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
                logger.log(level: .debug, message: "(WebSockets transport) urlSession didOpenWithProtocol invoked. WebSocket open")

                Task {
                    if await openTcs.trySetResult(.success(())) == true {
                        logger.log(level: .debug, message: "(WebSockets transport) WebSocket connected")
                    }
                }
            }

            private func receiveMessage() async {
                guard let websocket: URLSessionWebSocketTask = websocket else {
                    logger.log(level: .error, message: "(WebSockets transport) WebSocket is nil")
                    return 
                }

                do {
                    while !Task.isCancelled {
                        let message = try await websocket.receive()

                        switch message {
                        case .string(let text):
                            logger.log(level: .debug, message: "(WebSockets transport) Received message: \(text)")
                            await onReceive?(.string(text))
                        case .data(let data):
                            await onReceive?(.data(data))
                        }
                    }
                } catch {
                    logger.log(level: .debug, message: "Websocket receive error : \(error)")
                }
            }
        }
    #endif
}
