import SwiftUI

/// Read-only "Server setup" guide, reachable from the Destination tab.
///
/// This view is documentation only: it injects no stores, performs no
/// network calls, requests no HealthKit access, and touches no credentials.
/// Opening it, copying the setup prompt, or sharing it can never authorize
/// anything, save anything, or send anything.
struct ServerSetupGuideView: View {
    @State private var copiedPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                overview
                connectSection
                ownServerSection
                dataSection
                linksSection
            }
            .padding()
        }
        .navigationTitle("Server setup")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text("•")
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
            }
        }
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(url.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "safari")
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityHint("Opens in your web browser")
    }

    // MARK: Sections

    private var overview: some View {
        section("What VitalRoute does") {
            paragraph(
                "VitalRoute sends the Apple Health categories you choose from your iPhone to a server you trust — usually one you run yourself. Nothing is sent anywhere until you configure a destination and start a sync, and the app itself never shares data with any other service."
            )
        }
    }

    private var connectSection: some View {
        section("1. Connect to an existing server") {
            VStack(alignment: .leading, spacing: 12) {
                paragraph(
                    "If someone already runs a VitalRoute-compatible receiver for you, they give you two things:"
                )
                bullets([
                    "An endpoint URL — where the server accepts records. It must be HTTPS and point at the receiver's records path, for example \(ServerSetup.endpointTemplate).",
                    "An API token — a secret string that authenticates your phone to that server. Treat it like a password.",
                ])
                paragraph(
                    "Enter both on the Destination screen: save the endpoint first, then save the API key. Both are stored only in this phone's Keychain."
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Test Connection")
                        .font(.headline)
                    paragraph(
                        "The “Test connection” button on the Destination screen checks that the endpoint is reachable, that its HTTPS certificate is valid, and that your API token is accepted. It is a single read-only request: it never sends or returns health records. It succeeds on both older (v1) and current receivers — turning on Automatic Sync separately requires the current contract (v2, with additions and deletions), and that check happens when you enable it."
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("After connecting")
                        .font(.headline)
                    bullets([
                        "Health Data tab: choose which categories may be exported.",
                        "Overview tab: use “Sync now” for a manual sync whenever you like.",
                        "Settings tab: turn on Automatic Sync to let the app deliver new records in the background.",
                    ])
                    paragraph(
                        "Automatic sync runs when iOS grants background time, so delivery times vary — it is not a fixed schedule. Manual sync works even with a receiver that only supports the older v1 contract; automatic sync needs v2."
                    )
                }
            }
        }
    }

    private var ownServerSection: some View {
        section("2. Install your own server") {
            VStack(alignment: .leading, spacing: 12) {
                paragraph(
                    "The repository includes a small reference receiver: a minimal service that receives your records over HTTPS, stores them in a single SQLite database, and answers a read-only query service for your own agents. It has no accounts, no dashboard, and no third-party services."
                )
                bullets([
                    "Runs on any always-on machine you control — a home server, VM, or cloud host — with Linux, Docker Compose, and persistent disk for the database.",
                    "Authenticates every request with a bearer token you generate at install time.",
                    "Requires HTTPS with a publicly trusted certificate; self-signed certificates are rejected by the app.",
                    "Must be reachable from your phone. A private-network address (for example a Tailscale tailnet) works from your devices only; a local home address will not work when you are away from home unless you route to it.",
                ])
                paragraph(
                    "The supported installation is Docker Compose via the repository's install script, which pins the deployed revision, generates the token, and health-checks the result. Full instructions, HTTPS setup (Tailscale Serve or a reverse proxy), backups, token rotation, and data removal are documented in the repository:"
                )
                linkRow("Receiver overview (README)", url: ServerSetup.receiverREADMEURL)
                linkRow("Deployment and operations", url: ServerSetup.receiverDeploymentURL)
                linkRow("Install script (pinned revision)", url: ServerSetup.receiverInstallScriptURL)

                agentPromptCard
            }
        }
    }

    private var agentPromptCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set it up with an AI agent")
                    .font(.headline)
                paragraph(
                    "Copy the prompt below into an AI coding agent (for example on the machine that will host the server). It pins the compatible receiver revision, asks the agent to confirm hosting and network choices with you, and requires verification with synthetic data before you connect. Nothing on this phone is read or included — you will fill in the details it asks for."
                )
                Text(ServerSetup.agentSetupPrompt)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Setup prompt to give to an AI agent")
                HStack {
                    // Safety invariant: both actions below must place
                    // ServerSetup.agentSetupPrompt verbatim — never any
                    // store value, credential, or device configuration.
                    Button {
                        UIPasteboard.general.string = ServerSetup.agentSetupPrompt
                        copiedPrompt = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copiedPrompt = false
                        }
                    } label: {
                        Label(copiedPrompt ? "Copied" : "Copy setup prompt",
                              systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: ServerSetup.agentSetupPrompt) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
    }

    private var dataSection: some View {
        section("3. Use and manage your data") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How the app talks to the server")
                        .font(.headline)
                    paragraph(
                        "One URL does everything. A GET on the endpoint is the connection test; a POST delivers a batch of changes. Every request carries your API token as a Bearer authorization header. Batches are atomic (all records are stored or none are) and idempotent (each record's Apple Health ID is stored once, so retries never duplicate data). Automatic sync also sends deletions: when you delete a sample in Apple Health, the deletion is propagated to the server, and the server keeps a tombstone so the deleted sample can never reappear."
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Querying your data")
                        .font(.headline)
                    paragraph(
                        "The receiver also ships an optional read-only query service (MCP) so your own AI agents can answer questions about your stats. It is separate from ingestion, uses its own token, and can only read: it exposes three fixed tools (list metrics, daily aggregates, recent records), excludes deleted samples, and has no write path."
                    )
                    linkRow("Agent query guide (AGENT.md)", url: ServerSetup.receiverAgentGuideURL)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Stopping, removing, deleting")
                        .font(.headline)
                    bullets([
                        "Stop automatic sync: Settings → turn Automatic Sync off. Manual sync still works.",
                        "Remove this phone's connection: Destination → “Remove saved destination”. This deletes the endpoint and API key from this phone only — the server keeps the records it already received.",
                        "Delete server-held data: the app cannot do this. Records live in the server's database, which you (or the server's operator) control; deletion is a server-side action documented in the deployment guide — including removing the data volume, which irreversibly deletes every received record.",
                    ])
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("About delivery timing")
                        .font(.headline)
                    paragraph(
                        "Automatic sync runs when iOS grants the app background time. That depends on your usage patterns, battery, and system scheduling — treat it as “delivered eventually”, not as a fixed or guaranteed schedule. Manual sync is immediate."
                    )
                }
            }
        }
    }

    private var linksSection: some View {
        section("Documentation") {
            VStack(alignment: .leading, spacing: 10) {
                linkRow("Receiver API contract (API.md)", url: ServerSetup.receiverAPIURL)
                linkRow("Receiver overview (README.md)", url: ServerSetup.receiverREADMEURL)
                linkRow("Deployment guide (DEPLOYMENT.md)", url: ServerSetup.receiverDeploymentURL)
                Text("Links point at the receiver revision this version of VitalRoute was tested with.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
