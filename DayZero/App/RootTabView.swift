import SwiftUI

enum AppTab: Hashable {
    case home, map, apps
}

/// Pages opened from the Home tab's tiles.
enum HomePage: String, Hashable, CaseIterable {
    case emergency, water, food, babyFood, petFood, powerTools, waterTools, sanitationTools, survivalTools, household, notes, settings
}

/// Shared navigation state, so later phases can jump between tabs
/// (for example "Show on map" from an emergency contact).
@Observable
final class AppRouter {
    var selectedTab: AppTab = AppRouter.launchTab
    /// The Home tab's navigation stack (pages and anything pushed inside them).
    var homePath = NavigationPath(AppRouter.launchPages)
    /// Set by "Show on map"; the Map tab centers on it.
    var mapFocus: MapFocus?
    /// A tool screen the Apps tab should open (from a quick action).
    var openTool: ToolID? = {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "openTool").flatMap(ToolID.init(rawValue:))
        #else
        return nil
        #endif
    }()

    /// Debug builds accept `-initialTab map` (etc.) as a launch argument, for screenshots and testing.
    private static var launchTab: AppTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "initialTab") {
        case "map": return .map
        case "apps": return .apps
        default: return .home
        }
        #else
        return .home
        #endif
    }

    /// Debug: `-initialTab water|food|babyFood|petFood|powerTools|household|notes|emergency|settings` opens that page on Home.
    private static var launchPages: [HomePage] {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "initialTab").flatMap(HomePage.init(rawValue:)).map { [$0] } ?? []
        #else
        return []
        #endif
    }

    /// Opens a Home page: pushed on top when already on Home, otherwise Home is shown with just that page.
    func open(_ page: HomePage) {
        if selectedTab == .home {
            homePath.append(page)
        } else {
            homePath = NavigationPath([page])
            selectedTab = .home
        }
    }

    func showOnMap(title: String, latitude: Double, longitude: Double) {
        mapFocus = MapFocus(title: title, latitude: latitude, longitude: longitude)
        selectedTab = .map
    }
}

struct MapFocus: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let latitude: Double
    let longitude: Double
}

struct RootTabView: View {
    @State private var router = AppRouter()
    @State private var quickActions = QuickActionCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            OfflineMapView()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(AppTab.map)

            AppsView()
                .tabItem { Label("Control", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.apps)
        }
        .environment(router)
        .modifier(SupplyMonitor())
        .onChange(of: quickActions.pending, initial: true) { _, action in
            guard let action else { return }
            quickActions.pending = nil
            router.selectedTab = .apps
            switch action {
            case .flashlight:
                ToolController.shared.setTorch(true)
                router.openTool = .flashlight
            case .sos:
                ToolController.shared.startSOS()
                router.openTool = .sos
            default:
                router.openTool = action
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The LED turns off when DayZero leaves the screen.
            if phase == .background { ToolController.shared.appDidEnterBackground() }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: DayZeroSchema.models, inMemory: true)
}
