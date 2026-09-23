import Foundation

enum DestinationClientError: Error, Equatable, LocalizedError {
    case authenticationFailed
    case payloadTooLarge
    case redirected
    case serverRejected(status: Int)
    case malformedAcknowledgment
    case requestTimedOut
    case connectionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "The destination rejected the API key. Check the key saved for this destination."
        case .payloadTooLarge:
            "The destination rejected the batch size. Try syncing again later or contact the destination's operator."
        case .redirected:
            "The destination tried to redirect the request. Redirects are not allowed for health data; use the final endpoint URL."
        case .serverRejected(let status):
            "The destination returned an error (HTTP \(status)). No data from this batch was confirmed delivered."
        case .malformedAcknowledgment:
            "The destination acknowledged the batch in an unexpected format, so delivery could not be confirmed."
        case .requestTimedOut:
            "The destination did not respond in time."
        case .connectionFailed:
            "The destination could not be reached."
        case .invalidResponse:
            "The destination returned an invalid response."
        }
    }
}

/// HTTPS transport for the receiver contract (`server/API.md`). Uses normal
/// system certificate validation, rejects redirects outright, and never logs
/// endpoints, tokens, or payload contents.
final class HTTPDestinationClient: DestinationClient {
    /// One request in, one raw response out. Injectable so tests can act as
    /// the remote end; production uses URLSession below.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: Transport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false
            // The delegate owns redirect rejection at the session level, so
            // credential-bearing and health-data requests never even follow
            // a 3xx — the task completes with the redirect response itself,
            // which perform(_:) then fails.
            let session = URLSession(
                configuration: configuration,
                delegate: RedirectRejectingSessionDelegate(),
                delegateQueue: nil
            )
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                return (data, response)
            }
        }
    }

    func send(
        _ payload: SyncPayload,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> SyncAcknowledgment {
        let body = try SyncPayloadEncoder.encode(payload)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(request: &request, authorization: authorization)

        let data = try await perform(request)
        return try Self.decodeAcknowledgment(data)
    }

    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(request: &request, authorization: authorization)

        let data = try await perform(request)
        return try Self.decodeHealthResponse(data)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as CancellationError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError {
            throw Self.map(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DestinationClientError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 300...399:
            throw DestinationClientError.redirected
        case 401, 403:
            throw DestinationClientError.authenticationFailed
        case 413:
            throw DestinationClientError.payloadTooLarge
        default:
            throw DestinationClientError.serverRejected(status: http.statusCode)
        }
    }

    private static func authorize(request: inout URLRequest, authorization: DestinationAuthorization) {
        request.setValue("Bearer \(authorization.bearerToken)", forHTTPHeaderField: "Authorization")
    }

    private static func map(_ error: URLError) -> DestinationClientError {
        switch error.code {
        case .timedOut:
            .requestTimedOut
        default:
            .connectionFailed
        }
    }

    private static func decodeAcknowledgment(_ data: Data) throws -> SyncAcknowledgment {
        struct Shape: Decodable {
            let status: String
            let accepted: Int
            let duplicates: Int
        }
        let shape: Shape
        do {
            shape = try JSONDecoder().decode(Shape.self, from: data)
        } catch {
            throw DestinationClientError.malformedAcknowledgment
        }
        guard shape.status == "accepted", shape.accepted >= 0, shape.duplicates >= 0 else {
            throw DestinationClientError.malformedAcknowledgment
        }
        return SyncAcknowledgment(accepted: shape.accepted, duplicates: shape.duplicates)
    }

    private static func decodeHealthResponse(_ data: Data) throws -> ReceiverHealthResponse {
        struct Shape: Decodable {
            let status: String
            let service: String
            let apiVersion: Int
        }
        let shape: Shape
        do {
            shape = try JSONDecoder().decode(Shape.self, from: data)
        } catch {
            throw DestinationClientError.malformedAcknowledgment
        }
        guard shape.status == "ok", !shape.service.isEmpty, shape.apiVersion >= 1 else {
            throw DestinationClientError.malformedAcknowledgment
        }
        return ReceiverHealthResponse(status: shape.status, service: shape.service, apiVersion: shape.apiVersion)
    }
}

/// Refuses every redirect: a credential-bearing or health-data request must
/// land exactly on the configured endpoint, not wherever a 3xx would send it.
private final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
