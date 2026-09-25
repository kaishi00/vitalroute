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
    @State private var backfillStore = BackfillPreferenceStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let healthKitService = HealthKitService()
        let sharedGate = SyncWorkGate()
        let syncDirectory = Self.syncDirectory()

        let stateStore = SyncStateStore(directory: syncDirectory)
        let outbox = Outbox(directory: syncDirectory)
        // One transport for manual and automatic work: the client owns a
        // URLSession, and two of them means two sessions and two
        // redirect-rejecting delegates for the same destination.
        let destinationClient = HTTPDestinationClient()
        let engine = AutomaticSyncEngine(
            healthData: healthKitService,
            client: destinationClient,
            stateStore: stateStore,
            outbox: outbox,
            workGate: sharedGate
        )
        engine.scheduleBackgroundRetry = { delay in
            BackgroundSyncTasks.scheduleNext(after: delay)
        }

        // The stores the engine's launch restoration reads. Built here as
        // locals so the restoration task below can capture them; the @State
        // wrappers share the same instances.
        let destinationStore = DestinationConfigurationStore()
        let credentialStore = DestinationCredentialStore()
        let selectionStore = ExportSelectionStore()

        _appModel = State(initialValue: VitalRouteModel(healthData: healthKitService))
        _destinationStore = State(initialValue: destinationStore)
        _credentialStore = State(initialValue: credentialStore)
        _selectionStore = State(initialValue: selectionStore)
        _syncCoordinator = State(
            initialValue: ManualSyncCoordinator(
                healthData: healthKitService,
                client: destinationClient,
                stateStore: stateStore,
                workGate: sharedGate
            )
        )
        _autoSyncEngine = State(initialValue: engine)

        // Must happen before the app finishes launching.
        BackgroundSyncTasks.register(engine: engine)

        // Launch restoration must not depend on a UI scene existing. iOS can
        // relaunch a terminated app directly into the background — a
        // HealthKit background-delivery wake or a scheduled BGTask — and no
        // SwiftUI scene ever connects there, so `.task` modifiers on scene
        // content never run. Restoration is what re-arms the observers and
        // gives the engine its destination and credential; without it, a
        // process death ended observation until the user happened to open
        // the app, and background passes could see no configuration at all.
        //
        // This races the scene-driven configuration re-reports in the
        // foreground; that is safe by construction — an identical re-report
        // claims no generation, and `restoreOnLaunch`'s claim always wins
        // ordering because it runs before the scene's onChange hooks can
        // observe a settled store — so a duplicate pass is redundant work at
        // worst, never lost work.
        Task { @MainActor in
            await destinationStore.loadSavedEndpoint()
            await credentialStore.loadCredential(for: destinationStore.savedEndpoint)
            await engine.prepareStorage()
            await engine.restoreOnLaunch(
                destination: destinationStore.savedEndpoint,
                token: credentialStore.loadedToken,
                metrics: selectionStore.selectedMetrics
            )
        }
    }

    nonisolated private static func syncDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Unreachable on iOS; a container-relative path keeps the durable
            // stores inside the sandbox rather than somewhere shared.
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
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
                .environment(backfillStore)
                .task { await destinationStore.loadSavedEndpoint() }
                // Re-reading the credential whenever the endpoint settles or
                // changes keeps credential state namespaced to the active
                // destination; it never triggers any network traffic. Engine
                // launch restoration itself happens in `init`, independent
                // of any scene.
                .task(id: destinationStore.savedEndpoint) {
                    await credentialStore.loadCredential(for: destinationStore.savedEndpoint)
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
                // A replacement for the same endpoint changes neither
                // `hasCredential` nor `credentialEndpoint`; the revision is
                // what tells the engine its credential is stale.
                .onChange(of: credentialStore.credentialRevision) {
                    syncConfigurationWithEngine()
                }
                .onChange(of: selectionStore.selectedMetrics) {
                    syncConfigurationWithEngine()
                }
                // `isSyncing` cannot drive this: it is a computed property
                // over the observation-ignored task handle, so reading it
                // registers no dependency and its transitions are never
                // observed. `phase` is observable, and every run that enters
                // `runSync` returns it to .idle. A run cancelled while still
                // queued never leaves .idle, so no transition fires — and
                // none is needed: that run held no work and changed nothing
                // for the engine to catch up on.
                .onChange(of: syncCoordinator.phase) { oldValue, newValue in
                    if oldValue != .idle && newValue == .idle {
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
