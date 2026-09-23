import Foundation

struct DestinationConfiguration: Equatable {
    let endpoint: URL

    init(endpoint rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value) else {
            throw DestinationConfigurationError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw DestinationConfigurationError.httpsRequired
        }
        guard let host = components.host, !host.isEmpty else {
            throw DestinationConfigurationError.hostRequired
        }
        guard components.user == nil, components.password == nil else {
            throw DestinationConfigurationError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw DestinationConfigurationError.queryAndFragmentNotAllowed
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw DestinationConfigurationError.invalidURL
        }
        guard let url = components.url, url.host != nil else {
            throw DestinationConfigurationError.invalidURL
        }
        endpoint = url
    }
}

enum DestinationConfigurationError: Error, Equatable, LocalizedError {
    case invalidURL
    case httpsRequired
    case hostRequired
    case credentialsNotAllowed
    case queryAndFragmentNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid destination URL."
        case .httpsRequired:
            "The destination must use HTTPS."
        case .hostRequired:
            "Enter a destination with a host name."
        case .credentialsNotAllowed:
            "Credentials cannot be included in the destination URL."
        case .queryAndFragmentNotAllowed:
            "Remove query parameters and fragments from the destination URL."
        }
    }
}
