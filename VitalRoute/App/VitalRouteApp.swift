import SwiftUI
import BackgroundTasks

@main
struct VitalRouteApp: App {
    @State private var appModel: VitalRouteModel
    @State private var destinationStore: DestinationConfigurationStore
    @State private var credentialStore: DestinationCredentialStore
    @State private var selectionStore: ExportSelectionStore
    @State private var syncCoordinator: ManualSyncCoordinator
    @State private var autoSyncEngine: AutomaticSyncEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let healthKitService = HealthKitService()
        let sharedGate = SyncWorkGate()
        let syncDirectory = Self.syncDirectory()

        let stateStore = SyncStateStore(directory: syncDirectory)
        let outbox = Outbox(directory: syncDirectory)
        let engine = AutomaticSyncEngine(
            healthData: healthKitService,
            client: HTTPDestinationClient(),
            stateStore: stateStore,
            outbox: outbox,
            workGate: sharedGate
        )
        engine.scheduleBackgroundRetry = { delay in
            _ = BackgroundSyncTasks.scheduleNext(after: delay)
        }

        _appModel = State(initialValue: VitalRouteModel(healthData: healthKitService))
        _destinationStore = State(initialValue: DestinationConfigurationStore())
        _credentialStore = State(initialValue: DestinationCredentialStore())
        _selectionStore = State(initialValue: ExportSelectionStore())
        _syncCoordinator = State(
            initialValue: ManualSyncCoordinator(
                healthData: healthKitService,
                client: HTTPDestinationClient(),
                workGate: sharedGate
            )
        )
        _autoSyncEngine = State(initialValue: engine)

        // Must happen before the app finishes launching. A registration
        // failure (identifier not permitted) is logged by the registrar.
        _ = BackgroundSyncTasks.register(engine: engine)
    }

    nonisolated private static func syncDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VitalRouteSync", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
                .environment(destinationStore)
                .environment(credentialStore)
                .environment(selectionStore)
                .environment(syncCoordinator)
                .environment(autoSyncEngine)
                .task { await destinationStore.loadSavedEndpoint() }
                // Re-reading the credential whenever the endpoint settles or
                // changes keeps credential state namespaced to the active
                // destination; it never triggers any network traffic.
                .task(id: destinationStore.savedEndpoint) {
                    await credentialStore.loadCredential(for: destinationStore.savedEndpoint)
                }
                .task {
                    await launchAutomaticSync()
                }
                .onChange(of: destinationStore.savedEndpoint) {
                    syncConfigurationWithEngine()
                }
                .onChange(of: credentialStore.hasCredential) {
                    syncConfigurationWithEngine()
                }
                .onChange(of: credentialStore.credentialEndpoint) {
                    syncConfigurationWithEngine()
                }
                .onChange(of: selectionStore.selectedMetrics) {
                    syncConfigurationWithEngine()
                }
                .onChange(of: syncCoordinator.isSyncing) { oldValue, newValue in
                    if oldValue && !newValue {
                        autoSyncEngine.manualSyncFinished()
                    }
                }
                .onChange(of: scenePhase) { _, newValue in
                    if newValue == .active {
                        autoSyncEngine.foregroundCatchUp()
                    }
                }
        }
    }

    /// App-level (not screen-level) restoration: prepares durable stores and
    /// re-arms observers whenever automatic sync is enabled.
    private func launchAutomaticSync() async {
        await autoSyncEngine.prepareStorage()
        await autoSyncEngine.restoreOnLaunch(
            destination: destinationStore.savedEndpoint,
            token: credentialStore.loadedToken,
            metrics: selectionStore.selectedMetrics
        )
    }

    private func syncConfigurationWithEngine() {
        let engine = autoSyncEngine
        let endpoint = destinationStore.savedEndpoint
        let token = credentialStore.loadedToken
        let metrics = selectionStore.selectedMetrics
        Task {
            await engine.configurationChanged(
                destination: endpoint,
                token: token,
                metrics: metrics
            )
        }
    }
}

private struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                OverviewView()
            }
            .tabItem {
                Label("Overview", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                HealthDataView()
            }
            .tabItem {
                Label("Health Data", systemImage: "heart.text.square")
            }

            NavigationStack {
                DestinationView()
            }
            .tabItem {
                Label("Destination", systemImage: "arrow.trianglehead.branch")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(.teal)
    }
}
