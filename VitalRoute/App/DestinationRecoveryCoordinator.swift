import Foundation
import UIKit

/// Re-arms the persisted configuration after transient secure-storage
/// unavailability — the locked-device background-launch case that build 6
/// turned into "no destination".
///
/// The SwiftUI scene hooks (`onChange`, `.task`) only run when a scene
/// exists. A background launch has none, so without this coordinator the
/// stores' retry and the engine's re-arming would wait for the user to open
/// the app. `start()` observes protected-data availability, which fires when
/// the device is unlocked even with no scene attached, and `recoverNow()` is
/// also invoked from the scene-active hook as a belt-and-braces retry.
///
/// Every step is idempotent and safe to call repeatedly: settled loads
/// no-op, the Keychain accessibility migration converges, and an identical
/// configuration re-report claims no engine generation.
@MainActor
final class DestinationRecoveryCoordinator {
    private let destinationStore: DestinationConfigurationStore
    private let credentialStore: DestinationCredentialStore
    private let selectionStore: ExportSelectionStore
    private let engine: AutomaticSyncEngine
    private let secureStore: any SecureValueStoring
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// Set once the accessibility migration has succeeded for this process;
    /// until then every recovery trigger retries it (it fails while the
    /// device is locked, and converges on the first unlock).
    private var migrationConverged = false

    init(
        destinationStore: DestinationConfigurationStore,
        credentialStore: DestinationCredentialStore,
        selectionStore: ExportSelectionStore,
        engine: AutomaticSyncEngine,
        secureStore: any SecureValueStoring,
        notificationCenter: NotificationCenter = .default
    ) {
        self.destinationStore = destinationStore
        self.credentialStore = credentialStore
        self.selectionStore = selectionStore
        self.engine = engine
        self.secureStore = secureStore
        self.notificationCenter = notificationCenter
    }

    /// Begins observing protected-data availability. Call once at app init;
    /// observers live for the process.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.recoverNow()
            }
        })
    }

    /// Upgrades the Keychain items' accessibility class once per process
    /// until it succeeds; items written by earlier builds stay unreadable
    /// from locked-device launches until this converges on first unlock.
    /// The `SecItemUpdate` runs off the main actor — the same reason reads
    /// do: it can block on a busy keychain.
    func migrateSecureStorageIfNeeded() async {
        guard !migrationConverged else { return }
        let store = secureStore
        do {
            try await Task.detached(priority: .utility) {
                try store.migrateToBackgroundAccessibility()
            }.value
            migrationConverged = true
        } catch {
            // Locked device: retried on the next recovery trigger.
        }
    }

    /// One recovery attempt: upgrade Keychain accessibility (first unlock
    /// after this update), retry the stores that have not settled, and —
    /// only once endpoint and credential describe the same destination —
    /// report the configuration to the engine so a waiting engine resumes
    /// without user interaction. A settled empty endpoint means removal and
    /// ends the wait through the removal path instead.
    func recoverNow() async {
        await migrateSecureStorageIfNeeded()

        await destinationStore.loadSavedEndpoint()
        guard destinationStore.isLoaded else { return }
        let endpoint = destinationStore.savedEndpoint

        if endpoint.isEmpty {
            await engine.configurationRemoved()
            return
        }

        await credentialStore.loadCredential(for: endpoint)
        // An endpoint may only be paired with its own credential: reporting
        // while the credential still describes a previous endpoint would let
        // the engine send that key to the new destination.
        guard credentialStore.credentialEndpoint == endpoint else { return }

        await engine.configurationChanged(
            destination: endpoint,
            token: credentialStore.loadedToken,
            metrics: selectionStore.selectedMetrics
        )
    }
}
