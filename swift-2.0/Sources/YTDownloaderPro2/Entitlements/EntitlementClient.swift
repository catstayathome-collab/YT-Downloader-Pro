import Foundation

enum EntitlementClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAccessToken
    case unauthorized
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
    case cancelled
    case transportUnavailable
}

protocol EntitlementTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionEntitlementTransport: EntitlementTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EntitlementClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

protocol EntitlementFetching: Sendable {
    func fetch(accessToken: String) async throws -> String
}

struct EntitlementClient: EntitlementFetching, Sendable {
    static let maximumResponseBytes = 64 * 1_024

    let endpoint: URL
    let transport: any EntitlementTransport

    init(endpoint: URL, transport: any EntitlementTransport = URLSessionEntitlementTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func fetch(accessToken: String) async throws -> String {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.fragment == nil else {
            throw EntitlementClientError.invalidEndpoint
        }
        guard !accessToken.isEmpty,
              accessToken == accessToken.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EntitlementClientError.invalidAccessToken
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["schema": 1, "platform": "macos"],
            options: [.sortedKeys]
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw EntitlementClientError.cancelled
        } catch let error as EntitlementClientError {
            throw error
        } catch {
            throw EntitlementClientError.transportUnavailable
        }

        guard data.count <= Self.maximumResponseBytes else {
            throw EntitlementClientError.responseTooLarge
        }
        if response.statusCode == 401 {
            throw EntitlementClientError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw EntitlementClientError.httpStatus(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["token"],
              let token = dictionary["token"] as? String,
              !token.isEmpty,
              token == token.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EntitlementClientError.invalidResponse
        }
        return token
    }
}
