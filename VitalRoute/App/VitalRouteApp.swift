import SwiftUI

@main
struct VitalRouteApp: App {
    @State private var appModel: VitalRouteModel
    @State private var destinationStore: DestinationConfigurationStore

    init() {
        _appModel = State(initialValue: VitalRouteModel(healthData: HealthKitService()))
        _destinationStore = State(initialValue: DestinationConfigurationStore())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
                .environment(destinationStore)
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
