import XCTest
@testable import VitalRoute

/// Pins the bundled server-setup content: the pinned receiver revision, the
/// documentation links built from it, the endpoint format the guide teaches
/// (checked against the app's real validation), and the guarantee that the
/// agent setup prompt is static content that can never carry the phone's
/// saved configuration or secrets.
@MainActor
final class ServerSetupTests: XCTestCase {
    // MARK: Compatibility pin

    func testCompatibleReceiverRefIsAFullCommitSha() {
        // A branch name moves and an abbreviated SHA is ambiguous; the guide
        // pins an immutable revision so the instructions stay compatible.
        let ref = ServerSetup.compatibleReceiverRef
        XCTAssertNotNil(ref.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                        "receiver ref must be a full 40/64-char lowercase commit SHA")
    }

    func testDocumentationLinksArePinnedToTheCompatibleRevision() {
        let links: [(URL, String)] = [
            (ServerSetup.receiverREADMEURL, "server/README.md"),
            (ServerSetup.receiverAPIURL, "server/API.md"),
            (ServerSetup.receiverDeploymentURL, "server/DEPLOYMENT.md"),
            (ServerSetup.receiverAgentGuideURL, "server/AGENT.md"),
            (ServerSetup.receiverInstallScriptURL, "server/deploy/install.sh"),
        ]
        for (url, path) in links {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertEqual(url.host(), "github.com", url.absoluteString)
            XCTAssertEqual(
                url.path(),
                "/kaishi00/vitalroute/blob/\(ServerSetup.compatibleReceiverRef)/\(path)",
                url.absoluteString
            )
        }
    }

    // MARK: Endpoint format taught by the guide

    func testEndpointTemplateIsAcceptedByDestinationConfiguration() throws {
        // Whatever host the user substitutes, the template's shape must pass
        // the app's real endpoint validation.
        let filled = ServerSetup.endpointTemplate.replacingOccurrences(
            of: "<your-server>",
            with: "health.example.org"
        )
        let configuration = try DestinationConfiguration(endpoint: filled)
        XCTAssertEqual(configuration.endpoint.absoluteString, filled)
    }

    func testEndpointTemplateRejectsInsecureVariantTheGuideNeverSuggests() {
        let insecure = ServerSetup.endpointTemplate
            .replacingOccurrences(of: "https://", with: "http://")
            .replacingOccurrences(of: "<your-server>", with: "health.example.org")
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: insecure))
    }

    // MARK: Agent setup prompt

    func testAgentPromptContainsRequiredGuidance() {
        let prompt = ServerSetup.agentSetupPrompt

        XCTAssertTrue(prompt.contains("https://github.com/kaishi00/vitalroute"))
        XCTAssertTrue(prompt.contains(ServerSetup.compatibleReceiverRef))
        XCTAssertTrue(prompt.contains(ServerSetup.endpointTemplate),
                      "the prompt must state the exact endpoint format to enter")
        // Read the docs before acting.
        XCTAssertTrue(prompt.contains("server/API.md"))
        XCTAssertTrue(prompt.contains("server/DEPLOYMENT.md"))
        XCTAssertTrue(prompt.contains("server/README.md"))
        // Ask, don't assume.
        XCTAssertTrue(prompt.contains("Ask the owner before choosing anything"))
        // Synthetic-only verification.
        XCTAssertTrue(prompt.contains("send_synthetic_data.py"))
        // Secure token handling and where it lives on a default install.
        XCTAssertTrue(prompt.contains("/srv/vitalroute/token"))
        // Hard rules.
        XCTAssertTrue(prompt.contains("Never log or echo credentials"))
    }

    func testAgentPromptPlaceholdersAreFromTheDocumentedSet() {
        // Every <placeholder> in the prompt must be one the guide documents;
        // anything else suggests runtime interpolation crept in.
        let allowed: Set<String> = ["<your-server>"]
        let prompt = ServerSetup.agentSetupPrompt
        let regex = try! NSRegularExpression(pattern: "<[^<>\\n]{1,60}>")
        let range = NSRange(location: 0, length: prompt.utf16.count)
        let found = regex.matches(in: prompt, range: range).map {
            (prompt as NSString).substring(with: $0.range)
        }
        for placeholder in found {
            XCTAssertTrue(allowed.contains(placeholder),
                          "unexpected placeholder \(placeholder)")
        }
        XCTAssertFalse(found.isEmpty, "the prompt should ask for explicit input")
    }

    func testAgentPromptNeverCarriesDeviceConfigurationOrSecrets() throws {
        // The prompt is static content. To prove it cannot leak the phone's
        // saved configuration, save a distinctive endpoint and token in the
        // same stores the Destination screen uses and check neither value —
        // nor any bearer-formatted secret — appears in the prompt.
        let secureStore = PromptProbeSecureStore()
        let endpoint = "https://probe-\(UUID().uuidString).example/v1/records"
        let token = "secret-token-\(UUID().uuidString)"
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        let credentialStore = DestinationCredentialStore(secureStore: secureStore)
        try configurationStore.save(endpoint: endpoint)
        try credentialStore.saveCredential(token, for: endpoint)
        XCTAssertEqual(credentialStore.loadedToken, token, "precondition: a token is saved")

        let prompt = ServerSetup.agentSetupPrompt

        XCTAssertFalse(prompt.contains(endpoint))
        XCTAssertFalse(prompt.contains(token))
        XCTAssertFalse(prompt.contains("Bearer secret-token"))
    }
}

/// Minimal in-memory secure store for the probe test.
private final class PromptProbeSecureStore: SecureValueStoring, @unchecked Sendable {
    var values: [String: String] = [:]

    func readValue(forKey key: String) throws -> String? { values[key] }
    func saveValue(_ value: String, forKey key: String) throws { values[key] = value }
    func removeValue(forKey key: String) throws { values.removeValue(forKey: key) }
    func migrateToBackgroundAccessibility() throws {}
}
