import SwiftUI

struct DestinationView: View {
    @Environment(DestinationConfigurationStore.self) private var destinationStore
    @State private var endpointDraft = ""
    @State private var tokenDraft = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Send future exports to an HTTPS endpoint you control. The endpoint is saved on this device; this build does not send health data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("https://your-server.example/health", text: $endpointDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .accessibilityLabel("HTTPS destination endpoint")
            } header: {
                Text("Destination")
            } footer: {
                Text(destinationStore.isConfigured ? "Saved: \(destinationStore.savedEndpoint)" : "HTTPS is required. Credentials and query strings are not accepted in the URL.")
            }

            Section {
                SecureField("API key (not saved)", text: $tokenDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("This field is temporary and is not stored or sent. Keychain support will be in place before network delivery is added.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Authentication")
            }

            Section {
                Button("Save endpoint") {
                    do {
                        try destinationStore.save(endpoint: endpointDraft)
                        endpointDraft = destinationStore.savedEndpoint
                        statusMessage = "HTTPS endpoint saved on this device."
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .disabled(!isValidEndpoint)

                Button("Test connection") {}
                    .disabled(true)
            } footer: {
                Text("Connection testing and synchronization will be added after secure credential storage and HTTPS delivery are implemented.")
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
                        destinationStore.clear()
                        endpointDraft = ""
                        statusMessage = "Saved endpoint removed."
                    }
                }
            }
        }
        .onAppear {
            if endpointDraft.isEmpty {
                endpointDraft = destinationStore.savedEndpoint
            }
        }
        .navigationTitle("Destination")
        .navigationBarTitleDisplayMode(.large)
    }

    private var isValidEndpoint: Bool {
        (try? DestinationConfiguration(endpoint: endpointDraft)) != nil
    }
}
