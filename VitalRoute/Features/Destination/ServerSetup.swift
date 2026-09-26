import Foundation

/// Bundled server-setup content: the repository pointers, the compatible
/// receiver revision, documentation links, and the reusable agent setup
/// prompt shown in the Destination tab's "Server setup" guide.
///
/// Everything here is a compile-time constant built from the two values
/// below. When the receiver's HTTP contract changes, update
/// `compatibleReceiverRef` (a full commit SHA of a revision whose
/// `server/` matches the contract this app speaks — see
/// `ReceiverHealthResponse.supportsDeletions`) and re-verify the linked
/// documents at that revision.
enum ServerSetup {
    /// The app's own repository, which contains the reference receiver.
    static let repositoryURL = URL(string: "https://github.com/kaishi00/vitalroute")!

    /// Contract this app's automatic sync requires: `apiVersion >= 2` with
    /// `["additions", "deletions"]` capabilities — keep in sync with
    /// `ReceiverHealthResponse.supportsDeletions`.
    ///
    /// Last verified 2026-09-25 against `server/API.md` at the revision
    /// below. Maintainers: when the receiver contract changes, update the
    /// SHA to a revision implementing the new contract, re-read every
    /// document linked here at that revision, and re-verify the links
    /// resolve (HTTP 200).
    static let compatibleContractVersion = 2

    /// Receiver revision this app's documentation and setup prompt are
    /// written for. A full commit SHA is used on purpose — branch names
    /// move and `main` may not be compatible; deploy exactly this revision.
    static let compatibleReceiverRef = "959ee7833e906281716b480a805d96b0e1736998"

    /// The URL shape the app expects. The configured endpoint is the exact
    /// ingestion URL; the connection test is `GET` on the same URL.
    static let endpointTemplate = "https://<your-server>/v1/records"

    // MARK: Documentation links (pinned to the compatible revision)

    static var receiverREADMEURL: URL { documentationURL("server/README.md") }
    static var receiverAPIURL: URL { documentationURL("server/API.md") }
    static var receiverDeploymentURL: URL { documentationURL("server/DEPLOYMENT.md") }
    static var receiverAgentGuideURL: URL { documentationURL("server/AGENT.md") }
    static var receiverInstallScriptURL: URL { documentationURL("server/deploy/install.sh") }

    private static func documentationURL(_ path: String) -> URL {
        guard let url = URL(string: "\(repositoryURL.absoluteString)/blob/\(compatibleReceiverRef)/\(path)") else {
            preconditionFailure("ServerSetup: invalid documentation URL for \(path)")
        }
        return url
    }

    // MARK: Reusable agent setup prompt

    /// A prompt the owner can hand to an AI agent to install and configure
    /// the receiver on the owner's behalf. Static by construction: it never
    /// reads the keychain, the app's stores, or anything else on the device,
    /// so copying or sharing it can never leak the saved endpoint, API
    /// token, or health data. Every value the agent needs is an explicit
    /// `<placeholder>` for the owner (or the agent, asking the owner) to
    /// fill in.
    static let agentSetupPrompt = #"""
    You are setting up a receiving server for the VitalRoute iOS app on the
    owner's behalf. VitalRoute sends selected Apple Health data from the
    owner's iPhone to a server the owner controls. Your job: install and
    configure the reference receiver, then report exactly what the owner
    needs to enter in the app.

    Repository: https://github.com/kaishi00/vitalroute
    Required receiver revision (full commit SHA): 959ee7833e906281716b480a805d96b0e1736998
    The app's automatic sync requires contract v2: connection test plus
    change-batch ingestion of additions and deletions (`apiVersion >= 2`,
    capabilities `["additions", "deletions"]`). Manual-only sync would work
    with a v1 receiver, but deploy exactly the revision above so automatic
    sync works — do not use `main` or a branch name; they may not be
    compatible.

    Before acting, read these files at that revision:
    - server/README.md      (what the receiver is; configuration; HTTPS)
    - server/API.md          (the HTTP contract: connection test, ingestion,
                              contract v2 semantics, limits)
    - server/DEPLOYMENT.md   (supported installation, HTTPS, day-2 operations)

    Ask the owner before choosing anything:
    1. Which machine should host the receiver? (Any always-on machine the
       owner controls with Linux, Docker Compose, and persistent storage.
       Never assume a particular host, container platform, address, account,
       or provider.)
    2. How should the iPhone reach it? Options documented in DEPLOYMENT.md:
       a private tailnet hostname via Tailscale Serve, or a public hostname
       behind a reverse proxy. The app requires HTTPS with a publicly
       trusted certificate; self-signed certificates are rejected.

    Installation:
    - Use the supported deployment method: server/deploy/install.sh via
      Docker Compose, with its persistent data volume. Keep the receiver
      bound to loopback on the host and expose it only through the HTTPS
      layer you set up.
    - Let the installer generate and store the bearer token its documented
      way. Never invent, embed, print, or commit a token, and never put one
      in a URL.
    - Verify access through the exact phone-facing endpoint URL: GET the
      full https://<your-server>/v1/records value the owner will enter (not
      just the host, and not just /v1/health). It must return 200 with
      apiVersion >= 2 and capabilities ["additions", "deletions"], and 401
      without the token.
    - Prove ingestion with the receiver's synthetic-data sender
      (server/send_synthetic_data.py) only. Never use real health data
      during setup, and remember the connection test itself sends nothing.

    Report back to the owner:
    1. The exact endpoint URL to enter in VitalRoute > Destination, in the
       form https://<your-server>/v1/records
    2. Where the API token lives on the server (on a default install:
       /srv/vitalroute/token, readable only by the receiver and by root
       via sudo), how to retrieve it without echoing it into logs or chat,
       and that it is entered once in VitalRoute > Destination and stored
       in the phone's Keychain.
    3. The network or VPN requirements for the phone to reach the endpoint,
       and how those were verified.
    4. Basic maintenance, using only the receiver's documented tooling:
       status and health checks, upgrades by pinned revision, backups
       (server/deploy/backup.sh), token rotation (and updating the key in
       VitalRoute > Destination afterwards), and how deletion works:
       deleting samples in Apple Health propagates deletions during sync,
       the receiver keeps tombstones so deleted samples cannot reappear,
       and permanently deleting server-held data is the operator action
       documented in DEPLOYMENT.md.

    Hard rules:
    - Inspect the receiver code and documentation before acting; do not
      invent commands, paths, or endpoints.
    - Never log or echo credentials, headers, or record contents; never put
      secrets in URLs; never leave the receiver unauthenticated.
    - Make no changes on the host beyond what the documented installation
      requires.
    """#
}
