import SwiftUI

@main
struct VitalRouteApp: App {
    @State private var appModel: VitalRouteModel
    @State private var destinationStore: DestinationConfigurationStore
    @State private var credentialStore: DestinationCredentialStore
    @State private var selectionStore: ExportSelectionStore
    @State private var syncCoordinator: ManualSyncCoordinator

    init() {
        let healthKitService = HealthKitService()
        _appModel = State(initialValue: VitalRouteModel(healthData: healthKitService))
        _destinationStore = State(initialValue: DestinationConfigurationStore())
        _credentialStore = State(initialValue: DestinationCredentialStore())
        _selectionStore = State(initialValue: ExportSelectionStore())
        _syncCoordinator = State(
            initialValue: ManualSyncCoordinator(
                healthData: healthKitService,
                client: HTTPDestinationClient()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
                .environment(destinationStore)
                .environment(credentialStore)
                .environment(selectionStore)
                .environment(syncCoordinator)
                .task { await destinationStore.loadSavedEndpoint() }
                // Re-reading the credential whenever the endpoint settles or
                // changes keeps credential state namespaced to the active
                // destination; it never triggers any network traffic.
                .task(id: destinationStore.savedEndpoint) {
                    await credentialStore.loadCredential(for: destinationStore.savedEndpoint)
                }
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
