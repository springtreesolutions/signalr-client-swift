// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import XCTest

@testable import SignalRClient

// Intercepts every request made through a session configured with it, so tests can tell whether a
// caller supplied URLSession was really used.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestedUrls: [String] = []

    static func makeSession() -> URLSession {
        requestedUrls = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        MockURLProtocol.requestedUrls.append(request.url!.absoluteString)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 234, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "custom session".data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

class CustomUrlSessionTests: XCTestCase {
    func testDefaultHttpClientUsesProvidedSession() async throws {
        let client = DefaultHttpClient(logger: dummyLogger, urlSession: MockURLProtocol.makeSession())
        let request = HttpRequest(method: .GET, url: "https://custom.session.invalid/api")

        let (message, response) = try await client.send(request: request)

        XCTAssertEqual(response.statusCode, 234)
        XCTAssertEqual(message.convertToString(), "custom session")
        XCTAssertEqual(MockURLProtocol.requestedUrls, ["https://custom.session.invalid/api"])
    }

    func testHttpConnectionUsesProvidedSession() async throws {
        var options = HttpConnectionOptions()
        options.urlSession = MockURLProtocol.makeSession()
        let connection = HttpConnection(url: "https://custom.session.invalid/hub", options: options)

        do {
            // Negotiation fails because the mock doesn't return a negotiate payload. All the test
            // cares about is that the request went through the provided session.
            try await connection.start(transferFormat: .text)
            XCTFail("Negotiation should fail!")
        } catch {}

        XCTAssertEqual(
            MockURLProtocol.requestedUrls,
            ["https://custom.session.invalid/hub/negotiate?negotiateVersion=1"]
        )
    }

    func testBuilderPassesSessionRegardlessOfCallOrder() throws {
        let session = MockURLProtocol.makeSession()

        var builder = HubConnectionBuilder()
            .withUrlSession(urlSession: session)
            .withUrl(url: "https://custom.session.invalid/hub", options: HttpConnectionOptions())
        XCTAssertIdentical(builder.resolvedHttpConnectionOptions().urlSession, session)

        builder = HubConnectionBuilder()
            .withUrl(url: "https://custom.session.invalid/hub", options: HttpConnectionOptions())
            .withUrlSession(urlSession: session)
        XCTAssertIdentical(builder.resolvedHttpConnectionOptions().urlSession, session)
    }
}
