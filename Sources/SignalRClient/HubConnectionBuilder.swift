// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import Foundation

public class HubConnectionBuilder {
    var connection: HttpConnection?
    var logHandler: LogHandler?
    var logLevel: LogLevel?
    var hubProtocol: HubProtocol?
    var serverTimeout: TimeInterval?
    var keepAliveInterval: TimeInterval?
    var url: String?
    var retryPolicy: RetryPolicy?
    var statefulReconnectBufferSize: Int?
    var urlSession: URLSession?
    var httpConnectionOptions: HttpConnectionOptions = HttpConnectionOptions()

    public init() {}

    public func withLogLevel(logLevel: LogLevel) -> HubConnectionBuilder {
        self.logLevel = logLevel
        self.httpConnectionOptions.logLevel = logLevel
        return self
    }

    public func withLogHandler(logHandler: LogHandler) -> HubConnectionBuilder {
        self.logHandler = logHandler
        return self
    }

    public func withHubProtocol(hubProtocol: HubProtocolType) -> HubConnectionBuilder {
        switch hubProtocol {
        case let .json(encoder, decoder):
            self.hubProtocol = JsonHubProtocol(encoder: encoder, decoder: decoder)
        case .messagePack:
            self.hubProtocol = MessagePackHubProtocol()
        }
        return self
    }

    public func withServerTimeout(serverTimeout: TimeInterval) -> HubConnectionBuilder {
        self.serverTimeout = serverTimeout
        return self
    }

    public func withKeepAliveInterval(keepAliveInterval: TimeInterval) -> HubConnectionBuilder {
        self.keepAliveInterval = keepAliveInterval
        return self
    }

    public func withUrl(url: String) -> HubConnectionBuilder {
        self.url = url
        return self
    }

    public func withUrl(url: String, transport: HttpTransportType) -> HubConnectionBuilder {
        self.url = url
        self.httpConnectionOptions.transport = transport
        return self
    }
    
    public func withUrl(url: String, options: HttpConnectionOptions) -> HubConnectionBuilder {
        self.url = url
        self.httpConnectionOptions = options
        return self
    }

    /// Uses the given `URLSession` for the connection instead of a session created by the client.
    ///
    /// The negotiate and long polling requests use the session as-is. The WebSockets and
    /// server-sent events transports need their own `URLSessionDelegate`, so they create a session
    /// from a copy of this session's `configuration` and forward authentication challenges to this
    /// session's delegate.
    public func withUrlSession(urlSession: URLSession) -> HubConnectionBuilder {
        self.urlSession = urlSession
        return self
    }

    public func withStatefulReconnect(bufferSize: Int) -> HubConnectionBuilder {
        self.httpConnectionOptions.useStatefulReconnect = true
        self.statefulReconnectBufferSize = bufferSize
        return self
    }

    public func withAutomaticReconnect() -> HubConnectionBuilder {
        self.retryPolicy = DefaultRetryPolicy(retryDelays: [0, 2, 10, 30])
        return self
    }

    public func withAutomaticReconnect(retryPolicy: RetryPolicy) -> HubConnectionBuilder {
        self.retryPolicy = retryPolicy
        return self
    }

    public func withAutomaticReconnect(retryDelays: [TimeInterval]) -> HubConnectionBuilder {
        self.retryPolicy = DefaultRetryPolicy(retryDelays: retryDelays)
        return self
    }

//    public func withStatefulReconnect() -> HubConnectionBuilder {
//        return withStatefulReconnect(options: StatefulReconnectOptions())
//    }
//
//    public func withStatefulReconnect(options: StatefulReconnectOptions) -> HubConnectionBuilder {
//        self.statefulReconnectBufferSize = options.bufferSize
//        self.httpConnectionOptions.useStatefulReconnect = true
//        return self
//    }

    // The options a connection is built with. The url session is applied here instead of in
    // withUrlSession(urlSession:) so the order of that call and withUrl(url:options:) doesn't matter.
    func resolvedHttpConnectionOptions() -> HttpConnectionOptions {
        var options = httpConnectionOptions
        if let urlSession = urlSession {
            options.urlSession = urlSession
        }
        return options
    }

    public func build() -> HubConnection {
        guard let url = url else {
            fatalError("url must be set with .withUrl(String:)")
        }

        let connection = connection ?? HttpConnection(url: url, options: resolvedHttpConnectionOptions())
        let logger = Logger(logLevel: logLevel, logHandler: logHandler ?? DefaultLogHandler())
        let hubProtocol = hubProtocol ?? JsonHubProtocol()
        let retryPolicy = retryPolicy ?? DefaultRetryPolicy(retryDelays: []) // No retry by default

        return HubConnection(connection: connection,
                             logger: logger,
                             hubProtocol: hubProtocol,
                             retryPolicy: retryPolicy,
                             serverTimeout: serverTimeout,
                             keepAliveInterval: keepAliveInterval,
                             statefulReconnectBufferSize: statefulReconnectBufferSize)
    }
}

public enum HubProtocolType {
    case json(JSONEncoder = .init(), JSONDecoder = .init())
    case messagePack
}
