import SwiftUI

struct DestinationView: View {
    @Environment(DestinationConfigurationStore.self) private var destinationStore
    @State private var endpointDraft = ""
    @State private var tokenDraft = ""
    @State private var isEditingEndpoint = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Send future exports to an HTTPS endpoint you control. The endpoint is saved securely on this device; this build does not send health data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isEditingEndpoint {
                    TextField("https://your-server.example/health", text: $endpointDraft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .accessibilityLabel("HTTPS destination endpoint")
                } else {
                    Label("HTTPS endpoint saved securely", systemImage: "checkmark.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Change endpoint") {
                        endpointDraft = destinationStore.savedEndpoint
                        isEditingEndpoint = true
                    }
                }
            } header: {
                Text("Destination")
            } footer: {
                Text(isEditingEndpoint
                     ? "HTTPS is required. User info, query strings, and fragments are not accepted in the endpoint."
                     : "The saved destination is protected by Keychain on this device.")
            }

            Section {
                SecureField("API key (not saved)", text: $tokenDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("This value is kept only in memory and is neither saved to this device nor sent. Keychain-backed credential support will be added before network delivery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Authentication")
            }

            Section {
                if isEditingEndpoint {
                    Button("Save endpoint") {
                        do {
                            try destinationStore.save(endpoint: endpointDraft)
                            endpointDraft = ""
                            isEditingEndpoint = false
                            statusMessage = "HTTPS endpoint saved securely on this device."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                    .disabled(!isValidEndpoint)

                    if destinationStore.isConfigured {
                        Button("Cancel", role: .cancel) {
                            endpointDraft = ""
                            isEditingEndpoint = false
                        }
                    }
                }

                Button("Test connection") {}
                    .disabled(true)
            } footer: {
                Text("Connection testing and synchronization will be added after secure credential storage and HTTPS delivery are implemented.")
            }

            if let storageError = destinationStore.storageError {
                Section {
                    Label(storageError, systemImage: "exclamationmark.triangle")
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
                    Button("Remove saved endpoint", role: .destructive) {
                        do {
                            try destinationStore.clear()
                            endpointDraft = ""
                            isEditingEndpoint = true
                            statusMessage = "Saved endpoint removed."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .onAppear {
            if !destinationStore.isConfigured {
                isEditingEndpoint = true
            }
        }
        .onDisappear {
            tokenDraft = ""
        }
        .navigationTitle("Destination")
        .navigationBarTitleDisplayMode(.large)
    }

    private var isValidEndpoint: Bool {
        (try? DestinationConfiguration(endpoint: endpointDraft)) != nil
    }
}
