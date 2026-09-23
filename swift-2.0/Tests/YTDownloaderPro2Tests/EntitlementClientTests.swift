import Foundation
import XCTest
@testable import YTDownloaderPro2

final class EntitlementClientTests: XCTestCase {
    private let endpoint = URL(string: "https://project.supabase.co/functions/v1/entitlement")!

    func testClientSendsOnlyReviewedBodyAndBearerHeader() async throws {
        let transport = RecordingEntitlementTransport(responses: [
            .response(status: 200, body: try tokenResponse("signed-token"))
        ])
        let client = EntitlementClient(endpoint: endpoint, transport: transport)

        let token = try await client.fetch(accessToken: "memory-only-access")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)

        XCTAssertEqual(token, "signed-token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-only-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? NSDictionary)
        XCTAssertEqual(body, ["schema": 1, "platform": "macos"] as NSDictionary)
        XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains("url"))
    }

    func testClientRejectsEmptyAccessTokenBeforeTransport() async {
        let transport = RecordingEntitlementTransport(responses: [])
        let client = EntitlementClient(endpoint: endpoint, transport: transport)

        await assertClientError(.invalidAccessToken) {
            _ = try await client.fetch(accessToken: "  ")
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testClientMapsUnauthorizedSeparatelyAndNeverLeaksResponseBody() async {
        let secretBody = Data("private database detail".utf8)
        let transport = RecordingEntitlementTransport(responses: [
            .response(status: 401, body: secretBody)
        ])
        let client = EntitlementClient(endpoint: endpoint, transport: transport)

        do {
            _ = try await client.fetch(accessToken: "access")
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? EntitlementClientError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains("database"))
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testClientDoesNotAutomaticallyRetryBoundedHTTPFailures() async {
        for status in [400, 403, 500] {
            let transport = RecordingEntitlementTransport(responses: [
                .response(status: status, body: Data("secret-body".utf8))
            ])
            let client = EntitlementClient(endpoint: endpoint, transport: transport)

            await assertClientError(.httpStatus(status)) {
                _ = try await client.fetch(accessToken: "access")
            }
            let requestCount = await transport.requestCount
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testClientRejectsOversizedMalformedAndStructurallyUnexpectedResponses() async throws {
        let cases: [(Data, EntitlementClientError)] = [
            (Data(repeating: 65, count: 65_537), .responseTooLarge),
            (Data("not-json".utf8), .invalidResponse),
            (try tokenResponse(""), .invalidResponse),
            (try JSONSerialization.data(withJSONObject: ["token": "ok", "extra": true]), .invalidResponse)
        ]

        for (body, expected) in cases {
            let transport = RecordingEntitlementTransport(responses: [.response(status: 200, body: body)])
            let client = EntitlementClient(endpoint: endpoint, transport: transport)
            await assertClientError(expected) {
                _ = try await client.fetch(accessToken: "access")
            }
        }
    }

    func testClientPreservesCancellationAsBoundedCategory() async {
        let transport = RecordingEntitlementTransport(responses: [.cancelled])
        let client = EntitlementClient(endpoint: endpoint, transport: transport)

        await assertClientError(.cancelled) {
            _ = try await client.fetch(accessToken: "access")
        }
    }

    private func tokenResponse(_ token: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["token": token], options: [.sortedKeys])
    }

    private func assertClientError(
        _ expected: EntitlementClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? EntitlementClientError, expected)
        }
    }
}

private actor RecordingEntitlementTransport: EntitlementTransport {
    enum Response: Sendable {
        case response(status: Int, body: Data)
        case cancelled
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var requestCount: Int { requests.count }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        switch responses.removeFirst() {
        case let .response(status, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        case .cancelled:
            throw CancellationError()
        }
    }
}
