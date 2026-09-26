import SwiftUI

struct DestinationView: View {
    @Environment(DestinationConfigurationStore.self) private var destinationStore
    @Environment(DestinationCredentialStore.self) private var credentialStore
    @State private var endpointDraft = ""
    @State private var tokenDraft = ""
    @State private var isEditingEndpoint = false
    @State private var isEditingToken = false
    @State private var statusMessage: String?
    @State private var isTestingConnection = false
    @State private var connectionResult: String?
    @State private var connectionSucceeded: Bool?
    @State private var connectionClient = HTTPDestinationClient()

    var body: some View {
        Form {
            if !destinationStore.isConfigured {
                setupGuidePromoSection
            }
            endpointSection
            authenticationSection
            connectionSection
            setupGuideSection

            if let storageError = destinationStore.storageError {
                Section {
                    Label(storageError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if let credentialError = credentialStore.storageError {
                Section {
                    Label(credentialError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            if destinationStore.isConfigured {
                Section {
                    Button("Remove saved destination", role: .destructive) {
                        removeDestination()
                    }
                }
            }
        }
        .onAppear {
            enterEditingIfUnconfigured()
        }
        .onChange(of: destinationStore.isLoaded) {
            enterEditingIfUnconfigured()
        }
        .onChange(of: destinationStore.savedEndpoint) {
            // The app-level task(id:) reloads credential state; clear any
            // stale per-endpoint UI on this screen when the endpoint changes.
            tokenDraft = ""
            isEditingToken = false
            connectionResult = nil
            connectionSucceeded = nil
        }
        .onDisappear {
            // Leaving the screen discards the whole editing session — drafts,
            // status text, and edit mode — so returning shows the settled
            // saved/unconfigured state; first-time entry is restored by
            // enterEditingIfUnconfigured() on the next appear.
            tokenDraft = ""
            endpointDraft = ""
            statusMessage = nil
            connectionResult = nil
            connectionSucceeded = nil
            isEditingEndpoint = false
            isEditingToken = false
        }
        .navigationTitle("Destination")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: Sections

    /// Prominent while no destination is configured: a new user's first
    /// question is where an endpoint and API key come from.
    private var setupGuidePromoSection: some View {
        Section {
            NavigationLink {
                ServerSetupGuideView()
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: "book.circle")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setting up a server?")
                            .font(.headline)
                        Text(
                            "Read the server setup guide: what an endpoint and API key are, how to run your own receiver, and how syncing works."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Always available, configured or not.
    private var setupGuideSection: some View {
        Section {
            NavigationLink {
                ServerSetupGuideView()
            } label: {
                Label("Server setup guide", systemImage: "book")
            }
            .accessibilityHint("Explains endpoints, API tokens, running your own server, and managing your data")
        } header: {
            Text("Server setup")
        } footer: {
            Text("Read-only guide. Nothing here changes your configuration or sends data.")
        }
    }

    private var endpointSection: some View {
        Section {
            Text("Send exports to an HTTPS endpoint you control. The endpoint and its API key are saved separately, each secured in Keychain on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isEditingEndpoint {
                TextField("https://your-server.example/v1/records", text: $endpointDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .accessibilityLabel("HTTPS destination endpoint")

                Button("Save endpoint") {
                    saveEndpoint()
                }
                .disabled(!isValidEndpoint)

                if destinationStore.isConfigured {
                    Button("Cancel", role: .cancel) {
                        endpointDraft = ""
                        isEditingEndpoint = false
                    }
                }
            } else if destinationStore.isConfigured {
                Text(destinationStore.savedEndpoint)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
                Button("Change endpoint") {
                    endpointDraft = destinationStore.savedEndpoint
                    statusMessage = nil
                    isEditingEndpoint = true
                }
            } else if destinationStore.isLoaded {
                Label("No destination saved yet.", systemImage: "arrow.trianglehead.branch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Add endpoint") {
                    statusMessage = nil
                    isEditingEndpoint = true
                }
            } else {
                Label("Checking secure storage…", systemImage: "key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Destination")
        } footer: {
            Text(isEditingEndpoint
                 ? "HTTPS is required. User info, query strings, and fragments are not accepted in the endpoint."
                 : "The saved destination is protected by Keychain on this device.")
        }
    }

    private var authenticationSection: some View {
        Section {
            if isEditingToken || !credentialStore.hasCredential {
                SecureField("API key for this destination", text: $tokenDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(credentialStore.hasCredential ? "Replace API key" : "Save API key") {
                    saveToken()
                }
                .disabled(!canSaveToken)

                if credentialStore.hasCredential {
                    Button("Cancel", role: .cancel) {
                        tokenDraft = ""
                        isEditingToken = false
                    }
                }
            } else if credentialStore.isLoaded {
                Label("API key saved securely for this destination", systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Replace API key") {
                    tokenDraft = ""
                    statusMessage = nil
                    isEditingToken = true
                }
                Button("Remove API key", role: .destructive) {
                    removeToken()
                }
            } else {
                Label("Checking secure storage…", systemImage: "key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Keys are stored per destination: changing the endpoint removes the previous destination's key instead of reusing it. The key is sent only as an authorization header over HTTPS.")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                    }
                    Text("Test connection")
                }
            }
            .disabled(!canTestConnection || isTestingConnection)

            if let connectionResult {
                Label(
                    connectionResult,
                    systemImage: connectionSucceeded == true ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Checks that the endpoint is reachable over HTTPS and accepts the API key. The test sends no health records.")
        }
    }

    // MARK: Actions

    /// The saved endpoint loads asynchronously, so the unconfigured check may
    /// only become meaningful after this screen first appears.
    private func enterEditingIfUnconfigured() {
        guard destinationStore.isLoaded, !destinationStore.isConfigured, !isEditingEndpoint else {
            return
        }
        isEditingEndpoint = true
    }

    private func saveEndpoint() {
        let previousEndpoint = destinationStore.savedEndpoint
        do {
            try destinationStore.save(endpoint: endpointDraft)
            endpointDraft = ""
            isEditingEndpoint = false
            statusMessage = "HTTPS endpoint saved securely on this device."
            if !previousEndpoint.isEmpty && previousEndpoint != destinationStore.savedEndpoint {
                // Credentials are namespaced per destination: drop the old
                // destination's key so it is neither reused nor left behind.
                do {
                    try credentialStore.removeCredential(for: previousEndpoint)
                    statusMessage = "HTTPS endpoint saved. The previous destination's API key was removed."
                } catch {
                    statusMessage = "HTTPS endpoint saved, but the previous destination's API key could not be removed from secure storage."
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeDestination() {
        let endpoint = destinationStore.savedEndpoint
        do {
            try destinationStore.clear()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        do {
            try credentialStore.removeCredential(for: endpoint)
            statusMessage = "Saved destination and its API key were removed."
        } catch {
            statusMessage = "Saved destination removed, but its API key could not be deleted from secure storage."
        }
        endpointDraft = ""
        isEditingEndpoint = true
        tokenDraft = ""
        isEditingToken = false
        connectionResult = nil
    }

    private func saveToken() {
        do {
            try credentialStore.saveCredential(tokenDraft, for: destinationStore.savedEndpoint)
            tokenDraft = ""
            isEditingToken = false
            statusMessage = "API key saved securely for this destination."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeToken() {
        do {
            try credentialStore.removeCredential(for: destinationStore.savedEndpoint)
            isEditingToken = false
            statusMessage = "API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let endpoint = URL(string: destinationStore.savedEndpoint), endpoint.scheme == "https" else {
            connectionResult = "Save a valid HTTPS destination first."
            return
        }
        guard let bearer = resolvedToken() else {
            connectionResult = "Enter or save an API key before testing."
            return
        }

        isTestingConnection = true
        connectionResult = nil
        connectionSucceeded = nil
        Task {
            defer { isTestingConnection = false }
            do {
                let response = try await connectionClient.testConnection(
                    to: endpoint,
                    authorization: DestinationAuthorization(bearerToken: bearer)
                )
                connectionSucceeded = true
                connectionResult = "Connection verified — \(response.service) (API v\(response.apiVersion)) acknowledged the key. No health records were sent."
            } catch is CancellationError {
                connectionResult = nil
                connectionSucceeded = nil
            } catch {
                connectionSucceeded = false
                connectionResult = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Saved token when present, otherwise the draft the user just typed —
    /// letting a key be verified before it is committed to Keychain.
    private func resolvedToken() -> String? {
        if credentialStore.hasCredential,
           credentialStore.credentialEndpoint == destinationStore.savedEndpoint,
           let token = credentialStore.loadedToken {
            return token
        }
        let draft = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? nil : draft
    }

    // MARK: Derived state

    private var canSaveToken: Bool {
        destinationStore.isConfigured
            && !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTestConnection: Bool {
        guard destinationStore.isConfigured, !isEditingEndpoint, !isEditingToken else {
            return false
        }
        return credentialStore.hasCredential
            || !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isValidEndpoint: Bool {
        (try? DestinationConfiguration(endpoint: endpointDraft)) != nil
    }

}
