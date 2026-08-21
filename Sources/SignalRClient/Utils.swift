// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

class Utils {
    static func getUserAgent() -> String {
        return
            "Microsoft SignalR Client/Swift \(PackageVersion); \(currentOSVersion())"
    }

    static func currentOSVersion() -> String {
        #if os(macOS)
            let osName = "macOS"
        #elseif os(iOS)
            #if targetEnvironment(macCatalyst)
                let osName = "Mac Catalyst"
            #else
                let osName = "iOS"
            #endif
        #elseif os(tvOS)
            let osName = "tvOS"
        #elseif os(watchOS)
            let osName = "watchOS"
        #elseif os(Windows)
            return "Windows"
        #elseif os(Linux)
            return "Linux"
        #else
            return "Unknown OS"
        #endif

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString =
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            return "\(osName) \(versionString)"
        #endif
    }
}

extension Utils {
    /// Copies the configuration of a caller-supplied session, or creates a default one.
    static func sessionConfiguration(from urlSession: URLSession?) -> URLSessionConfiguration {
        // URLSession.configuration returns a copy, so mutating the result is safe.
        return urlSession?.configuration ?? URLSessionConfiguration.default
    }
}

#if !os(Linux)
    extension Utils {
        /// Forwards an authentication challenge to the delegate of a caller-supplied session.
        ///
        /// The WebSockets and SSE transports install their own `URLSessionDelegate`, so they can't
        /// use a caller-supplied session directly. Forwarding the challenge keeps delegate based
        /// logic such as certificate pinning working on those transports. Returns `false` when the
        /// caller's session has no delegate handling challenges, in which case the caller is
        /// responsible for performing default handling.
        static func forwardAuthChallenge(
            _ challenge: URLAuthenticationChallenge,
            session: URLSession,
            task: URLSessionTask? = nil,
            to originalSession: URLSession?,
            completionHandler: @escaping @Sendable (
                URLSession.AuthChallengeDisposition, URLCredential?
            ) -> Void
        ) -> Bool {
            guard let delegate = originalSession?.delegate else { return false }
            if let task = task, let taskDelegate = delegate as? URLSessionTaskDelegate,
               taskDelegate.urlSession?(
                   session, task: task, didReceive: challenge,
                   completionHandler: completionHandler
               ) != nil {
                return true
            }
            return delegate.urlSession?(
                session, didReceive: challenge, completionHandler: completionHandler
            ) != nil
        }
    }
#endif

extension HttpRequest {
    init(
        method: HttpMethod, url: String, content: StringOrData? = nil,
        responseType: TransferFormat? = nil,
        headers: [String: String]? = nil, timeout: TimeInterval? = nil,
        options: HttpConnectionOptions, includeUserAgent: Bool = true
    ) {
        self.init(
            method: method, url: url, content: content,
            responseType: responseType, headers: headers,
            timeout: timeout
        )
        if includeUserAgent {
            self.headers["User-Agent"] = Utils.getUserAgent()
        }
        if let headers = options.headers {
            self.headers = self.headers.merging(headers) { (_, new) in new }
        }
        if let timeout = options.timeout {
            self.timeout = timeout
        }
    }
}

extension Data {
    func convertToStringOrData(transferFormat: TransferFormat) throws
    -> StringOrData {
        switch transferFormat {
        case .text:
            guard
                let message = String(
                    data: self, encoding: .utf8
                )
            else {
                throw SignalRError.invalidTextMessageEncoding
            }
            return .string(message)
        case .binary:
            return .data(self)
        }
    }
}

extension StringOrData {
    func getDataDetail(includeContent: Bool) -> String {
        switch self {
        case .string(let str):
            return
                "String data of length \(str.count)\(includeContent ? ". Content: \(str)" : "")"
        case .data(let data):
            // TODO: data format?
            return
                "Binary data of length \(data.count)\(includeContent ? ". Content: \(data)" : "")"
        }
    }

    func isEmpty() -> Bool {
        switch self {
        case .string(let str):
            return str.count == 0
        case .data(let data):
            return data.isEmpty
        }
    }

    func convertToString() -> String? {
        switch self {
        case .string(let str):
            return str
        case .data(let data):
            return String(data: data, encoding: .utf8)
        }
    }

    func converToData() -> Data {
        switch self {
        case .string(let str):
            return str.data(using: .utf8)!
        case .data(let data):
            return data
        }
    }
}
